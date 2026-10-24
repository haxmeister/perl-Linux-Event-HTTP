package Linux::Event::HTTP::_NativeBridge;
use v5.36;
use Linux::Event::HTTP ();
use Unblock::HTTP1::NativeABI 0.12 ();
require XSLoader;
XSLoader::load(__PACKAGE__, $Linux::Event::HTTP::VERSION);

sub definition {
    return { provider => \&_operations_address,
        abi_version => 1, operations_address => _operations_address() };
}

sub _input_operations_address {
    return Unblock::HTTP1::NativeABI::definition()->{operations_address};
}

1;
