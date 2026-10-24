use strict;
use warnings;
use ExtUtils::MakeMaker;

if ($^O ne 'linux') {
    print "OS unsupported: Linux::Event::HTTP supports Linux only\n";
    exit 0;
}

my @public_modules = qw(
    Linux::Event::HTTP
    Linux::Event::HTTP::Body::Stream
    Linux::Event::HTTP::Client
    Linux::Event::HTTP::Client::Connection
    Linux::Event::HTTP::Client::Operation
    Linux::Event::HTTP::Server
    Linux::Event::HTTP::Server::Connection
    Linux::Event::HTTP::Request
    Linux::Event::HTTP::Response
    Linux::Event::HTTP::Transaction
);

my $distribution_version = MM->parse_version('lib/Linux/Event/HTTP.pm');
my %provides = map {
    my $file = "lib/$_.pm";
    $file =~ s{::}{/}g;
    $_ => {
        file    => $file,
        version => $distribution_version,
    };
} @public_modules;

WriteMakefile(
    NAME             => 'Linux::Event::HTTP',
    VERSION_FROM     => 'lib/Linux/Event/HTTP.pm',
    ABSTRACT         => 'Linux-native integration of Unblock HTTP',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    DIR              => [qw(xshttp1 xsbridge)],
    # The original public-API suite remains as migration reference. Its
    # verified baseline is recorded in docs/UNBLOCK-REBUILD-STATUS.md.
    test             => { TESTS => 't/rebuild/*.t' },
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
        'Unblock::HTTP1' => '0.12',
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'HTTP::CookieJar'     => '0.014',
        'Linux::Event'        => '0.117',
        'Unblock::HTTP'       => '0.02',
        'Uniform::HTTP'       => '0.06',
        'Uniform::HTTP::Auth' => '0.02',
        'URI'                 => 0,
    },
    META_MERGE => {
        optional_features => {
            http3 => {
                description => 'HTTP/3 over verified QUIC/TLS (optional)',
                prereqs => { runtime => { requires => {
                    'Unblock::HTTP3' => '0.13', 'Net::QUIC' => '0.06',
                } } },
            },
            http2 => {
                description => 'HTTP/2 over TLS with ALPN',
                prereqs => { runtime => { requires => { 'Unblock::HTTP2' => '0.12' } } },
            },
        },
        'meta-spec' => {
            version => 2,
        },
        no_index => {
            package => [qw(
                Linux::Event::HTTP::_Config
                Linux::Event::HTTP::_Stream
                Linux::Event::HTTP::_Transport
                Linux::Event::HTTP::_QUICSocket
                Linux::Event::HTTP::_NativeStream
                Linux::Event::HTTP::_NativeBridge
                Linux::Event::HTTP::_ClientAuth
                Linux::Event::HTTP::_ClientConnect
                Linux::Event::HTTP::_ClientUpgrade
                Linux::Event::HTTP::_HTTP1
                Linux::Event::HTTP::_HTTP1::Chunked
                Linux::Event::HTTP::_HTTP2
                Linux::Event::HTTP::_HTTP2::Client
                Linux::Event::HTTP::_HTTP2::ClientConnection
                Linux::Event::HTTP::_HTTP2::ClientSelector
                Linux::Event::HTTP::_HTTP2::ClientSelectorConnection
                Linux::Event::HTTP::_HTTP2::Server
                Linux::Event::HTTP::_HTTP2::ServerConnection
                Linux::Event::HTTP::_ServerConnect
                Linux::Event::HTTP::_Upgrade
            )],
        },
        provides => \%provides,
        resources => {
            homepage   => 'https://github.com/haxmeister/perl-Linux-Event-HTTP',
            bugtracker => {
                web => 'https://github.com/haxmeister/perl-Linux-Event-HTTP/issues',
            },
            repository => {
                type => 'git',
                url  => 'https://github.com/haxmeister/perl-Linux-Event-HTTP.git',
                web  => 'https://github.com/haxmeister/perl-Linux-Event-HTTP',
            },
        },
    },
);
