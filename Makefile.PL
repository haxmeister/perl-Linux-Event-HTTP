use strict;
use warnings;
use ExtUtils::MakeMaker;

if ($^O ne 'linux') {
    print "OS unsupported: Linux::Event::Net::HTTP supports Linux only\n";
    exit 0;
}

my @public_modules = qw(
    Linux::Event::Net::HTTP
    Linux::Event::Net::HTTP::Connection
    Linux::Event::Net::HTTP::Request
    Linux::Event::Net::HTTP::Response
    Linux::Event::Net::HTTP::Server
);

my $distribution_version = MM->parse_version('lib/Linux/Event/Net/HTTP.pm');
my %provides = map {
    my $file = "lib/$_.pm";
    $file =~ s{::}{/}g;
    $_ => {
        file    => $file,
        version => $distribution_version,
    };
} @public_modules;

WriteMakefile(
    NAME             => 'Linux::Event::Net::HTTP',
    VERSION_FROM     => 'lib/Linux/Event/Net/HTTP.pm',
    ABSTRACT         => 'Native high-performance HTTP protocol support for Linux::Event',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    DIR              => [qw(xshttp1)],
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'Linux::Event' => '0.112',
    },
    META_MERGE => {
        'meta-spec' => {
            version => 2,
        },
        no_index => {
            package => [qw(
                Linux::Event::Net::HTTP::_Parser::HTTP1
            )],
        },
        provides => \%provides,
        resources => {
            homepage   => 'https://github.com/haxmeister/perl-Linux-Event-Net-HTTP',
            bugtracker => {
                web => 'https://github.com/haxmeister/perl-Linux-Event-Net-HTTP/issues',
            },
            repository => {
                type => 'git',
                url  => 'https://github.com/haxmeister/perl-Linux-Event-Net-HTTP.git',
                web  => 'https://github.com/haxmeister/perl-Linux-Event-Net-HTTP',
            },
        },
    },
);
