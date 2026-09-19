/*
 * parallelism-tracker — measure and nudge parallel-vs-sequential tool usage.
 *
 * Modes:
 *   check <tool_name> [input|-]
 *                      — called from PreToolUse hook. Logs the call.
 *                        Detects 3+ consecutive solo turns (>=500ms apart)
 *                        and writes a nudge to stderr.
 *                        With a third argument the call's tool_input is
 *                        hashed (FNV-1a 64 over tool_name + NUL + input; `-`
 *                        reads the input from stdin so a large Write payload
 *                        never hits ARG_MAX). The same tool called with a
 *                        byte-identical input HMD_LOOP_THRESHOLD times in a
 *                        row (default 5) writes a one-line LOOP warning to
 *                        stderr. Any different input resets the run. Without
 *                        a third argument the loop detector is inert and the
 *                        binary behaves exactly as before. Advisory only:
 *                        exit code is never changed by the detector.
 *   grade              — called from SessionEnd hook. Tallies session log,
 *                        appends a record to .planning/metrics.jsonl,
 *                        prints summary to stdout.
 *
 * Solo vs batch: tool calls within 500ms of the previous one are treated as
 * a parallel batch (same assistant turn). Calls separated by >=500ms count
 * as the start of a new turn.
 *
 * State file is a line-based key=value text format guarded by a sibling
 * .lock file via flock(LOCK_EX). Concurrent PreToolUse hook firings do not
 * corrupt the counters.
 *
 * Cold start: ~1ms (no interpreter, no JSON parser, single static binary).
 *
 * Build:    clang -O2 -Wall -Wextra -o bin/parallelism-tracker bin/parallelism-tracker.c
 */

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define BATCH_THRESHOLD_MS 500
#define SOLO_TRIGGER 3
#define AGENT_SOLO_TRIGGER 2
#define LOOP_THRESHOLD_DEFAULT 5
#define LOOP_TOOL_CAP 64
#define STATE_VERSION 2

typedef struct {
    long long last_ts;
    long solo;
    long batch_turns;
    long total_turns;
    long current_turn_size;
    long calls;
    long agent_solo;
    long agent_calls;
    long agent_batched;
    /* v2: live identical-call loop detector. An old (v1) state file simply
     * lacks these keys; read_state zeroes them, so the first call after an
     * upgrade starts a fresh run of 1 rather than misreading anything. */
    uint64_t loop_hash;
    long loop_run;
    char loop_tool[LOOP_TOOL_CAP];
} state_t;

/* FNV-1a 64-bit. Stable across runs and platforms; not cryptographic, and it
 * does not need to be: a collision only means a different input is mistaken
 * for a repeat, and the detector is advisory. */
#define FNV1A64_OFFSET 0xcbf29ce484222325ULL
#define FNV1A64_PRIME  0x100000001b3ULL

static uint64_t fnv1a_update(uint64_t h, const void *buf, size_t len) {
    const unsigned char *p = (const unsigned char *)buf;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint64_t)p[i];
        h *= FNV1A64_PRIME;
    }
    return h;
}

/* Hash tool name + NUL + input. `input` of "-" streams stdin in chunks so the
 * payload never has to fit in memory or on the command line. Returns 0 on
 * success, -1 if stdin could not be read (detector then stays inert). */
static int hash_call(const char *tool, const char *input, uint64_t *out) {
    uint64_t h = FNV1A64_OFFSET;
    h = fnv1a_update(h, tool, strlen(tool));
    h = fnv1a_update(h, "", 1);
    if (strcmp(input, "-") == 0) {
        unsigned char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), stdin)) > 0) {
            h = fnv1a_update(h, buf, n);
        }
        if (ferror(stdin)) return -1;
    } else {
        h = fnv1a_update(h, input, strlen(input));
    }
    *out = h;
    return 0;
}

static long loop_threshold(void) {
    const char *env = getenv("HMD_LOOP_THRESHOLD");
    if (!env || !*env) return LOOP_THRESHOLD_DEFAULT;
    char *end = NULL;
    long v = strtol(env, &end, 10);
    if (end == env || (end && *end != '\0') || v < 2) return LOOP_THRESHOLD_DEFAULT;
    return v;
}

static long long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000LL + (long long)(tv.tv_usec / 1000);
}

static int mkdir_p(const char *path) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t len = strlen(tmp);
    if (len == 0) return 0;
    if (tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static void state_path(char *out, size_t cap, const char *suffix) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
    const char *sid = getenv("CLAUDE_SESSION_ID");
    if (!sid || !*sid) sid = getenv("SESSION_ID");
    if (!sid || !*sid) sid = "default";

    size_t tlen = strlen(tmpdir);
    int needs_slash = (tlen > 0 && tmpdir[tlen - 1] != '/');
    snprintf(out, cap, "%s%sheimdall-parallel/%s.%s",
             tmpdir, needs_slash ? "/" : "", sid, suffix);
}

