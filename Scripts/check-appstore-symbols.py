#!/usr/bin/env python3
"""Fail when an app contains undefined symbols flagged in the Mac review."""
import os
from pathlib import Path
import subprocess
import sys

SYMBOLS = set(('caxpy ccopy cgemm cgemv cswap ctrsm ctrsv dasum daxpy dcabs1_ '
    'dcopy dgemm dgemv dnrm2 dswap dtrsm dtrsv dzasum dznrm2 icamax idamax '
    'isamax izamax lsame_ sasum saxpy scasum scnrm2 scopy sgemm sgemv snrm2 '
    'sswap strsm strsv xerbla_array__ zaxpy zcopy zgemm zgemv zswap ztrsm ztrsv').split())
SYMBOLS = {'_' + value for value in SYMBOLS}
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
root = Path(sys.argv[1]).resolve(strict=True)
if not root.is_dir() or root.suffix != '.app':
    raise SystemExit('Expected an app bundle')
failures = []
count = 0
for path in root.rglob('*'):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open('rb') as source:
        if source.read(4) not in MAGIC:
            continue
    count += 1
    result = subprocess.run(['nm', '-u', str(path)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f'nm failed for {path.relative_to(root)}: {result.stderr}')
    found = sorted({parts[-1] for line in result.stdout.splitlines() if (parts := line.split()) and parts[-1] in SYMBOLS})
    if found:
        failures.append((path.relative_to(root), found))
for path, found in failures:
    print(f'{path}: {", ".join(found)}')
print(f'Scanned {count} Mach-O files; {len(failures)} files reference flagged symbols')
sys.exit(bool(failures) or count == 0)
