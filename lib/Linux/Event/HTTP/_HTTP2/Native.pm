package Linux::Event::HTTP::_HTTP2::Native;
use v5.36;
use strict;
use warnings;

use XSLoader;

our $VERSION = '0.002';

XSLoader::load(__PACKAGE__, $VERSION);

sub new_client ($class, %option) {
    my $callbacks = delete($option{callbacks}) // {};
    die 'new_client(): callbacks must be a hash reference'
        if ref($callbacks) ne 'HASH';
    die 'new_client(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    return $class->_new(0, $callbacks);
}

sub send_connection_preface ($self, %option) {
    my $max_concurrent_streams =
        delete($option{max_concurrent_streams}) // 100;
    my $max_header_list_size =
        delete($option{max_header_list_size}) // 65_536;

    die 'send_connection_preface(): unknown options: '
        . join(', ', sort keys %option)
        if %option;
    for my $setting (
        [ max_concurrent_streams => $max_concurrent_streams ],
        [ max_header_list_size   => $max_header_list_size ],
    ) {
        die "send_connection_preface(): $setting->[0] must be a positive integer"
            if ref($setting->[1])
            || "$setting->[1]" !~ /\A[0-9]+\z/
            || $setting->[1] < 1
            || $setting->[1] > 4_294_967_295;
    }

    $self->_submit_settings(
        0 + $max_concurrent_streams,
        0 + $max_header_list_size,
    );
    return $self;
}

sub _copy_headers ($operation, $headers) {
    $headers //= [];
    die "$operation(): headers must be an array reference"
        if ref($headers) ne 'ARRAY';

    my @copy;
    for my $pair (@$headers) {
        die "$operation(): each header must be a [name, value] pair"
            if ref($pair) ne 'ARRAY' || @$pair != 2;
        my ($name, $value) = @$pair;
        die "$operation(): header name and value must be scalars"
            if !defined($name) || ref($name)
            || !defined($value) || ref($value);
        push @copy, [ "$name", "$value" ];
    }
    return \@copy;
}

sub _body_provider ($operation, $body, $data_callback, $callback_data) {
    if (defined($data_callback)) {
        die "$operation(): data_callback must be a coderef"
            if ref($data_callback) ne 'CODE';
        die "$operation(): body and data_callback cannot both be supplied"
            if defined $body;
        return (undef, $data_callback, $callback_data);
    }

    return (undef, undef, undef) if !defined $body;
    if (ref($body) eq 'CODE') {
        return (undef, $body, $callback_data);
    }
    die "$operation(): body must be a scalar or coderef" if ref $body;
    return ("$body", undef, undef);
}

sub _compat_submit_request ($self, %option) {
    my $method    = delete($option{method}) // 'GET';
    my $path      = delete($option{path}) // '/';
    my $scheme    = delete($option{scheme}) // 'https';
    my $authority = delete($option{authority}) // '';
    my $headers   = _copy_headers(
        'submit_request', delete $option{headers},
    );
    my $body = delete $option{body};
    my $data_callback = delete $option{data_callback};
    my $callback_data = delete $option{callback_data};

    die 'submit_request(): method, path, scheme, and authority must be scalars'
        if ref($method) || ref($path) || ref($scheme) || ref($authority);
    die 'submit_request(): unknown options: ' . join(', ', sort keys %option)
        if %option;

    my ($static, $callback, $data) = _body_provider(
        'submit_request', $body, $data_callback, $callback_data,
    );

    my @block = (
        [ ':method',    "$method" ],
        [ ':path',      "$path" ],
        [ ':scheme',    "$scheme" ],
        [ ':authority', "$authority" ],
        @$headers,
    );

    return $self->_submit_request_full(
        \@block, $static, $callback, $data,
    );
}

sub _compat_submit_response ($self, $stream_id, %option) {
    my $status = delete($option{status}) // 200;
    my $headers = _copy_headers(
        'submit_response', delete $option{headers},
    );
    my $body = delete $option{body};
    my $data_callback = delete $option{data_callback};
    my $callback_data = delete $option{callback_data};

    die 'submit_response(): status must be a three-digit integer'
        if ref($status) || "$status" !~ /\A[1-9][0-9][0-9]\z/;
    die 'submit_response(): unknown options: '
        . join(', ', sort keys %option)
        if %option;

    my ($static, $callback, $data) = _body_provider(
        'submit_response', $body, $data_callback, $callback_data,
    );

    my @block = (
        [ ':status', "$status" ],
        @$headers,
    );

    $self->_submit_response_full(
        $stream_id, \@block, $static, $callback, $data,
    );
    return $stream_id;
}


sub _raw_consumer_definition ($class) {
    return {
        provider           => \&_raw_consumer_operations_address,
        abi_version        => 1,
        operations_address => _raw_consumer_operations_address(),
    };
}

sub new_server ($class, %option) {
    my $callbacks = delete($option{callbacks}) // {};
    die 'new_server(): callbacks must be a hash reference'
        if ref($callbacks) ne 'HASH';
    die 'new_server(): unknown options: ' . join(', ', sort keys %option)
        if %option;
    return $class->_new(1, $callbacks);
}

{
    no warnings 'redefine';
    *submit_request  = \&_compat_submit_request;
    *submit_response = \&_compat_submit_response;
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::_HTTP2::Native - private libnghttp2 bridge

=head1 DESCRIPTION

Experimental private XS boundary between Linux::Event::HTTP and libnghttp2.
It deliberately exposes only the session primitives needed by the HTTP/2
executors and is not a general-purpose Perl nghttp2 binding.

=cut
