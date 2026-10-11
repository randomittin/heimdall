#!/usr/bin/perl
# agents_notif_index.pl CACHE_DIR FILE... -- the <task-notification> index bin/heimdall-agents builds, kept incrementally.
#
# bin/heimdall-agents used to `grep -hF '<task-notification>'` EVERY parent session transcript on every list/count/orphans
# call -- transcripts reach 16 MB and this runs on the statusline path of every session (handoff 2026-10-11: whole-transcript
# greps re-spawned every tick by three sessions, most of a 10-core box's load). Transcripts are append-only JSONL, so a
# per-transcript cache keyed by (dev, inode) holds the byte offset already scanned plus the last status per task id seen up
# to it; a call reads only the bytes appended since. Prints " id:status id:status " -- the LAST notification for an id
# wins, later files win over earlier ones -- exactly what the grep|perl|awk pipeline it replaces printed.
#
# A cache entry is trusted only when the file is the same inode and no shorter than the offset it recorded; anything else
# is rescanned from byte 0. A line without its newline (a record still being written) is read for THIS answer but never
# cached, so it is scanned again, whole, on the next call. An unusable cache dir only costs speed. HMD_NOTIF_INDEX_DEBUG=1
# prints scanned_bytes=N on stderr.
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);

my ($dir, @files) = @ARGV;
my $cached = defined $dir && length $dir && (-d $dir || mkdir($dir, 0700));
my (%last, $scanned);
$scanned = 0;

for my $f (@files) {
    my @st = stat($f) or next;
    my ($dev, $ino, $size) = @st[0, 1, 7];
    my $cf = $cached ? "$dir/" . md5_hex($f) . ".idx" : undef;
    my ($off, %file) = (0);
    if ($cf && open(my $c, '<', $cf)) {
        my $head = <$c>;
        my ($o, $d, $i) = split /\t/, (defined $head ? $head : ''), 3;
        if (defined $i) {
            chomp $i;
            if ($o =~ /^\d+$/ && $d eq $dev && $i eq $ino && $o <= $size) {
                $off = $o;
                while (my $l = <$c>) {
                    chomp $l;
                    my ($id, $s) = split /\t/, $l, 2;
                    $file{$id} = $s if defined $s;
                }
            }
        }
        close $c;
    }
    open(my $fh, '<:raw', $f) or next;
    seek($fh, $off, 0);
    my ($new_off, %tail) = ($off);
    while (defined(my $line = <$fh>)) {
        $scanned += length $line;
        my $complete = substr($line, -1) eq "\n";
        $new_off += length $line if $complete;
        next if index($line, '<task-notification>') < 0;
        while ($line =~ m{<task-id>([^<]+)</task-id>.*?<status>([^<]+)</status>}g) {
            if ($complete) { $file{$1} = $2 } else { $tail{$1} = $2 }
        }
    }
    close $fh;
    if ($cf && ($new_off != $off || !-e $cf)) {
        my $tmp = "$cf.$$.tmp";
        if (open(my $o, '>', $tmp)) {
            print $o "$new_off\t$dev\t$ino\n";
            print $o "$_\t$file{$_}\n" for sort keys %file;
            close($o) ? rename($tmp, $cf) : unlink($tmp);
        }
    }
    $last{$_} = $file{$_} for keys %file;
    $last{$_} = $tail{$_} for keys %tail;
}
print " ";
print "$_:$last{$_} " for sort keys %last;
print STDERR "scanned_bytes=$scanned\n" if $ENV{HMD_NOTIF_INDEX_DEBUG};
