package Linux::Event::Net::HTTP::_Native::Response1;
use v5.36;
use strict;
use warnings;

use Linux::Event::Net::HTTP ();

our $VERSION = $Linux::Event::Net::HTTP::VERSION;

# Transitional compatibility shim for the old private Connection engine.
# Returning undef tells that engine to use the ordinary Response state machine.
# The dedicated XS implementation was benchmark-specific and is intentionally
# retired under the Linux::Event ecosystem protocol policy.
sub build_default_final ($class, $request, $body) {
    return undef;
}

1;
