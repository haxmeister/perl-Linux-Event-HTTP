package Linux::Event::Net::HTTP::_ServerConnection;
use v5.36;
use strict;
use warnings;

use parent 'Linux::Event::Net::HTTP::Connection';

use Carp qw(croak);

our $VERSION = '0.001';

sub new ($class, %option) {
    my $state = $option{data};
    croak 'HTTP Server accepted connection state is missing'
        if ref($state) ne 'HASH' || !$state->{_http_server_state};

    my $connection_class = $state->{connection_class};
    croak 'HTTP Server connection_class cannot use the private adapter directly'
        if $connection_class eq __PACKAGE__;

    $option{data} = $state->{data};

    my $callbacks = $state->{callbacks};
    for my $name (qw(on_request on_body on_request_end on_request_final)) {
        $option{$name} = $callbacks->{$name}
            if exists $callbacks->{$name};
    }

    return $connection_class->new(%option);
}

1;
