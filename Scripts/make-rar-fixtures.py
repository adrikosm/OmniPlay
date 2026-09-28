#!/usr/bin/env python3
"""Generate tiny synthetic RAR5 inputs using a local RAR CLI; never bundle the CLI."""
import argparse
import pathlib
import random
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--rar', default='rar')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
out = root / 'Fixtures/synthetic/rar'
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as folder:
    work = pathlib.Path(folder)
    (work / 'hello.txt').write_text('OmniPlay RAR fixture\n')
    (work / '日本語.txt').write_text('Unicode filename\n')
    (work / 'second.txt').write_text('OmniPlay RAR fixture\n' * 100)
    (work / 'volume.bin').write_bytes(random.Random(42).randbytes(12000))
    with (work / 'large.bin').open('wb') as large:
        large.truncate(70 << 20)
    for name, flags, files in [
        ('stored', ['-m0'], ['hello.txt']),
        ('solid', ['-s', '-m5'], ['hello.txt', 'second.txt', '日本語.txt']),
        ('password', ['-pfixture'], ['hello.txt']),
        ('headers', ['-hpfixture'], ['hello.txt']),
        ('volumes', ['-v5k', '-m0'], ['volume.bin']),
        ('dictionary', ['-md128m'], ['large.bin']),
    ]:
        target = out / (name + '.rar')
        if target.exists(): target.unlink()
        subprocess.run([args.rar, 'a', '-y', '-cfg-', '-idq', '-md4m', '-ts-', *flags, str(target), *files], cwd=work, check=True)

# The pinned libarchive corpus includes RAR4, which current RAR no longer writes.
import binascii
source = root / 'Native/libarchive/libarchive/test/test_read_format_rar.rar.uu'
lines = source.read_bytes().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith(b'begin ')) + 1
(out / 'rar4.rar').write_bytes(b''.join(binascii.a2b_uu(line) for line in lines[start:] if line != b'end'))