static void state_dir(char *out, size_t cap) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
    size_t tlen = strlen(tmpdir);
    int needs_slash = (tlen > 0 && tmpdir[tlen - 1] != '/');
    snprintf(out, cap, "%s%sheimdall-parallel",
             tmpdir, needs_slash ? "/" : "");
}

static int read_state(const char *path, state_t *s) {
    memset(s, 0, sizeof(*s));
    FILE *f = fopen(path, "r");
    if (!f) return 0; /* fresh state */

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *val = eq + 1;
        size_t vlen = strlen(val);
        if (vlen > 0 && val[vlen - 1] == '\n') val[vlen - 1] = '\0';

        if (strcmp(key, "last_ts") == 0)            s->last_ts           = strtoll(val, NULL, 10);
        else if (strcmp(key, "solo") == 0)          s->solo              = strtol(val, NULL, 10);
        else if (strcmp(key, "batch_turns") == 0)   s->batch_turns       = strtol(val, NULL, 10);
        else if (strcmp(key, "total_turns") == 0)   s->total_turns       = strtol(val, NULL, 10);
        else if (strcmp(key, "current_turn_size") == 0) s->current_turn_size = strtol(val, NULL, 10);
        else if (strcmp(key, "calls") == 0)         s->calls             = strtol(val, NULL, 10);
        else if (strcmp(key, "agent_solo") == 0)    s->agent_solo        = strtol(val, NULL, 10);
        else if (strcmp(key, "agent_calls") == 0)   s->agent_calls       = strtol(val, NULL, 10);
        else if (strcmp(key, "agent_batched") == 0)  s->agent_batched     = strtol(val, NULL, 10);
        else if (strcmp(key, "loop_hash") == 0)     s->loop_hash         = strtoull(val, NULL, 16);
        else if (strcmp(key, "loop_run") == 0)      s->loop_run          = strtol(val, NULL, 10);
        else if (strcmp(key, "loop_tool") == 0)     snprintf(s->loop_tool, sizeof(s->loop_tool), "%s", val);
        /* state_version and any unknown key: ignored, so a newer or older
         * file never trips the parser. */
    }
    if (s->loop_run < 0) s->loop_run = 0;
    fclose(f);
    return 0;
}

