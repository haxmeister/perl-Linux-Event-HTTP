use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Net::HTTP::_Native::Response1',
    VERSION_FROM     => '../lib/Linux/Event/Net/HTTP.pm',
    ABSTRACT         => 'Private native HTTP/1 final-response fast path for Linux::Event::Net::HTTP',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Response1.xs' => 'Response1.c' },
    OBJECT           => 'Response1$(OBJ_EXT)',
    clean            => { FILES => 'Response1.c' },
);
