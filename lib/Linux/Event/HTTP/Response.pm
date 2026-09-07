package Linux::Event::HTTP::Response;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

require Linux::Event::Net::HTTP::Response;

{
    no warnings 'once';
    push @Linux::Event::Net::HTTP::Response::ISA, __PACKAGE__
        if !Linux::Event::Net::HTTP::Response->isa(__PACKAGE__);
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Response - writable HTTP response

=head1 DESCRIPTION

Response objects are created by the HTTP connection and passed to application
callbacks. They are the writable handle for an HTTP transaction and may be
retained for deferred completion.

Applications should use the public response operations rather than depend on
HTTP/1 serializer details. The current interface supports status and header
metadata, C<write>, C<end>, and validated protocol upgrade.

=head1 SEE ALSO

L<Linux::Event::HTTP>, L<Linux::Event::HTTP::Request>,
L<Linux::Event::HTTP::Connection>.

=cut
