package Linux::Event::HTTP::Request;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

require Linux::Event::Net::HTTP::Request;

{
    no warnings 'once';
    push @Linux::Event::Net::HTTP::Request::ISA, __PACKAGE__
        if !Linux::Event::Net::HTTP::Request->isa(__PACKAGE__);
}

1;

__END__

=head1 NAME

Linux::Event::HTTP::Request - received HTTP request

=head1 DESCRIPTION

Request objects are created by the HTTP connection and passed to application
callbacks. Applications do not construct them directly.

The current HTTP/1 engine retains parsed request metadata internally and
materializes method, target, and header strings when requested. That storage
strategy is an implementation detail; applications should rely on the public
Request methods rather than parser-specific state.

=head1 METHODS

The request interface currently provides C<method>, C<target>, C<http_version>,
C<body_mode>, C<content_length>, C<keep_alive>, C<header>, C<header_values>,
C<header_count>, C<header_name>, and C<header_value>.

=head1 SEE ALSO

L<Linux::Event::HTTP>, L<Linux::Event::HTTP::Connection>,
L<Linux::Event::HTTP::Response>.

=cut
