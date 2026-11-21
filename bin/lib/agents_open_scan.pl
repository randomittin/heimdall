#!/usr/bin/perl
# agents_open_scan.pl FILE... -- what Claude Code session transcripts (oldest first) say is still OPEN. Read-only, one pass, no cache.
#
# WHY (docs/analysis/2026-11-20-finished-agents-still-listed.md, recommendations 3 and 4): a background agent that sent its "finished"
# notice stays resumable, so the harness keeps listing it until something calls TaskStop, and `heimdall-agents orphans` saw none of
# them: it knew parked, wedged and dead-session agents only. The transcript is the one place that holds both halves of the story, the
# notice and the TaskStop that closes it, so this reads it (never writes it).
#
# WHAT IT READS (shapes measured on a real 70 MB session, 2026-11-22):
#   * a <task-notification> block, and ONLY from a row the harness itself wrote it into, in the one string that row keeps it in:
#         queue-operation row (enqueue, remove) ............. content             4392 rows
#         user row with origin.kind "task-notification" ..... message.content     995 rows
#         attachment row, attachment.type "queued_command" .. attachment.prompt     80 rows
#     Never from a tool_result, a tool_use input (an Agent prompt), assistant text, a structured toolUseResult or a user row of any
#     other origin: those carry what a file, a web page or a model said, and a notice in them is a forgery that would put an id and a
#     description of the attacker's choosing into hook output and into CHECKPOINT.md, a tracked file. A string that merely BEGINS with
#     the tag proves nothing (a Bash `cat` result does), so the position is checked on the decoded row, at the three exact paths above.
#     Only the header of the block (task-id .. summary) is read: the <result> that follows is an agent's free text.
#     The same notice sits in up to four rows (enqueue, remove, delivery, attachment): it is applied once, at its first row, keyed by
#     the md5 of its text. Applying the delivery row too would re-open an agent that TaskStop closed between enqueue and delivery.
#   * a TaskStop tool_use and its tool_result: a success, "No task found" and "is not running" all CLOSE the id (the last two mean the
#     harness no longer holds it, so another TaskStop could only fail).
#   * a SendMessage to an id: that agent runs again, so it is not "finished" until its next notice.
#   * a background Bash launch: tool_use (description) + tool_result "Command running in background with ID: X. Output ... to: PATH."
# A later notice for an id re-opens it (an agent can be resumed and stop again), so the LAST event for each id decides.
#
# WHAT IT PRINTS IS DATA, NEVER INSTRUCTIONS (security findings on 2db80607):
#   * an id is a task only in the harness's own shapes (measured: 1893 agent ids, 3476 shell ids, no other): an agent is `a` and 16 or
#     more lowercase hex digits, a background shell `b` and 8 or 9 of 0-9a-z. Anything else is dropped, wherever it was read.
#   * an output path is kept only when it is absolute and ends in `.output`.
#   * a description is the Bash `description` or the quoted words of a notice's summary, NEVER the command text (a command can hold a
#     token, and a checkpoint is committed). It is cleaned in clean_desc: control characters, secrets and markup removed, one line, at
#     most 100 characters.
#
# OUTPUT, one TAB-separated line per task:  kind id state closed at output description   (an empty field is "-")
#   agents: only the open ones (state finished, never stopped).
#   shells: every shell seen, closed ones too, so the caller can tell a stopped one from one it never heard of.
#   state:  finished | ended (the shell's process exited: a completed or failed notice) | running (launched, no notice yet: the
#           caller asks the process table) | other | closed.     at: epoch of the notice's row, "-" when the row has no timestamp.
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use JSON::PP;
use Time::Local qw(timegm);

my $jd = JSON::PP->new->utf8->allow_nonref;
my (%task, %pending, %bashdesc, %seen);
# Stands in for a notice string while its row is decoded; a 64-bit random word no transcript can have predicted.
my $MARK = sprintf('@@hmd%08x%08x@@', int(rand(2**32)), int(rand(2**32)));
my %XML  = (lt => '<', gt => '>', quot => '"', apos => "'", amp => '&');

