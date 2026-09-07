from pathlib import Path
import re


def replace_exact(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f'{path}: expected {count} exact matches, found {actual}: {old[:80]!r}')
    p.write_text(text.replace(old, new))


def sub_exact(path, pattern, repl, count=1, flags=0):
    p = Path(path)
    text = p.read_text()
    changed, actual = re.subn(pattern, repl, text, count=count, flags=flags)
    if actual != count:
        raise SystemExit(f'{path}: expected {count} regex matches, found {actual}: {pattern[:100]!r}')
    p.write_text(changed)


# Server::Connection: one private HTTP/1 loader and no public fast-final handler.
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    'use Linux::Event::HTTP::_HTTP1 ();\nuse Linux::Event::HTTP::_HTTP1 ();\nuse Linux::Event::HTTP::_HTTP1 ();\n',
    'use Linux::Event::HTTP::_HTTP1 ();\n',
)
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    "    croak 'new(): Connection cannot use message framing callbacks'\n"
    "        if exists($option{on_message}) || exists($option{on_messages});\n\n",
    "    croak 'new(): Connection cannot use message framing callbacks'\n"
    "        if exists($option{on_message}) || exists($option{on_messages});\n"
    "    croak 'new(): on_request_final was removed; use on_request and Response->end'\n"
    "        if exists $option{on_request_final};\n\n",
)
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    "    my $on_request_end = _take_http_handler($class, 'on_request_end', \\%option);\n"
    "    my $on_request_final = _take_http_handler(\n"
    "        $class, 'on_request_final', \\%option,\n"
    "    );\n",
    "    my $on_request_end = _take_http_handler($class, 'on_request_end', \\%option);\n",
)
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    '    $self->{_http_on_request_final} = $on_request_final;\n',
    '',
)
sub_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    r'\nsub _invoke_request_final \(\$self, \$request\) \{.*?\n\}\n\nsub _clear_transaction',
    '\nsub _clear_transaction',
    flags=re.S,
)
sub_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    r'\nsub _complete_request_final_fallback \(\$self, \$request, \$body\) \{.*?\n\}\n\nsub _drive_http1',
    '\nsub _drive_http1',
    flags=re.S,
)
sub_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    r'\n        if \(\$bodyless && \$self->\{_http_on_request_final\}\) \{.*?\n        \}\n\n        my \$response',
    '\n\n        my $response',
    flags=re.S,
)
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    "Applications use C<on_request>, optional C<on_body>, optional\n"
    "C<on_request_end>, and optionally C<on_request_final>. Named methods are\n"
    "resolved and cached by connection class. Direct construction may supply the same\n"
    "names as constructor callbacks when lexical application scope is preferable.\n\n"
    "Ordinary request handling pairs each Request with one\n"
    "L<Linux::Event::HTTP::Response> created by Connection, and the same Request\n"
    "and Response objects are passed to the ordinary callbacks for that transaction.\n"
    "A defined C<on_request_final> result may complete a bodyless request before a\n"
    "Response object is allocated.\n",
    "Applications use C<on_request>, optional C<on_body>, and optional\n"
    "C<on_request_end>. Named methods are resolved and cached by connection class.\n"
    "Direct construction may supply the same names as constructor callbacks when\n"
    "lexical application scope is preferable.\n\n"
    "Every dispatched Request is paired with one L<Linux::Event::HTTP::Response>\n"
    "created by Connection, and the same Request and Response objects are passed to\n"
    "the callbacks for that transaction.\n",
)
sub_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    r'=head2 on_request_final\n.*?\n=head2 on_request\n',
    '=head2 on_request\n',
    flags=re.S,
)
sub_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    r'\n        on_request_final => sub \(\$conn, \$req\) \{\n            return "ok\\n" if \$req->target eq \'/health\';\n            return undef;\n        \},',
    '',
)
replace_exact(
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    "For the narrower bodyless/default-C<200 OK> case, C<on_request_final> may return\n"
    "the complete scalar body before a Response object is constructed. This is an\n"
    "optional performance path; it does not replace the Response API.\n\n",
    "Scalar C<end> is the ordinary complete-response path. Eligible default scalar\n"
    "responses may use a private native finalization path transparently; applications\n"
    "do not select a separate performance API.\n\n",
)

