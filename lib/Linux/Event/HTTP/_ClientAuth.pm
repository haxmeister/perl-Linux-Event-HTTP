package Linux::Event::HTTP::_ClientAuth;
use v5.36;
use strict;
use warnings;

use Scalar::Util qw(blessed);
use Uniform::HTTP::Auth 0.01 ();

sub validate_manager ($value, $where, $name) {
    return undef if !defined $value;
    die "$where: $name must be a Uniform::HTTP::Auth object"
        if !blessed($value) || !$value->isa('Uniform::HTTP::Auth');
    return $value;
}

sub prepare_retry (%arg) {
    my $manager = $arg{manager} or return undef;
    my @challenge = $arg{response}->header_values($arg{challenge_header});
    return undef if !@challenge;

    my %prepare = (
        challenge_headers => \@challenge,
        origin            => $arg{origin},
        method            => $arg{method},
        request_target    => $arg{request_target},
    );

    if (!$arg{has_stream_body}) {
        $prepare{entity_body} = $arg{has_body}
            ? (defined($arg{body}) ? $arg{body} : '')
            : '';
    }

    my $result;
    my $ok = eval {
        $result = $manager->prepare_authentication(%prepare);
        1;
    };
    if (!$ok) {
        my $error = "$@";
        $error =~ s/\s+\z//;
        return {
            error => "$arg{label} authentication preparation failed: $error",
        };
    }

    return undef if !$result;

    if ($arg{has_stream_body}) {
        return {
            error => "cannot automatically retry $arg{status} $arg{label} authentication for a streaming Request body because the producer is not replayable",
        };
    }

    return {
        scheme => $result->{scheme},
        value  => $result->{value},
    };
}

1;
