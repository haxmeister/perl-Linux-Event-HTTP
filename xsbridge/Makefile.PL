use strict;
use warnings;
use ExtUtils::MakeMaker;
use Unblock::HTTP1::NativeABI ();
my $inc = Unblock::HTTP1::NativeABI::native_include_dir();
WriteMakefile(
    NAME => 'Linux::Event::HTTP::_NativeBridge',
    VERSION_FROM => '../lib/Linux/Event/HTTP.pm',
    PM => {},
    INC => qq{-I"$inc" -I../xshttp1},
    XS => { 'NativeBridge.xs' => 'NativeBridge.c' },
    OBJECT => 'NativeBridge$(OBJ_EXT)',
    clean => { FILES => 'NativeBridge.c' },
);
