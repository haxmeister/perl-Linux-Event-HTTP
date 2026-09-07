from pathlib import Path
import subprocess

for raw in subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0'):
    if not raw:
        continue
    path = Path(raw.decode())
    if not path.is_file():
        continue
    data = path.read_bytes()
    changed = data.replace(
        b'use Linux::Event::HTTP::_HTTP1::Chunked ();',
        b'use Linux::Event::HTTP::_HTTP1 ();',
    )
    changed = changed.replace(
        b'use Linux::Event::HTTP::_HTTP1::Chunked;',
        b'use Linux::Event::HTTP::_HTTP1;',
    )
    if changed != data:
        path.write_bytes(changed)