# The text of a JSON string body (what sits between the quotes); undef when it is not valid JSON.
sub jdec {
    my ($raw) = @_;
    my $s = eval { $jd->decode('"' . $raw . '"') };
    return $s;
}

sub jstr {
    my ($raw) = @_;
    my $s = jdec($raw);
    return defined $s ? $s : $raw;
}

sub task_of {
    my ($id) = @_;
    return $task{$id} ||= { id => $id };
}

# 'agent' | 'shell' for an id in one of the harness's shapes, undef for anything else. Mirrored by _valid_task_id in bin/heimdall-agents.
sub kind_of_id {
    my ($id) = @_;
    return 'agent' if $id =~ /\Aa[0-9a-f]{16,}\z/;
    return 'shell' if $id =~ /\Ab[0-9a-z]{8,9}\z/;
    return undef;
}

sub out_path {
    my ($p) = @_;
    return (defined $p && $p =~ m{\A/[^\x00-\x1f\x7f"\\]*\.output\z}) ? $p : undef;
}

# A description is words a model or a file chose, and it lands in hook output a model reads and in CHECKPOINT.md, which is committed.
# Order matters: secrets go FIRST, while a token is still whole (cut at a markup character it would no longer look like one), and the
# secret rules mirror bin/lib/companion_push.py (the phone's redact.ts profile) WITHOUT its exceptions for a notification: it keeps a
# 1-5 digit value (PASSWORD=12345 passes there) and rewrites URLs and paths, neither of which suits a file that is kept.
sub clean_desc {
    my ($d) = @_;
    return undef unless defined $d;
    $d = substr($d, 0, 1000);                                   # bounds the work; nothing past the cap below survives anyway
    $d =~ s/&(lt|gt|quot|apos|amp);/$XML{$1}/g;                 # the harness XML-escapes its summaries; one pass, so &amp;lt; stays text
    $d =~ s/[\p{Cc}\p{Cf}\p{Co}\p{Zl}\p{Zp}]+/ /g;             # control and format characters (ESC, bidi marks), line and paragraph separators
    $d =~ s{(\b[a-z][a-z0-9+.-]*://)[^\s/]*@}{${1}REDACTED\@}gi;   # URL userinfo: scheme://user:pass@host
    $d =~ s{\b(authorization\b\s*[:=]\s*)(?:(?:bearer|basic|token|digest|negotiate)\s+)?[^\s"',;]+}{${1}REDACTED}gi;
    $d =~ s{\b(bearer)\s+[^\s"',;]+}{$1 REDACTED}gi;
    $d =~ s{\b([\w.-]*?(?:token|secret|passw(?:or)?d|pwd|credential|cookie|signature|key)s?)(["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s"'&,;()\[\]{}]+)}{$1$2REDACTED}gi;
    $d =~ s{\b(?:gh[pousr]_|github_pat_|sk-ant-|sk-proj-|sk_live_|sk_test_|xox[baprs]-|AKIA|ASIA|AIza)[A-Za-z0-9_-]{8,}}{REDACTED}g;
    $d =~ s{(?=[A-Za-z0-9+/_-]*\d)[A-Za-z0-9+/_-]{20,}={0,2}}{REDACTED}g;   # a long hex or base64 run that has a digit in it
    $d =~ s{<!--.*?-->|<[A-Za-z/!?][^>]*>}{ }gs;                # HTML comments (the checkpoint's own markers are two) and tags
    $d =~ s/[`"\\\[\]<>*#|~]/ /g;                               # what is left of markdown: code, quotes, links, emphasis, headings, tables
    $d =~ s/\s+/ /g;
    $d =~ s/\A | \z//g;
    return undef unless length($d);
    if (length($d) > 100) {
        $d = substr($d, 0, 97);
        $d =~ s/\s+\z//;
        $d .= '...';
    }
    return $d;
}

# (BLOCK, EPOCH) of the one notice this row legitimately carries, () for none. See WHAT IT READS: the row is decoded with each candidate
# string swapped for a marker (decoding the notices themselves is 5 s of JSON::PP on that session, what is left is a fraction of it),
# and the notice counts only if the marker sits at one of the three exact paths. A string anywhere else, nested at any depth, cannot.
sub harness_notice {
    my ($line) = @_;
    my (@cand, %key);
    (my $slim = $line) =~ s{("(?:content|prompt)":")(<task-notification>(?:[^"\\]++|\\.)*+)"}{push @cand, $2; $1 . $MARK . $#cand . '"'}ge;
    my @fresh = grep { $cand[$_] =~ m{\A<task-notification>(.*?)</task-notification>}s && !$seen{ $key{$_} = md5_hex($1) } } 0 .. $#cand;
    return unless @fresh;                                       # every notice here was applied at an earlier row: nothing to decode
    my $row = eval { $jd->decode($slim) };
    return unless ref $row eq 'HASH';
    my $type = $row->{type};
    return unless defined $type && !ref $type;
    my $v;
    if ($type eq 'queue-operation') {
        $v = $row->{content};
    } elsif ($type eq 'user') {
        $v = $row->{message}{content}
            if ref $row->{origin} eq 'HASH' && ($row->{origin}{kind} // '') eq 'task-notification' && ref $row->{message} eq 'HASH';
    } elsif ($type eq 'attachment') {
        $v = $row->{attachment}{prompt}
            if ref $row->{attachment} eq 'HASH' && ($row->{attachment}{type} // '') eq 'queued_command';
    }
    return unless defined $v && !ref $v;
    my ($i) = $v =~ /\A\Q$MARK\E(\d+)\z/ or return;
    my $k = $key{$i};
    return if !defined $k || $seen{$k}++;
    my ($blk) = $cand[$i] =~ m{\A<task-notification>(.*?)</task-notification>}s;
    my $at;
    my $ts = $row->{timestamp};
    if (defined $ts && !ref $ts && $ts =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/) {
        my @p = ($1, $2, $3, $4, $5, $6);
        $at = eval { timegm($p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0]) };
    }
    return ($blk, $at);
}

sub apply_notice {
    my ($blk, $at) = @_;
    $blk =~ m{\A(?:\\n|\s)*<task-id>([^<]+)</task-id>(?:\\n|\s)*(?:<tool-use-id>([^<]*)</tool-use-id>(?:\\n|\s)*)?(?:<output-file>([^<]*)</output-file>(?:\\n|\s)*)?<status>([^<]*)</status>(?:\\n|\s)*<summary>(.*?)</summary>} or return;
    notice($1, $3, $4, $5, $at);
}

sub notice {
    my ($id, $out, $st, $raw_sm, $at) = @_;
    my $kind = kind_of_id($id) or return;
    my $sm   = jdec($raw_sm);
    my $text = defined $sm ? $sm : $raw_sm;                     # state is judged on the raw text when it will not decode; a description never is
    return if ($text =~ /\ABackground command / && $kind ne 'shell') || ($text =~ /\AAgent "/ && $kind ne 'agent');
    my $t = task_of($id);
    my $p = out_path($out);
    $t->{output} = $p if defined $p;
    $t->{at}     = $at if defined $at;
    $t->{desc}   = clean_desc($1)
        if defined $sm && $sm =~ /\A(?:Agent|Background command) "(.*)" (?:finished|is waiting|stopped at|was stopped|failed|completed)/s;
    delete $t->{closed};
    if ($st eq 'killed') {
        $t->{closed} = 1;
        $t->{state}  = 'closed';
        return;
    }
    if ($kind eq 'agent') {
        $t->{state} = ($st eq 'completed' && $text =~ /" finished$/) ? 'finished' : 'other';
    } else {
        $t->{state} = ($st eq 'completed' || $st eq 'failed') ? 'ended' : 'other';
    }
}

for my $f (@ARGV) {
    open(my $fh, '<:raw', $f) or next;
    while (defined(my $line = <$fh>)) {
        if (index($line, '<task-notification>') >= 0) {
            next unless $line =~ /"(?:content|prompt)":"<task-notification>/;
            my ($blk, $at) = harness_notice($line) or next;
            apply_notice($blk, $at);
            next;
        }
        if (index($line, '"name":"TaskStop","input"') >= 0) {
            while ($line =~ m{"type":"tool_use","id":"(toolu_[A-Za-z0-9_]+)","name":"TaskStop","input":\{([^\}]*)\}}g) {
                my ($tu, $in) = ($1, $2);
                if ($in =~ /"(?:task_id|shell_id)":"([^"]+)"/) {
                    my $target = $1;
                    $pending{$tu} = $target if defined kind_of_id($target);
                }
            }
        }
        if (%pending && index($line, '"type":"tool_result"') >= 0) {
            while ($line =~ m{"tool_use_id":"(toolu_[A-Za-z0-9_]+)","type":"tool_result","content":"((?:[^"\\]++|\\.)*+)"}g) {
                my ($tu, $raw) = ($1, $2);
                my $id = delete $pending{$tu};
                next unless defined $id;
                task_of($id)->{closed} = 1 if jstr($raw) =~ /Successfully stopped task|No task found|is not running/i;
            }
        }
        if (index($line, '"name":"SendMessage","input":{"to":"') >= 0) {
            while ($line =~ m{"name":"SendMessage","input":\{"to":"([^"]+)"}g) {
                my $t = $task{$1};
                $t->{state} = 'resumed' if $t && ($t->{state} // '') eq 'finished';
            }
        }
        if (index($line, '"name":"Bash","input":{') >= 0 && index($line, 'run_in_background') >= 0) {
            while ($line =~ m{"type":"tool_use","id":"(toolu_[A-Za-z0-9_]+)","name":"Bash","input":\{((?:[^"\\\}]++|\\.|"(?:[^"\\]++|\\.)*+")*+)\}}g) {
                my ($tu, $in) = ($1, $2);
                next unless $in =~ /"run_in_background":true/;
                # The description only. The command is NOT a fallback: it can hold a token, and the line lands in a committed file.
                my ($d) = $in =~ /"description":"((?:[^"\\]|\\.)*)"/;
                my $text = defined $d ? jdec($d) : undef;
                $bashdesc{$tu} = clean_desc($text) if defined $text;
            }
        }
        if (index($line, 'Command running in background with ID') >= 0) {
            while ($line =~ m{"tool_use_id":"(toolu_[A-Za-z0-9_]+)","type":"tool_result","content":"Command running in background with ID: ([A-Za-z0-9_-]+)\. Output is being written to: ((?:[^"\\]|\\.)*?\.output)\.}g) {
                my ($tu, $id, $out) = ($1, $2, jstr($3));
                next unless (kind_of_id($id) // '') eq 'shell';
                my $p = out_path($out);
                next unless defined $p;
                my $t = task_of($id);
                $t->{output} = $p;
                $t->{desc}   = $bashdesc{$tu} if !defined $t->{desc} && defined $bashdesc{$tu};
                $t->{state}  ||= 'running';
            }
        }
    }
    close $fh;
}

binmode(STDOUT, ':raw');
sub field {
    my ($v) = @_;
    $v = '-' unless defined $v && length $v;
    $v =~ s/[\t\r\n]+/ /g;
    utf8::encode($v) if utf8::is_utf8($v);
    return $v;
}
for my $id (sort keys %task) {
    my $t      = $task{$id};
    my $kind   = kind_of_id($id) or next;
    my $state  = $t->{state} // '';
    my $closed = $t->{closed} ? 1 : 0;
    if ($kind eq 'agent') {
        next unless $state eq 'finished' && !$closed;
    } else {
        next unless $state ne '' || $closed;
    }
    print join("\t", $kind, $id, $state, $closed, field($t->{at}), field($t->{output}), field($t->{desc})), "\n";
}
