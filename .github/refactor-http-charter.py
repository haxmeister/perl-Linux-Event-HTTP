from pathlib import Path
import re
import subprocess


def tracked_files():
    out = subprocess.check_output(['git', 'ls-files', '-z'])
    return [Path(p.decode()) for p in out.split(b'\0') if p]


subprocess.check_call([
    'git', 'mv', 'lib/Linux/Event/HTTP.pm', 'lib/Linux/Event/HTTP.pm'
])
subprocess.check_call([
    'git', 'mv', 'lib/Linux/Event/HTTP', 'lib/Linux/Event/HTTP'
])
Path('lib/Linux/Event/HTTP/Server').mkdir(parents=True, exist_ok=True)
subprocess.check_call([
    'git', 'mv',
    'lib/Linux/Event/HTTP/Server/Connection.pm',
    'lib/Linux/Event/HTTP/Server/Connection.pm',
])

replacements = [
    (b'Linux::Event::HTTP', b'Linux::Event::HTTP'),
    (b'Linux::Event::HTTP::Server::Connection', b'Linux::Event::HTTP::Server::Connection'),
    (b'lib/Linux/Event/HTTP', b'lib/Linux/Event/HTTP'),
    (b'lib/Linux/Event/HTTP/Server/Connection.pm', b'lib/Linux/Event/HTTP/Server/Connection.pm'),
    (b'perl-Linux-Event-HTTP', b'perl-Linux-Event-HTTP'),
    (b'Linux-Event-HTTP', b'Linux-Event-HTTP'),
]

for path in tracked_files():
    if not path.is_file():
        continue
    data = path.read_bytes()
    changed = data
    for old, new in replacements:
        changed = changed.replace(old, new)
    if changed != data:
        path.write_bytes(changed)

# Collapse the three private native extensions into xshttp1/HTTP1.xs.
# Plain C helpers must remain before the first XS MODULE declaration.
http1_path = Path('xshttp1/HTTP1.xs')
http1 = http1_path.read_text()
chunked = Path('xschunked/Chunked.xs').read_text()
response1 = Path('xsresponse1/Response1.xs').read_text()

assert 'static struct phr_chunked_decoder *\ndecoder_from_object' in chunked
assert 'static int\nrequest_method_is_head' in response1
assert 'static int\nrequest_method_is_head' not in http1
assert 'decoder_from_object' not in http1
assert 'request_state_from_object' in http1

http1 = http1.replace(
    'MODULE = Linux::Event::HTTP::_HTTP1',
    'MODULE = Linux::Event::HTTP::_HTTP1',
).replace(
    'PACKAGE = Linux::Event::HTTP::_HTTP1',
    'PACKAGE = Linux::Event::HTTP::_HTTP1',
)

main_module = http1.index('MODULE = ')
main_c = http1[:main_module]
main_xsubs = http1[main_module:]

chunk_helper_start = chunked.index(
    'static struct phr_chunked_decoder *\ndecoder_from_object'
)
chunk_module = chunked.index('MODULE = ')
chunk_helpers = chunked[chunk_helper_start:chunk_module]
chunk_xsubs = chunked[chunk_module:].replace(
    'MODULE = Linux::Event::HTTP::_HTTP1::Chunked',
    'MODULE = Linux::Event::HTTP::_HTTP1',
).replace(
    'PACKAGE = Linux::Event::HTTP::_HTTP1::Chunked',
    'PACKAGE = Linux::Event::HTTP::_HTTP1::Chunked',
)

response_helper_start = response1.index('static int\nrequest_method_is_head')
response_module = response1.index('MODULE = ')
response_helpers = response1[response_helper_start:response_module]
response_xsubs = response1[response_module:].replace(
    'MODULE = Linux::Event::HTTP::_HTTP1',
    'MODULE = Linux::Event::HTTP::_HTTP1',
).replace(
    'PACKAGE = Linux::Event::HTTP::_HTTP1',
    'PACKAGE = Linux::Event::HTTP::_HTTP1',
)

http1_path.write_text(
    main_c.rstrip() + '\n\n'
    + chunk_helpers.strip() + '\n\n'
    + response_helpers.strip() + '\n\n'
    + main_xsubs.rstrip() + '\n\n'
    + chunk_xsubs.strip() + '\n\n'
    + response_xsubs.strip() + '\n'
)

