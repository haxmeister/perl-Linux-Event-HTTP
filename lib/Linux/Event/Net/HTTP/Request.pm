package Linux::Event::Net::HTTP::Request;
use v5.36;
use strict;
use warnings;

use Linux::Event::Net::HTTP::_Parser::HTTP1 ();

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

Request message framing is validated before the object is returned. Ambiguous
framing such as conflicting C<Content-Length> values or a request containing
both C<Transfer-Encoding> and C<Content-Length> is rejected.

Bodies are fundamentally streamed by L<Linux::Event::Net::HTTP::Connection>.
C<on_request> receives this Request and its paired Response after the request
head is available. Optional C<on_body> callbacks receive body byte strings, and
C<on_body_end> marks the complete request-body boundary. Content-Length and
chunked framing are removed by the protocol layer rather than exposed to the
application.

Chunked trailer sections are currently consumed to establish the message
boundary but are not yet exposed through Request. Any scalar whole-body
convenience API will be layered on top of the streaming primitive rather than
becoming the protocol's storage model.

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

=head2 body_mode

    my $mode = $request->body_mode;

Returns C<none>, C<content-length>, or C<chunked>. This reports HTTP message
framing, not whether the application considers the request method to have
content semantics.

=head2 content_length

    my $length = $request->content_length;

Returns the validated Content-Length as an integer when one was supplied, or
undef otherwise. Identical duplicate or comma-combined Content-Length values
are normalized to one numeric value during validation.

=head2 keep_alive

    if ($request->keep_alive) {
        ...
    }

Returns true when the HTTP version and Connection options permit this
connection to remain persistent after the response. C<Connection: close>
always disables persistence.

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
