package Linux::Event::HTTP;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Linux::Event::HTTP - HTTP protocol support for Linux::Event

=head1 VERSION

Version 0.001

=head1 DESCRIPTION

Linux::Event::HTTP provides HTTP communication primitives on top of
L<Linux::Event>. It is a protocol library, not a web application framework.

The public API is intentionally owned by the Linux::Event ecosystem. Parser,
serializer, compression, or standards-support libraries used internally are
implementation details and may be replaced without requiring application code
to adopt their APIs.

The initial implementation focuses on HTTP/1.1 server support. Transport, TLS,
buffering, backpressure, deadlines, and event dispatch remain responsibilities
of L<Linux::Event>.

=head1 DESIGN PRIORITIES

Protocol-layer work follows the Linux::Event ecosystem charter. The priorities
are correctness, ease of correct use, a clear public API, maintainability,
composability, and then good performance.

See F<docs/PROJECT-POLICY.md> and F<docs/ARCHITECTURE.md>.

=head1 AUTHOR

Joshua S. Day E<lt>hax@cpan.orgE<gt>

=head1 LICENSE

Copyright (C) 2026 Joshua S. Day.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl 5 itself.

=cut
