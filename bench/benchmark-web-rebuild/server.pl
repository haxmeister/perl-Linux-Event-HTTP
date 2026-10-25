#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP ();

my $action = shift // '';
if ($action eq 'info') {
    print JSON::PP->new->canonical->encode({
        label => 'Linux::Event::HTTP (Unblock rebuild)',
        default => JSON::PP::false,
        order => 15,
    });
    exit 0;
}
my $root = $ENV{BENCH_REBUILD_ROOT} // '';
if ($action eq 'settings') {
    print 'Unblock HTTP1, Linux::Event native borrowed input, no response cache';
    exit 0;
}
if ($action eq 'prepare' || $action eq 'cleanup') { exit 0 }
die "BENCH_REBUILD_ROOT is required\n" unless length($root) && -f "$root/blib/lib/Linux/Event/HTTP.pm";
my @prefix = ($^X, "-I$root/blib/lib", "-I$root/blib/arch");
if ($action eq 'probe') {
    system @prefix, '-MLinux::Event::Loop', '-MLinux::Event::HTTP::Server',
        '-e', '1';
    exit($? == 0 ? 0 : 1);
}
if ($action eq 'version') {
    exec @prefix, '-MLinux::Event::HTTP',
        '-e', 'print $Linux::Event::HTTP::VERSION';
    die "exec version: $!\n";
}
if ($action eq 'run') {
    exec @prefix, "$Bin/rebuilt-http.pl";
    die "exec server: $!\n";
}
die "usage: server.pl info|probe|prepare|version|settings|run|cleanup\n";
