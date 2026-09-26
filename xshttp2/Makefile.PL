use strict;
use warnings;
use ExtUtils::MakeMaker;

my $cflags = `pkg-config --cflags libnghttp2 2>/dev/null`;
my $libs   = `pkg-config --libs libnghttp2 2>/dev/null`;
chomp($cflags, $libs);

$libs ||= '-lnghttp2';

WriteMakefile(
    NAME             => 'Linux::Event::HTTP::_HTTP2::Native',
    VERSION_FROM     => '../lib/Linux/Event/HTTP.pm',
    ABSTRACT         => 'Private native libnghttp2 bridge for Linux::Event::HTTP',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Native.xs' => 'Native.c' },
    OBJECT           => 'Native$(OBJ_EXT)',
    INC              => $cflags,
    LIBS             => [ $libs ],
    clean            => { FILES => 'Native.c' },
);
