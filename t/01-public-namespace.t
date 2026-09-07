use v5.36;
use strict;
use warnings;

use Test::More;

use_ok('Linux::Event::HTTP');
use_ok('Linux::Event::HTTP::Connection');
use_ok('Linux::Event::HTTP::Request');
use_ok('Linux::Event::HTTP::Response');
use_ok('Linux::Event::HTTP::Server');

ok(
    Linux::Event::HTTP::Connection->isa('Linux::Event::Net::HTTP::Connection'),
    'public Connection facade uses the existing HTTP engine',
);

ok(
    Linux::Event::HTTP::Server->isa('Linux::Event::Net::HTTP::Server'),
    'public Server facade uses the existing listener integration',
);

ok(
    Linux::Event::Net::HTTP::Request->isa('Linux::Event::HTTP::Request'),
    'engine-created Request objects satisfy the public Request type',
);

ok(
    Linux::Event::Net::HTTP::Response->isa('Linux::Event::HTTP::Response'),
    'engine-created Response objects satisfy the public Response type',
);

{
    local $@;
    eval {
        Linux::Event::HTTP::Connection->new(
            on_request => sub { },
            on_request_final => sub { 'fast' },
        );
    };
    like(
        $@,
        qr/on_request_final is not part of the Linux::Event::HTTP public API/,
        'public Connection rejects benchmark-specific final-response callback',
    );
}

{
    local $@;
    eval {
        Linux::Event::HTTP::Server->new(
            on_request => sub { },
            on_request_final => sub { 'fast' },
        );
    };
    like(
        $@,
        qr/on_request_final is not part of the Linux::Event::HTTP public API/,
        'public Server rejects benchmark-specific final-response callback',
    );
}

{
    package T::HTTP::FastConnection;
    use parent 'Linux::Event::HTTP::Connection';
    sub on_request_final { 'fast' }

    package main;
    local $@;
    eval {
        T::HTTP::FastConnection->new(
            on_request => sub { },
        );
    };
    like(
        $@,
        qr/on_request_final is not part of the Linux::Event::HTTP public API/,
        'public Connection rejects benchmark-specific subclass method',
    );
}

done_testing;
