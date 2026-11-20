#!/usr/bin/perl
use strict;
use warnings;
use Errno qw(EINTR);
use POSIX qw(SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK WNOHANG sigprocmask);
use Time::HiRes qw(sleep);

my ($seconds, $step, @command) = @ARGV;
my $clock;
my $started = eval {
    $clock = Time::HiRes::CLOCK_MONOTONIC();
    Time::HiRes::clock_gettime($clock);
};
die "$step cannot start: CLOCK_MONOTONIC is unavailable in /usr/bin/perl.\n"
    unless defined $started && $started >= 0;
my $deadline = $started + $seconds;
my $poll_interval = 0.1;

my %signal_number = (HUP => SIGHUP, INT => SIGINT, TERM => SIGTERM);
my @received;
$SIG{$_} = sub { push @received, $_[0] } for keys %signal_number;

# Hold cancellation signals until the child group and its default handlers are ready.
my $forwarded_signals = POSIX::SigSet->new(values %signal_number);
my $original_mask = POSIX::SigSet->new();
defined sigprocmask(SIG_BLOCK, $forwarded_signals, $original_mask) or die "sigprocmask: $!\n";
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    $SIG{$_} = 'DEFAULT' for keys %signal_number;
    defined POSIX::setpgid(0, 0) or die "setpgid: $!\n";
    defined sigprocmask(SIG_SETMASK, $original_mask) or die "sigprocmask: $!\n";
    exec { $command[0] } @command or die "exec $command[0]: $!\n";
}
# The child may have already called exec or exited.
POSIX::setpgid($pid, $pid);
defined sigprocmask(SIG_SETMASK, $original_mask) or die "sigprocmask: $!\n";

while (!@received) {
    my $finished = waitpid($pid, WNOHANG);
    if ($finished == $pid) {
        exit(128 + $signal_number{$received[0]}) if @received;
        my $signal = $? & 127;
        exit($signal ? 128 + $signal : $? >> 8);
    }
    next if $finished < 0 && $! == EINTR;
    die "waitpid: $!\n" if $finished < 0;

    my $remaining = $deadline - Time::HiRes::clock_gettime($clock);
    last if $remaining <= 0;
    sleep($remaining < $poll_interval ? $remaining : $poll_interval);
}

# Keep the group leader unreaped until after KILL so its PID cannot be reused.
# The leader can exit on TERM while a descendant still holds a capture pipe open.
kill 'TERM', -$pid unless @received;
my $grace_deadline = Time::HiRes::clock_gettime($clock) + 2;
my $forwarded = 0;
while (1) {
    while ($forwarded < @received) {
        kill $received[$forwarded++], -$pid;
    }
    my $remaining = $grace_deadline - Time::HiRes::clock_gettime($clock);
    last if $remaining <= 0;
    sleep($remaining < $poll_interval ? $remaining : $poll_interval);
}
kill 'KILL', -$pid;
while (waitpid($pid, 0) < 0) {
    next if $! == EINTR;
    die "waitpid: $!\n";
}
exit(128 + $signal_number{$received[0]}) if @received;
print STDERR "$step timed out after $seconds seconds. See RELEASING.md for release keychain setup.\n";
exit 124;
