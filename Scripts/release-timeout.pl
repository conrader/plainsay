#!/usr/bin/perl
use strict;
use warnings;
use Errno qw(EINTR);
use POSIX qw(SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK WNOHANG sigprocmask);
use Time::HiRes qw(sleep);

my ($seconds, $step, @command) = @ARGV;
my $caller = getppid();
my $watchdog = $$;
my $clock;
my $started = eval {
    $clock = Time::HiRes::CLOCK_MONOTONIC();
    Time::HiRes::clock_gettime($clock);
};
die "$step cannot start: CLOCK_MONOTONIC is unavailable in /usr/bin/perl.\n"
    unless defined $started && $started >= 0;
my $deadline = $started + $seconds;
my $poll_interval = 0.1;

sub reap_child {
    my ($pid, $flags) = @_;
    while (1) {
        my $finished = waitpid($pid, $flags);
        return $? if $finished == $pid;
        return undef if $finished == 0;
        die "waitpid: $!\n" unless $! == EINTR;
    }
}

sub group_has_live_commands {
    my ($group) = @_;
    # The guardian and any unreaped zombies keep the group present after commands exit.
    open my $processes, '-|', '/bin/ps', '-ax', '-o', 'pid=', '-o', 'pgid=', '-o', 'stat=' or return 1;
    my $live = 0;
    while (<$processes>) {
        my ($pid, $pgid, $state) = split;
        $live = 1 if defined $state && $pgid == $group && $pid != $group && $state !~ /^Z/;
    }
    return !close($processes) || $live;
}

my %signal_number = (HUP => SIGHUP, INT => SIGINT, TERM => SIGTERM);
my @received;
$SIG{$_} = sub { push @received, $_[0] } for keys %signal_number;

# Hold cancellation signals until the command is ready. The guardian keeps them blocked.
my $forwarded_signals = POSIX::SigSet->new(values %signal_number);
my $original_mask = POSIX::SigSet->new();
defined sigprocmask(SIG_BLOCK, $forwarded_signals, $original_mask) or die "sigprocmask: $!\n";

# The guardian survives a KILL of the original group and pins the command's group ID
# even after the command exits. Establish the group before forking the command.
my $group = fork();
die "fork guardian: $!\n" unless defined $group;
if ($group == 0) {
    sleep($poll_interval) while getppid() == $watchdog;
    kill 'KILL', -$$;
    POSIX::_exit(1);
}
defined POSIX::setpgid($group, $group) or die "setpgid guardian: $!\n";

my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    $SIG{$_} = 'DEFAULT' for keys %signal_number;
    defined POSIX::setpgid(0, $group) or die "setpgid: $!\n";
    # The guardian may have sent KILL before this process joined the group.
    POSIX::_exit(1) if getppid() != $watchdog;
    defined sigprocmask(SIG_SETMASK, $original_mask) or die "sigprocmask: $!\n";
    exec { $command[0] } @command or die "exec $command[0]: $!\n";
}
# Ensure an early cancellation reaches the command, which may have already joined and exec'd.
POSIX::setpgid($pid, $group);
defined sigprocmask(SIG_SETMASK, $original_mask) or die "sigprocmask: $!\n";

my $status;
while (!@received && getppid() == $caller) {
    $status = reap_child($pid, WNOHANG);
    last if defined $status;

    my $remaining = $deadline - Time::HiRes::clock_gettime($clock);
    last if $remaining <= 0;
    sleep($remaining < $poll_interval ? $remaining : $poll_interval);
}
if (defined $status && !@received && getppid() == $caller) {
    kill 'KILL', $group;
    reap_child($group, 0);
    my $signal = $status & 127;
    exit($signal ? 128 + $signal : $status >> 8);
}

kill 'TERM', -$group unless @received;
my $grace_deadline = Time::HiRes::clock_gettime($clock) + 2;
my $forwarded = 0;
while (getppid() == $caller) {
    while ($forwarded < @received) {
        kill $received[$forwarded++], -$group;
    }
    if (@received) {
        $status = reap_child($pid, WNOHANG) unless defined $status;
        last if defined $status && !group_has_live_commands($group);
    }
    my $remaining = $grace_deadline - Time::HiRes::clock_gettime($clock);
    last if $remaining <= 0;
    sleep($remaining < $poll_interval ? $remaining : $poll_interval);
}
kill 'KILL', -$group;
reap_child($pid, 0) unless defined $status;
reap_child($group, 0);
exit(128 + $signal_number{$received[0]}) if @received;
exit(128 + SIGTERM) if getppid() != $caller;
print STDERR "$step timed out after $seconds seconds. See RELEASING.md for release keychain setup.\n";
exit 124;
