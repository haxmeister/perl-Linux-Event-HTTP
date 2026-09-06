use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Net::HTTP::_Parser::HTTP1::Chunked',
    VERSION_FROM     => '../lib/Linux/Event/Net/HTTP.pm',
    ABSTRACT         => 'Private native HTTP/1 chunked decoder for Linux::Event::Net::HTTP',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Chunked.xs' => 'Chunked.c' },
    OBJECT           => 'Chunked$(OBJ_EXT)',
    clean            => { FILES => 'Chunked.c' },
);