# Server: reject the removed option clearly and forward only real HTTP callbacks.
replace_exact(
    'lib/Linux/Event/HTTP/Server.pm',
    "    croak 'new(): HTTP Server cannot use message framing callbacks'\n"
    "        if exists($option{on_message}) || exists($option{on_messages});\n\n",
    "    croak 'new(): HTTP Server cannot use message framing callbacks'\n"
    "        if exists($option{on_message}) || exists($option{on_messages});\n"
    "    croak 'new(): on_request_final was removed; use on_request and Response->end'\n"
    "        if exists $option{on_request_final};\n\n",
)
replace_exact(
    'lib/Linux/Event/HTTP/Server.pm',
    '    for my $name (qw(on_request on_body on_request_end on_request_final)) {\n',
    '    for my $name (qw(on_request on_body on_request_end)) {\n',
)
replace_exact(
    'lib/Linux/Event/HTTP/Server.pm',
    "C<on_request> method. Optional C<on_body>, C<on_request_end>, and\n"
    "C<on_request_final> callbacks use the same signatures and semantics as\n"
    "L<Linux::Event::HTTP::Server::Connection> and are retained once by the Server.\n",
    "C<on_request> method. Optional C<on_body> and C<on_request_end> callbacks use\n"
    "the same signatures and semantics as L<Linux::Event::HTTP::Server::Connection>\n"
    "and are retained once by the Server.\n",
)
sub_exact(
    'lib/Linux/Event/HTTP/Server.pm',
    r'\n=head2 Complete final-response callback\n.*?\n=head2 Connection subclass form\n',
    '\n=head2 Connection subclass form\n',
    flags=re.S,
)
replace_exact(
    'lib/Linux/Event/HTTP/Server.pm',
    '            -> HTTP::Connection\n',
    '            -> HTTP::Server::Connection\n',
)

replace_exact(
    'lib/Linux/Event/HTTP/_ServerConnection.pm',
    '    for my $name (qw(on_request on_body on_request_end on_request_final)) {\n',
    '    for my $name (qw(on_request on_body on_request_end)) {\n',
)

# Server integration tests: remove shortcut-specific success cases and assert rejection.
sub_exact(
    't/40-server.t',
    r'\n\$loop = Linux::Event::Loop->new;\nmy \$final = \{.*?\n\{\n    package T::ServerConnection;',
    '\n{\n    package T::ServerConnection;',
    flags=re.S,
)
sub_exact(
    't/40-server.t',
    r'\n\$ok = eval \{\n    Linux::Event::HTTP::Server->new\(\n        loop => Linux::Event::Loop->new,\n        host => \'127\.0\.0\.1\',\n        port => 0,\n        on_request_final => sub \{ return "only\\n" \},\n    \);\n    1;\n\};\nok\(!\$ok, \'on_request_final alone does not replace general on_request\'\);\nlike\(\$@, qr/requires on_request/, \'final-only Server explains fallback requirement\'\);',
    "\n$ok = eval {\n"
    "    Linux::Event::HTTP::Server->new(\n"
    "        loop => Linux::Event::Loop->new,\n"
    "        host => '127.0.0.1',\n"
    "        port => 0,\n"
    "        on_request => sub ($conn, $req, $res) { $res->end(\"ok\\n\") },\n"
    "        on_request_final => sub { return \"old\\n\" },\n"
    "    );\n"
    "    1;\n"
    "};\n"
    "ok(!$ok, 'Server rejects removed on_request_final option');\n"
    "like($@, qr/on_request_final was removed/, 'Server gives migration guidance');",
    flags=re.S,
)

# Direct Connection gets the same explicit rejection before transport setup.
replace_exact(
    't/30-connection.t',
    '\ndone_testing;',
    "\nmy $removed_ok = eval {\n"
    "    Linux::Event::HTTP::Server::Connection->new(\n"
    "        on_request => sub { },\n"
    "        on_request_final => sub { return \"old\\n\" },\n"
    "    );\n"
    "    1;\n"
    "};\n"
    "ok(!$removed_ok, 'direct Connection rejects removed on_request_final option');\n"
    "like($@, qr/on_request_final was removed/, 'Connection gives migration guidance');\n\n"
    "done_testing;",
)