Path('lib/Linux/Event/HTTP/_HTTP1.pm').write_text(
    "package Linux::Event::HTTP::_HTTP1;\n"
    "use v5.36;\n"
    "use strict;\n"
    "use warnings;\n\n"
    "our $VERSION = '0.001';\n\n"
    "require XSLoader;\n"
    "XSLoader::load(__PACKAGE__);\n\n"
    "sub CLONE_SKIP { 1 }\n\n"
    "1;\n"
)

second = [
    (b'Linux::Event::HTTP::_HTTP1::Chunked', b'Linux::Event::HTTP::_HTTP1::Chunked'),
    (b'Linux::Event::HTTP::_HTTP1', b'Linux::Event::HTTP::_HTTP1'),
    (b'Linux::Event::HTTP::_HTTP1', b'Linux::Event::HTTP::_HTTP1'),
]
for path in tracked_files() + [Path('lib/Linux/Event/HTTP/_HTTP1.pm')]:
    if not path.is_file():
        continue
    data = path.read_bytes()
    changed = data
    for old, new in second:
        changed = changed.replace(old, new)
    if changed != data:
        path.write_bytes(changed)

makefile = Path('Makefile.PL')
text = makefile.read_text()
text = text.replace(
    "DIR              => [qw(xshttp1 xschunked xsresponse1)],",
    "DIR              => [qw(xshttp1)],",
)
text = re.sub(
    r"        no_index => \{\n            package => \[qw\(\n.*?            \)\],\n        \},",
    "        no_index => {\n"
    "            package => [qw(\n"
    "                Linux::Event::HTTP::_HTTP1\n"
    "                Linux::Event::HTTP::_HTTP1::Chunked\n"
    "                Linux::Event::HTTP::_ServerConnection\n"
    "                Linux::Event::HTTP::_Upgrade\n"
    "            )],\n"
    "        },",
    text,
    flags=re.S,
)
makefile.write_text(text)

xs_make = Path('xshttp1/Makefile.PL')
text = xs_make.read_text()
text = text.replace(
    "NAME             => 'Linux::Event::HTTP::_HTTP1'",
    "NAME             => 'Linux::Event::HTTP::_HTTP1'",
)
text = text.replace(
    'Private native HTTP/1 parser for Linux::Event::HTTP',
    'Private native HTTP/1 wire primitives for Linux::Event::HTTP',
)
xs_make.write_text(text)

subprocess.check_call([
    'git', 'rm', '-r', '-f', 'lib/Linux/Event/HTTP/_Parser'
])
subprocess.check_call([
    'git', 'rm', '-r', '-f', 'lib/Linux/Event/HTTP/_Native'
])
subprocess.check_call(['git', 'rm', '-r', '-f', 'xschunked'])
subprocess.check_call(['git', 'rm', '-r', '-f', 'xsresponse1'])

manifest = Path('MANIFEST').read_text().splitlines()
mapped = []
for line in manifest:
    line = line.replace('lib/Linux/Event/HTTP', 'lib/Linux/Event/HTTP')
    line = line.replace(
        'lib/Linux/Event/HTTP/Server/Connection.pm',
        'lib/Linux/Event/HTTP/Server/Connection.pm',
    )
    if line.startswith('lib/Linux/Event/HTTP/_Parser'):
        continue
    if line.startswith('lib/Linux/Event/HTTP/_Native'):
        continue
    if line.startswith('xschunked/') or line.startswith('xsresponse1/'):
        continue
    mapped.append(line)
if 'lib/Linux/Event/HTTP/_HTTP1.pm' not in mapped:
    mapped.append('lib/Linux/Event/HTTP/_HTTP1.pm')
Path('MANIFEST').write_text('\n'.join(sorted(set(mapped))) + '\n')

# Hard-stop on stale package names before building.
old = subprocess.run(
    ['git', 'grep', '-n', 'Linux::Event::HTTP', '--', ':!handoff.md'],
    capture_output=True,
    text=True,
)
if old.returncode == 0:
    print(old.stdout, end='')
    raise SystemExit('old public namespace remains')

obsolete = subprocess.run(
    [
        'git', 'grep', '-nE',
        'Linux::Event::HTTP::_HTTP1|Linux::Event::HTTP::_HTTP1',
    ],
    capture_output=True,
    text=True,
)
if obsolete.returncode == 0:
    print(obsolete.stdout, end='')
    raise SystemExit('obsolete private native package remains')
