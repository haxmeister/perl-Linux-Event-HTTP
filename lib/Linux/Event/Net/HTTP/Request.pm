package Linux::Event::Net::HTTP::Request;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

sub CLONE_SKIP { 1 }

1;

__END__

=head1 NAME

Linux::Event::Net::HTTP::Request - HTTP request representation

=head1 DESCRIPTION

Request metadata is retained in native protocol state. Method, target, and
header strings are materialized as Perl scalars only when requested by the
application.

The request object does not expose HTTP/1 parser offsets or parser-specific
storage. The same application-facing methods can therefore remain useful for
later HTTP protocol versions.

Bodies are fundamentally streamed by the protocol layer. Any eventual scalar
body convenience API must be layered on top of that streaming primitive.

=head1 METHODS

=head2 method

    my $method = $request->method;

Returns the request method.

=head2 target

    my $target = $request->target;

Returns the request target exactly as received.

=head2 http_version

    my $version = $request->http_version;

Returns the HTTP version, such as C<1.1>.

=head2 header

    my $host = $request->header('Host');

Returns the first value for a header name, or undef when the header is absent.
Header-name matching is ASCII case-insensitive. Header names are not rewritten,
so distinct legal names such as C<X_Foo> and C<X-Foo> remain distinct.

=head2 header_values

    my @values = $request->header_values('Set-Cookie');

Returns all values for the named header in wire order.

=head2 header_count

    my $count = $request->header_count;

Returns the number of received header fields.

=head2 header_name

    my $name = $request->header_name($index);

Returns the original header field name at the zero-based index.

=head2 header_value

    my $value = $request->header_value($index);

Returns the header field value at the zero-based index.

=cut