# Replace the former public-fast-path integration test with canonical Response->end coverage.
Path('t/50-final-response.t').write_text(r'''use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::IO::Sock::Stream;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server::Connection;
use Linux::Event::HTTP::Server;

{
    package T::FinalResponse;
    use parent 'Linux::Event::HTTP::Server::Connection';

    sub on_request ($self, $request, $response) {
        my $state = $self->data;
        ++$state->{request_hits};
        die "request boom\n" if $state->{request_die};

        if (($state->{mode} // '') eq 'invalid-body') {
            $response->end([]);
        } elsif (($state->{mode} // '') ne 'body') {
            $response->end($state->{response_body});
        }
        return;
    }

    sub on_body ($self, $request, $response, $bytes) {
        ++$self->data->{body_hits};
        $self->data->{body} .= $bytes;
        return;
    }

    sub on_request_end ($self, $request, $response) {
        my $state = $self->data;
        ++$state->{request_end_hits};
        if (($state->{mode} // '') eq 'body') {
            $response->end('post:' . $state->{body} . "\n");
        }
        return;
    }
}

sub new_state (%extra) {
    return {
        wire => '',
        request_hits => 0,
        body_hits => 0,
        request_end_hits => 0,
        body => '',
        response_body => "fast\n",
        %extra,
    };
}

sub run_exchange ($request_wire, $state, $expected_wire_body = undef) {
    my $loop = Linux::Event::Loop->new;
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        data => $state,
        connection_class => 'T::FinalResponse',
    );

    my $guard = Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 2,
        on_timer => sub ($timer) {
            die "final-response integration test timed out\n";
        },
    );

    my $done = 0;
    my $finish = sub ($stream) {
        return if $done;
        my $head_end = index($state->{wire}, "\r\n\r\n");
        return if $head_end < 0;
        my $head_len = $head_end + 4;
        my $head = substr($state->{wire}, 0, $head_len);
        return if $head !~ /\r\nContent-Length:\s*(\d+)\r\n/i;
        my $body_len = defined($expected_wire_body) ? $expected_wire_body : 0 + $1;
        return if length($state->{wire}) < $head_len + $body_len;

        $done = 1;
        $guard->cancel;
        $stream->close;
        $server->close;
        $loop->stop;
    };

    Linux::Event::IO::Sock::Stream->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->port,
        on_ready => sub ($stream) {
            $stream->write($request_wire);
        },
        on_data => sub ($stream, $bytes) {
            $state->{wire} .= $bytes;
            $finish->($stream);
        },
        on_eof => sub ($stream) {
            $finish->($stream);
            die "server closed before complete final response\n" if !$done;
        },
        on_error => sub ($stream, $error) {
            die "final-response client failed: $error\n";
        },
    );

    $loop->run;
    ok($done, 'exchange completed');
    return $state->{wire};
}

my $state = new_state(response_body => "fast\n");
my $wire = run_exchange(
    "GET /fast HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 200 OK\r\nContent-Length: 5\r\n\r\nfast\n\z/s,
    'ordinary on_request plus Response->end completes eligible scalar response',
);
is($state->{request_hits}, 1, 'ordinary request callback runs once');

$state = new_state(response_body => 'head-body');
$wire = run_exchange(
    "HEAD /head HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
    0,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 200 OK\r\nContent-Length: 9\r\n\r\n\z/s,
    'HEAD keeps representation length while suppressing response body bytes',
);
is($state->{request_hits}, 1, 'HEAD uses the same ordinary request callback');

$state = new_state(response_body => "old\n");
$wire = run_exchange(
    "GET /old HTTP/1.0\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.0 200 OK\r\nContent-Length: 4\r\n\r\nold\n\z/s,
    'HTTP/1.0 uses ordinary Response serialization',
);
is($state->{request_hits}, 1, 'HTTP/1.0 uses the same ordinary request callback');

$state = new_state(mode => 'body');
$wire = run_exchange(
    "POST /body HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Content-Length: 4\r\n\r\n" .
        "data",
    $state,
);
like($wire, qr/\r\n\r\npost:data\n\z/s, 'body-bearing request stays on streaming request path');
is($state->{request_hits}, 1, 'body-bearing request invokes ordinary on_request');
is($state->{body}, 'data', 'request body bytes are delivered');
is($state->{request_end_hits}, 1, 'request-end callback completes body response');

$state = new_state(request_die => 1);
$wire = run_exchange(
    "GET /boom HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 500 [^\r\n]+\r\nContent-Length: 0\r\nConnection: close\r\n\r\n\z/s,
    'ordinary request callback exception becomes protocol-safe 500',
);
is($state->{request_hits}, 1, 'failing ordinary request callback runs once');

$state = new_state(mode => 'invalid-body');
$wire = run_exchange(
    "GET /invalid-body HTTP/1.1\r\nHost: example.test\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 500 [^\r\n]+\r\nContent-Length: 0\r\nConnection: close\r\n\r\n\z/s,
    'invalid Response->end body becomes protocol-safe 500',
);
is($state->{request_hits}, 1, 'invalid body is handled inside ordinary request callback');

$state = new_state(response_body => "ignored\n");
$wire = run_exchange(
    "GET /expect HTTP/1.1\r\n" .
        "Host: example.test\r\n" .
        "Expect: nonsense\r\n\r\n",
    $state,
);
like(
    $wire,
    qr/\AHTTP\/1\.1 417 [^\r\n]+\r\nContent-Length: 0\r\nConnection: close\r\n\r\n\z/s,
    'unsupported Expect is rejected before application dispatch',
);
is($state->{request_hits}, 0, 'invalid Expect never reaches on_request');

done_testing;
''')

