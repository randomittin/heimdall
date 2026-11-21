#!/usr/bin/perl
# agents_open_scan.pl FILE... -- what Claude Code session transcripts (oldest first) say is still OPEN. Read-only, one pass, no cache.
#
# WHY (docs/analysis/2026-11-20-finished-agents-still-listed.md, recommendations 3 and 4): a background agent that sent its "finished"
# notice stays resumable, so the harness keeps listing it until something calls TaskStop, and `heimdall-agents orphans` saw none of
# them: it knew parked, wedged and dead-session agents only. The transcript is the one place that holds both halves of the story, the
# notice and the TaskStop that closes it, so this reads it (never writes it).
#
# WHAT IT READS (shapes measured on a real 70 MB session, 2026-11-22):
#   * a <task-notification> block whose JSON string BEGINS with it ("content" of a queue-operation or user row, "prompt" of a
#     queued_command attachment). A quote of one inside assistant text or a tool result never begins a string, so it is not read.
#     The same notice sits in up to four rows (enqueue, remove, delivery, attachment): it is applied once, at its first row, keyed by
#     the md5 of its text. Applying the delivery row too would re-open an agent that TaskStop closed between enqueue and delivery.
#   * a TaskStop tool_use and its tool_result: a success, "No task found" and "is not running" all CLOSE the id (the last two mean the
#     harness no longer holds it, so another TaskStop could only fail).
#   * a SendMessage to an id: that agent runs again, so it is not "finished" until its next notice.
#   * a background Bash launch: tool_use (description) + tool_result "Command running in background with ID: X. Output ... to: PATH."
# A later notice for an id re-opens it (an agent can be resumed and stop again), so the LAST event for each id decides.
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

sub jstr {
    my ($raw) = @_;
    my $s = eval { $jd->decode('"' . $raw . '"') };
    return defined $s ? $s : $raw;
}

sub task_of {
    my ($id) = @_;
    return $task{$id} ||= { id => $id };
}

sub notice {
    my ($id, $out, $st, $sm, $at) = @_;
    my $t = task_of($id);
    $t->{output} = $out if defined $out && length $out;
    $t->{at} = $at if defined $at;
    my $kind = $sm =~ /^Background command / ? 'shell' : $sm =~ /^Agent "/ ? 'agent' : $id =~ /^b/ ? 'shell' : 'agent';
    $t->{kind} = $kind;
    my ($d) = $sm =~ /^(?:Agent|Background command) "(.*)" (?:finished|is waiting|stopped at|was stopped|failed|completed)/s;
    $t->{desc} = $d if defined $d;
    delete $t->{closed};
    if ($st eq 'killed') {
        $t->{closed} = 1;
        $t->{state}  = 'closed';
        return;
    }
    if ($kind eq 'agent') {
        $t->{state} = ($st eq 'completed' && $sm =~ /" finished$/) ? 'finished' : 'other';
    } else {
        $t->{state} = ($st eq 'completed' || $st eq 'failed') ? 'ended' : 'other';
    }
}

for my $f (@ARGV) {
    open(my $fh, '<:raw', $f) or next;
    while (defined(my $line = <$fh>)) {
        if (index($line, '<task-notification>') >= 0) {
            next unless $line =~ /"(?:content|prompt)":"<task-notification>/;
            my $at;
            if ($line =~ /"timestamp":"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/) {
                my @p = ($1, $2, $3, $4, $5, $6);
                $at = eval { timegm($p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0]) };
            }
            while ($line =~ m{<task-notification>(.*?)</task-notification>}g) {
                my $blk = $1;
                next if $seen{ md5_hex($blk) }++;
                next unless $blk =~ m{^(?:\\n|\s)*<task-id>([^<]+)</task-id>(?:\\n|\s)*(?:<tool-use-id>([^<]*)</tool-use-id>(?:\\n|\s)*)?(?:<output-file>([^<]*)</output-file>(?:\\n|\s)*)?<status>([^<]*)</status>(?:\\n|\s)*<summary>(.*?)</summary>};
                my ($id, $out, $st, $sm) = ($1, $3, $4, $5);
                notice($id, $out, $st, jstr($sm), $at);
            }
            next;
        }
        if (index($line, '"name":"TaskStop","input"') >= 0) {
            while ($line =~ m{"type":"tool_use","id":"(toolu_[A-Za-z0-9_]+)","name":"TaskStop","input":\{([^\}]*)\}}g) {
                my ($tu, $in) = ($1, $2);
                $pending{$tu} = $1 if $in =~ /"(?:task_id|shell_id)":"([^"]+)"/;
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
                my ($d) = $in =~ /"description":"((?:[^"\\]|\\.)*)"/;
                my ($c) = $in =~ /"command":"((?:[^"\\]|\\.)*)"/;
                my $text = defined $d ? jstr($d) : defined $c ? substr(jstr($c), 0, 80) : undef;
                $bashdesc{$tu} = $text if defined $text;
            }
        }
        if (index($line, 'Command running in background with ID') >= 0) {
            while ($line =~ m{"tool_use_id":"(toolu_[A-Za-z0-9_]+)","type":"tool_result","content":"Command running in background with ID: ([A-Za-z0-9_-]+)\. Output is being written to: ((?:[^"\\]|\\.)*?\.output)\.}g) {
                my ($tu, $id, $out) = ($1, $2, jstr($3));
                my $t = task_of($id);
                $t->{kind}   ||= 'shell';
                $t->{output} = $out;
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
    my $kind   = $t->{kind} // ($id =~ /^b/ ? 'shell' : 'agent');
    my $state  = $t->{state} // '';
    my $closed = $t->{closed} ? 1 : 0;
    if ($kind eq 'agent') {
        next unless $state eq 'finished' && !$closed;
    } else {
        next unless $state ne '' || $closed;
    }
    my $d = defined $t->{desc} ? substr($t->{desc}, 0, 200) : undef;
    print join("\t", $kind, $id, $state, $closed, field($t->{at}), field($t->{output}), field($d)), "\n";
}