static int write_state_atomic(const char *path, const state_t *s) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    fprintf(f, "last_ts=%lld\n", s->last_ts);
    fprintf(f, "solo=%ld\n", s->solo);
    fprintf(f, "batch_turns=%ld\n", s->batch_turns);
    fprintf(f, "total_turns=%ld\n", s->total_turns);
    fprintf(f, "current_turn_size=%ld\n", s->current_turn_size);
    fprintf(f, "calls=%ld\n", s->calls);
    fprintf(f, "agent_solo=%ld\n", s->agent_solo);
    fprintf(f, "agent_calls=%ld\n", s->agent_calls);
    fprintf(f, "agent_batched=%ld\n", s->agent_batched);
    fprintf(f, "state_version=%d\n", STATE_VERSION);
    fprintf(f, "loop_hash=%016llx\n", (unsigned long long)s->loop_hash);
    fprintf(f, "loop_run=%ld\n", s->loop_run);
    fprintf(f, "loop_tool=%s\n", s->loop_tool);
    fflush(f);
    fclose(f);
    if (rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

static int do_check(const char *tool, const char *input) {
    char dir[1024], spath[1024], lpath[1024];

    /* Hash before taking the lock: reading stdin may take a moment for a
     * large payload and the lock should protect only the state update. */
    int have_hash = 0;
    uint64_t call_hash = 0;
    if (input && hash_call(tool ? tool : "unknown", input, &call_hash) == 0) {
        have_hash = 1;
    }
    state_dir(dir, sizeof(dir));
    if (mkdir_p(dir) != 0) return 1;
    state_path(spath, sizeof(spath), "state");
    state_path(lpath, sizeof(lpath), "lock");

    int lock_fd = open(lpath, O_RDWR | O_CREAT, 0644);
    if (lock_fd < 0) return 1;
    if (flock(lock_fd, LOCK_EX) != 0) {
        close(lock_fd);
        return 1;
    }

    state_t s;
    read_state(spath, &s);

    long long now = now_ms();
    s.calls += 1;
    long long delta = (s.last_ts == 0) ? 999999LL : (now - s.last_ts);

    if (s.last_ts != 0 && delta < BATCH_THRESHOLD_MS) {
        s.current_turn_size += 1;
        if (s.current_turn_size == 2) {
            s.batch_turns += 1;
            s.solo = 0;
        }
    } else {
        if (s.current_turn_size == 1) s.solo += 1;
        s.total_turns += 1;
        s.current_turn_size = 1;
    }

    s.last_ts = now;

    int is_agent = (tool && strcmp(tool, "Agent") == 0);
    if (is_agent) {
        s.agent_calls += 1;
        if (s.last_ts != 0 && delta < BATCH_THRESHOLD_MS) {
            s.agent_batched += 1;
            s.agent_solo = 0;
        } else {
            s.agent_solo += 1;
        }
    }

    long loop_warn = 0;
    if (have_hash) {
        if (s.loop_run > 0 && s.loop_hash == call_hash) {
            s.loop_run += 1;
        } else {
            s.loop_hash = call_hash;
            s.loop_run = 1;
            snprintf(s.loop_tool, sizeof(s.loop_tool), "%s", tool ? tool : "unknown");
        }
        if (s.loop_run >= loop_threshold()) loop_warn = s.loop_run;
    }

    int nudge = 0;
    int agent_nudge = 0;
    if (s.solo >= SOLO_TRIGGER) {
        nudge = 1;
        s.solo = 0;
    }
    if (is_agent && s.agent_solo >= AGENT_SOLO_TRIGGER) {
        agent_nudge = 1;
        s.agent_solo = 0;
    }

    write_state_atomic(spath, &s);

    flock(lock_fd, LOCK_UN);
    close(lock_fd);

    if (loop_warn > 0) {
        fprintf(stderr,
                "[heimdall] LOOP: %s called %ldx in a row with byte-identical input "
                "— the same call will give the same result. Change approach: "
                "different input, different tool, or stop and report the blocker.\n",
                s.loop_tool, loop_warn);
    }

    if (agent_nudge) {
        fprintf(stderr,
                "[heimdall] SEQUENTIAL AGENT SPAWNS DETECTED. "
                "You spawned %d Agent calls in separate turns. "
                "If these tasks are independent, send ALL Agent calls in ONE message "
                "with run_in_background: true. Sequential agents = slow. Parallel = fast.\n",
                AGENT_SOLO_TRIGGER);
    } else if (nudge) {
        fprintf(stderr,
                "[heimdall] STOP READING — DELEGATE NOW. "
                "%d consecutive solo tool calls (last: %s). "
                "You are the orchestrator, not the implementer. "
                "Spawn parallel agents and let THEM read/investigate. "
                "Your job: identify tasks → spawn agents → verify results. "
                "Do NOT deep-read files yourself.\n",
                SOLO_TRIGGER, tool ? tool : "unknown");
    }
    return 0;
}

static int do_grade(void) {
    char spath[1024], lpath[1024];
    state_path(spath, sizeof(spath), "state");
    state_path(lpath, sizeof(lpath), "lock");

    state_t s;
    read_state(spath, &s);

    if (s.calls == 0) return 0;

    double ratio = (s.total_turns > 0) ? ((double)s.batch_turns / (double)s.total_turns) : 0.0;

    char ts[64];
    time_t t = time(NULL);
    struct tm tm_utc;
    gmtime_r(&t, &tm_utc);
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tm_utc);

    const char *sid = getenv("CLAUDE_SESSION_ID");
    if (!sid || !*sid) sid = getenv("SESSION_ID");
    if (!sid || !*sid) sid = "default";

    /* Append metric record if .planning/ exists (cwd-relative). */
    struct stat st;
    if (stat(".planning", &st) == 0 && S_ISDIR(st.st_mode)) {
        FILE *m = fopen(".planning/metrics.jsonl", "a");
        if (m) {
            fprintf(m,
                    "{\"ts\":\"%s\",\"session\":\"%s\",\"metric\":\"parallelism\","
                    "\"total_turns\":%ld,\"batch_turns\":%ld,\"total_calls\":%ld,"
                    "\"parallel_ratio\":%.2f,"
                    "\"agent_calls\":%ld,\"agent_batched\":%ld}\n",
                    ts, sid, s.total_turns, s.batch_turns, s.calls, ratio,
                    s.agent_calls, s.agent_batched);
            fclose(m);
        }
    }

    printf("[heimdall] parallelism: %ld batched / %ld turns (ratio %.2f, %ld calls)",
           s.batch_turns, s.total_turns, ratio, s.calls);
    if (s.agent_calls > 0) {
        printf(" | agents: %ld calls, %ld batched", s.agent_calls, s.agent_batched);
    }
    printf("\n");

    unlink(spath);
    unlink(lpath);
    return 0;
}

int main(int argc, char **argv) {
    static const char usage[] = "usage: parallelism-tracker check <tool> [input|-]|grade\n";
    if (argc < 2) {
        fputs(usage, stderr);
        return 1;
    }
    if (strcmp(argv[1], "check") == 0) {
        const char *tool = (argc >= 3) ? argv[2] : "unknown";
        const char *input = (argc >= 4) ? argv[3] : NULL;
        return do_check(tool, input);
    } else if (strcmp(argv[1], "grade") == 0) {
        return do_grade();
    }
    fputs(usage, stderr);
    return 1;
}
