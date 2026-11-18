#!/usr/bin/env python3
"""Upload a local candidate with an existing App Store Connect API key."""
import argparse, datetime, hashlib, os, pathlib, re, shutil, subprocess, sys, tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('package', type=pathlib.Path, help='signed .pkg with adjacent .sha256 file')
a=p.parse_args()
key=os.environ.get('ASC_API_KEY_ID'); issuer=os.environ.get('ASC_API_ISSUER_ID')
if not key or not issuer:
    p.error('Set ASC_API_KEY_ID and ASC_API_ISSUER_ID; keep the .p8 key in API_PRIVATE_KEYS_DIR')
if not re.fullmatch(r'[A-Za-z0-9]+',key) or not re.fullmatch(r'[A-Fa-f0-9-]{36}',issuer):
    p.error('Invalid API key ID or issuer ID')
pkg=a.package.expanduser().resolve(strict=True)
if pkg.suffix != '.pkg' or not pkg.is_file(): raise SystemExit('Expected an existing .pkg')
# Locate the already-mounted volume by its actual volume name, not a guessed path.
volumes=[]
for volume in pathlib.Path('/Volumes').iterdir():
    if not os.path.ismount(volume): continue
    result=subprocess.run(['diskutil','info','-plist',str(volume)],capture_output=True)
    if result.returncode==0:
        import plistlib
        if plistlib.loads(result.stdout).get('VolumeName')=='外接硬盘': volumes.append(volume)
if len(volumes)!=1 or not pkg.is_relative_to((volumes[0]/'Codex').resolve()):
    raise SystemExit('Package must be below the mounted 外接硬盘/Codex directory')
sidecar=pkg.with_name(pkg.name+'.sha256')
expected=sidecar.read_text().split()[0]
h=hashlib.sha256()
with pkg.open('rb') as source:
    for block in iter(lambda:source.read(1024*1024),b''): h.update(block)
if not re.fullmatch(r'[a-fA-F0-9]{64}',expected) or h.hexdigest()!=expected.lower():
    raise SystemExit('Package checksum does not match')
os.umask(0o077)
evidence=pkg.parent.parent/'evidence'
if not evidence.is_dir() or not evidence.resolve().is_relative_to((volumes[0]/'Codex').resolve()):
    raise SystemExit('Expected an evidence directory below 外接硬盘/Codex')
with tempfile.TemporaryDirectory(prefix='upload-',dir=str(pkg.parent.parent)) as temporary:
    env=os.environ.copy(); env['TMPDIR']=temporary+'/'
    log=evidence/('upload-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')+'.log')
    with log.open('x') as out:
        check=subprocess.run(['pkgutil','--check-signature',str(pkg)],stdout=out,stderr=subprocess.STDOUT)
        if check.returncode: raise SystemExit('Installer signature check failed; see '+str(log))
        result=subprocess.run(['xcrun','altool','--upload-package',str(pkg),'--api-key',key,
                               '--api-issuer',issuer,'-CDTempDir',temporary],stdout=out,stderr=subprocess.STDOUT,env=env)
    if result.returncode:
        print('Upload failed; see '+str(log),file=sys.stderr); sys.exit(result.returncode)
print('Upload command succeeded. Check processing, compliance and review status in App Store Connect.')
print('Log: '+str(log))