# Focused benchmark now measures only supported canonical callback shapes.
bench = Path('bench/run-http-final-response.pl')
text = bench.read_text()
text, n = re.subn(
    r'\n\{\n    package Linux::Event::HTTP::Bench::FastFinalConnection;.*?\n\}\n',
    '\n', text, count=1, flags=re.S,
)
if n != 1:
    raise SystemExit('bench/run-http-final-response.pl: FastFinalConnection block not found')
text = text.replace(
    'my @mode = qw(ordinary_request ordinary_request_end fast_final);',
    'my @mode = qw(ordinary_request ordinary_request_end);',
)
text = text.replace(
    "    ordinary_request_end => 'on_request_end -> Response->end',\n"
    "    fast_final           => 'integrated fast-final return',\n",
    "    ordinary_request_end => 'on_request_end -> Response->end',\n",
)
text = text.replace(
    "    ordinary_request_end => 'Linux::Event::HTTP::Bench::OrdinaryRequestEndConnection',\n"
    "    fast_final           => 'Linux::Event::HTTP::Bench::FastFinalConnection',\n",
    "    ordinary_request_end => 'Linux::Event::HTTP::Bench::OrdinaryRequestEndConnection',\n",
)
text = text.replace(
    "say 'Linux::Event::HTTP production-shaped fast-final experiment';",
    "say 'Linux::Event::HTTP response finalization benchmark';",
)
text = text.replace(
    "say 'ordinary_request = real Connection on_request($conn,$req,$res) + Response->end with early bodyless completion';\n"
    "say 'ordinary_request_end = real Connection no-op on_request + on_request_end($conn,$req,$res) + Response->end';\n"
    "say 'fast_final = real Connection on_request_final($conn,$req) returning scalar body before Response allocation';",
    "say 'ordinary_request = real Connection on_request($conn,$req,$res) + Response->end';\n"
    "say 'ordinary_request_end = real Connection no-op on_request + on_request_end($conn,$req,$res) + Response->end';",
)
text, n = re.subn(
    r'\nfor my \$baseline \(qw\(ordinary_request ordinary_request_end\)\) \{.*?\n\}\nmy \$ordinary_vs_end',
    '\nmy $ordinary_vs_end', text, count=1, flags=re.S,
)
if n != 1:
    raise SystemExit('bench/run-http-final-response.pl: fast_final gain block not found')
text = text.replace(
    'usage: bench/run-http-fast-final-experiment.pl [options]',
    'usage: bench/run-http-final-response.pl [options]',
)
bench.write_text(text)

# Shared comparison server exposes only supported natural/request-end modes.
server_bench = Path('bench/servers/linuxevent-http.pl')
text = server_bench.read_text()
text, n = re.subn(
    r'\n\{\n    package Linux::Event::HTTP::Bench::FastFinalCompareConnection;.*?\n\}\n',
    '\n', text, count=1, flags=re.S,
)
if n != 1:
    raise SystemExit('bench/servers/linuxevent-http.pl: fast-final class block not found')
