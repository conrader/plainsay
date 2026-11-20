#!/usr/bin/perl
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my ($seconds, $step, @command) = @ARGV;
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    exec { $command[0] } @command or die "exec $command[0]: $!\n";
}

while (1) {
    my $finished = waitpid($pid, WNOHANG);
    if ($finished == $pid) {
        my $signal = $? & 127;
        exit($signal ? 128 + $signal : $? >> 8);
    }
    die "waitpid: $!\n" if $finished < 0;

    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    last if $remaining <= 0;
    sleep($remaining < 0.01 ? $remaining : 0.01);
}

# The direct child is still unreaped, so its PID cannot have been reused.
kill 'KILL', $pid;
waitpid($pid, 0);
print STDERR "$step timed out after $seconds seconds. See RELEASING.md for release keychain setup.\n";
exit 124;
