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
# cached, so it is scanned again, whole, on the next call. HMD_NOTIF_INDEX_DEBUG=1 prints scanned_bytes=N on stderr.
#
# THE CACHE IS PRIVATE (security review of 91623b61: a predictable /tmp name written with a plain open() is a symlink attack
# -- anything this user can write gets truncated and overwritten with cache text). The caller passes a directory under
# $HEIMDALL_HOME and the same rules as bin/lib/hmd_private_state.py apply here:
#   * the directory must be a real directory (never a link) this user owns; one that is ours but looser than 0700 is
#     tightened, a link or another account's is refused -- the answer is then built without a cache, only slower;
#   * a cache file is READ with O_NOFOLLOW and trusted only when it is a regular file of ours with no group/other bits;
#   * a cache file is WRITTEN to an unpredictable temp name created O_CREAT|O_EXCL|O_NOFOLLOW (0600 whatever the umask),
#     then renamed over the real name -- a link at the real name is replaced, never written through, and a link planted at
#     a temp name cannot be hit because the name is not known until the file exists.
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL);

# Without O_NOFOLLOW (no such platform is supported, but never guess) the cache is simply not used.
my $NOFOLLOW = eval { Fcntl::O_NOFOLLOW() };

sub private_dir {
    my ($d) = @_;
    return undef unless defined $NOFOLLOW && defined $d && length $d;
    my @st = lstat($d);
    unless (@st) {
        mkdir($d, 0700) or return undef;
        @st = lstat($d) or return undef;
    }
    return undef if -l _ || !-d _ || $st[4] != $<;
    chmod(0700, $d) if $st[2] & 077;
    return $d;
}

sub read_private {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDONLY | $NOFOLLOW) or return undef;
    my @st = stat($fh);
    return undef unless @st && -f _ && $st[4] == $< && !($st[2] & 077);
    return $fh;
}

sub rand_hex {
    my $b = '';
    if (open(my $u, '<:raw', '/dev/urandom')) { read($u, $b, 12); close $u; }
    $b .= pack('NN', time, $$) while length $b < 12;
    return unpack('H*', $b);
}

sub write_private {
    my ($dir, $final, $content) = @_;
    my $tmp = "$dir/.tmp-" . rand_hex();
    sysopen(my $o, $tmp, O_WRONLY | O_CREAT | O_EXCL | $NOFOLLOW, 0600) or return 0;
    my $ok = print {$o} $content;
    $ok = close($o) && $ok;
    return 1 if $ok && rename($tmp, $final);
    unlink $tmp;
    return 0;
}

my ($dir, @files) = @ARGV;
my $cdir = private_dir($dir);
my (%last, $scanned);
$scanned = 0;

for my $f (@files) {
    my @st = stat($f) or next;
    my ($dev, $ino, $size) = @st[0, 1, 7];
    my $cf = $cdir ? "$cdir/" . md5_hex($f) . ".idx" : undef;
    my ($off, %file) = (0);
    if ($cf and my $c = read_private($cf)) {
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
    if ($cf && ($new_off != $off || -l $cf || !-e $cf)) {
        write_private($cdir, $cf, "$new_off\t$dev\t$ino\n" . join('', map { "$_\t$file{$_}\n" } sort keys %file));
    }
    $last{$_} = $file{$_} for keys %file;
    $last{$_} = $tail{$_} for keys %tail;
}
print " ";
print "$_:$last{$_} " for sort keys %last;
print STDERR "scanned_bytes=$scanned\n" if $ENV{HMD_NOTIF_INDEX_DEBUG};