text = text.replace(
    "my $connection_class = $mode eq 'natural'\n"
    "    ? 'Linux::Event::HTTP::Bench::NaturalCompareConnection'\n"
    "    : $mode eq 'request-end'\n"
    "        ? 'Linux::Event::HTTP::Bench::RequestEndCompareConnection'\n"
    "        : $mode eq 'fast-final'\n"
    "            ? 'Linux::Event::HTTP::Bench::FastFinalCompareConnection'\n"
    "            : die \"unknown BENCH_LINUXEVENT_MODE: $mode\\n\";",
    "my $connection_class = $mode eq 'natural'\n"
    "    ? 'Linux::Event::HTTP::Bench::NaturalCompareConnection'\n"
    "    : $mode eq 'request-end'\n"
    "        ? 'Linux::Event::HTTP::Bench::RequestEndCompareConnection'\n"
    "        : die \"unknown BENCH_LINUXEVENT_MODE: $mode\\n\";",
)
server_bench.write_text(text)

# README: one normal request API, transparent optimization, no framework-adapter promises.
readme = Path('README.md')
text = readme.read_text()
text, n = re.subn(
    r'\nFor simple bodyless requests that can return the default complete response in\none scalar, an optional final-response callback avoids allocating the general\nResponse transaction machinery:.*?\nA Connection subclass remains the declarative form',
    "\nScalar `Response->end(...)` is also the complete-response path for simple\nbodyless requests. Eligible default scalar responses may use a private native\nfinalization path internally; applications use the same `on_request`/`Response`\nAPI whether that optimization applies or not.\n\nA Connection subclass remains the declarative form",
    text, count=1, flags=re.S,
)
if n != 1:
    raise SystemExit('README.md: public final-response section not found')
text = text.replace('`Linux::Event::Net::WebSocket`', '`Linux::Event::WebSocket`')
text = text.replace(
    'Applications use the Response object but do not construct it or pass it back to\n'
    'the Connection. Response is the writable handle for a general-path transaction\n'
    'and may be retained and completed from a later event.',
    'Applications use the Response object but do not construct it or pass it back to\n'
    'the Connection. Response is the writable handle for a server transaction and may\n'
    'be retained and completed from a later event.',
)
readme.write_text(text)

# Unreleased Changes should describe the API that will actually ship.
changes = Path('Changes')
text = changes.read_text()
text = text.replace(
    '    - Reserve Server, Connection, Request, and Response public namespaces.\n',
    '    - Use the flat Linux::Event::HTTP namespace and make the server-side transport\n'
    '      class Linux::Event::HTTP::Server::Connection, leaving Client structure for later.\n',
)
text = text.replace(
    '    - Bind HTTP Connection directly to Linux::Event::IO::Sock::Stream.\n',
    '    - Bind HTTP Server::Connection directly to Linux::Event::IO::Sock::Stream.\n',
)
text = text.replace(
    '    - Add optional on_request_final($connection, $request) for validated bodyless\n'
    '      complete responses while retaining on_request as the required general fallback.\n'
    '    - Add a narrow native default-final response builder and focused final-response\n'
    '      benchmark, with ordinary Response fallback for HEAD, HTTP/1.0, and body-bearing requests.\n',
    '    - Keep on_request -> Response as the single server request API while transparently\n'
    '      optimizing eligible scalar Response->end completions with a narrow native builder.\n'
    '    - Consolidate request parsing, chunked decoding, response serialization, and the\n'
    '      default-final builder into one private Linux::Event::HTTP::_HTTP1 extension.\n'
    '    - Keep a focused response-finalization benchmark for supported callback shapes.\n',
)
changes.write_text(text)

# Hard checks: the old public API/mode must survive nowhere except historical handoff notes.
for needle in ('on_request_final', 'fast-final'):
    offenders = []
    for path in Path('.').rglob('*'):
        if not path.is_file() or '.git' in path.parts or path == Path('handoff.md'):
            continue
        try:
            data = path.read_text()
        except UnicodeDecodeError:
            continue
        if needle in data:
            offenders.append(str(path))
    if offenders:
        raise SystemExit(f'{needle} still present outside handoff.md: {offenders}')
