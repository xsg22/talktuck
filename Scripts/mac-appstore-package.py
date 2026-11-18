#!/usr/bin/env python3
"""Build a local Mac App Store candidate; never uploads or installs it."""
import argparse, datetime, fcntl, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
HELPERS = ('Contents/MacOS/talktuck', 'Contents/Resources/Accounts/dws',
           'Contents/Resources/Integrations/lark-cli', 'Contents/Resources/Engine/ASR/paraformer-live',
           'Contents/Resources/Engine/ASR/qwen-asr')

def run(args, **kw):
    return subprocess.run([str(x) for x in args], check=True, **kw)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--version', required=True, help='App Store version, e.g. 1.0')
    p.add_argument('--build', required=True, help='unique CFBundleVersion, e.g. 3')
    p.add_argument('--output-root', required=True, type=pathlib.Path, help='new task directory below external Codex directory')
    p.add_argument('--app-identity', default=os.environ.get('TALKTUCK_MAS_APP_IDENTITY'), help='Apple Distribution signing identity (or TALKTUCK_MAS_APP_IDENTITY)')
    p.add_argument('--installer-identity', default=os.environ.get('TALKTUCK_MAS_INSTALLER_IDENTITY'), help='Installer identity (or TALKTUCK_MAS_INSTALLER_IDENTITY)')
    p.add_argument('--python', default='python3', help='Python 3.12 for source build')
    p.add_argument('--cache-root', type=pathlib.Path, help='dedicated external persistent dependency cache')
    p.add_argument('--from-app', type=pathlib.Path, help='package an existing candidate; provenance is unverified')
    p.add_argument('--keep-build', action='store_true', help='retain this run’s intermediate build and temporary files')
    a = p.parse_args()
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', a.version) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', a.build):
        p.error('version and build must contain only numeric dot-separated components')
    if not a.app_identity or not a.installer_identity: p.error('both signing identities are required')
    app_team = re.search(r'^Apple Distribution: .+ \(([A-Z0-9]{10})\)$', a.app_identity)
    installer_team = re.search(r'^3rd Party Mac Developer Installer: .+ \(([A-Z0-9]{10})\)$', a.installer_identity)
    if not app_team or not installer_team or app_team.group(1) != installer_team.group(1):
        p.error('App and installer identities must be distribution identities from the same team')
    # Never silently fall back to the system disk or overwrite an earlier run.
    matches=[]
    for candidate in pathlib.Path('/Volumes').iterdir():
        if not os.path.ismount(candidate): continue
        result = subprocess.run(['diskutil','info','-plist',str(candidate)], capture_output=True)
        if result.returncode == 0 and plistlib.loads(result.stdout).get('VolumeName') == '外接硬盘':
            matches.append(candidate)
    if len(matches) != 1: raise SystemExit('Expected exactly one mounted volume named 外接硬盘')
    mount = matches[0]
    allowed = (mount/'Codex').resolve(strict=True)
    root = a.output_root.expanduser().resolve()
    if not root.is_relative_to(allowed) or root == allowed: raise SystemExit('output-root must be below 外接硬盘/Codex')
    if root.exists(): raise SystemExit('output-root already exists; choose a new directory')
    if shutil.disk_usage(allowed).free < 8 * 1024**3: raise SystemExit('Less than 8 GiB available on external volume')
    if a.cache_root:
        cache = a.cache_root.expanduser().resolve()
        if not cache.is_relative_to(allowed) or cache == allowed: raise SystemExit('cache-root must be below 外接硬盘/Codex')
    else: cache = allowed/'talktuck/mas-dependency-cache'
    cache.mkdir(parents=True, exist_ok=True)
    cache_lock = (cache/'.packaging.lock').open('a')
    try: fcntl.flock(cache_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: raise SystemExit('Dependency cache is in use by another packaging process')
    root.mkdir(parents=True)
    for name in ('build','tmp','evidence','deliverables'): (root/name).mkdir()
    env = os.environ.copy()
    env.update(TMPDIR=str(root/'tmp')+'/', XDG_CACHE_HOME=str(root/'tmp/cache'),
               PYINSTALLER_CONFIG_DIR=str(root/'tmp/pyinstaller'), PIP_CACHE_DIR=str(cache/'pip'),
               TALKTUCK_SWIFT_SYSTEM_TMP='1', TALKTUCK_APP_ONLY='1')
    logpath = root/'evidence/build.log'
    with logpath.open('w', encoding='utf8') as log:
        def cmd(args, **kw): return run(args, stdout=log, stderr=subprocess.STDOUT, env=env, **kw)
        try:
            if a.from_app:
                source = a.from_app.resolve(strict=True)
                if source.suffix != '.app' or not source.is_dir(): raise ValueError('--from-app must identify an app bundle')
                provenance = {'type':'existing-app', 'source':str(source), 'source_commit':None, 'verified_against_source':False}
            else:
                status = subprocess.check_output(['git','status','--porcelain','--untracked-files=no'], cwd=ROOT, text=True)
                if status: raise ValueError('Tracked source changes exist; commit or use a clean checkout')
                commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip()
                cache.mkdir(parents=True, exist_ok=True)
                source_root = root/'build/source'; source_root.mkdir()
                # Git archive ensures the built files match the recorded commit.
                archive = root/'tmp/source.tar'
                with archive.open('wb') as f: run(['git','archive','--format=tar',commit], cwd=ROOT, stdout=f, stderr=log)
                cmd(['tar','-xf',archive,'-C',source_root])
                for name in ('.tools','.vendor'):
                    target = cache/name; target.mkdir(exist_ok=True); (source_root/name).symlink_to(target)
                (source_root/'.build').mkdir(exist_ok=True)
                runtime_cache = cache/'qwen-runtime'; runtime_cache.mkdir(exist_ok=True)
                (source_root/'.build/qwen-runtime').symlink_to(runtime_cache)
                py = pathlib.Path(a.python).expanduser()
                if not py.is_absolute():
                    found = shutil.which(str(py))
                    if not found: raise ValueError('Python interpreter not found')
                    py = pathlib.Path(found)
                cmd([py,'-c','import sys; assert sys.version_info[:2] == (3,12)'])
                bin_dir = root/'tmp/python-bin'; bin_dir.mkdir()
                (bin_dir/'python3').symlink_to(py.resolve())
                env['PATH'] = str(bin_dir)+os.pathsep+env['PATH']
                cmd(['/bin/zsh','Scripts/prepare-account-components.zsh'],cwd=source_root)
                cmd(['/bin/zsh','Scripts/build.zsh'],cwd=source_root)
                source = source_root/'.build/release/TalkTuck.app'
                provenance = {'type':'git-archive','source_commit':commit,'verified_against_source':True}
            app = root/'build/TalkTuck.app'; cmd(['ditto',source,app])
            info = app/'Contents/Info.plist'
            with info.open('rb') as f: values=plistlib.load(f)
            values.update(CFBundleIdentifier='com.talktuck.app', CFBundleShortVersionString=a.version,
                          CFBundleVersion=a.build, LSApplicationCategoryType='public.app-category.productivity')
            with info.open('wb') as f: plistlib.dump(values,f)
            arch = subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/TalkTuckApp')], text=True).strip().split()
            if arch != ['arm64']: raise ValueError('Expected an Apple Silicon arm64 app')
            for resource in ('Contents/Resources/AppIcon.icns', 'Contents/Resources/Assets.car',
                             'Contents/Resources/ASRModels.json', 'Contents/Resources/Engine/ASR/qwen-asr'):
                if not (app/resource).is_file(): raise ValueError('Missing required app resource: '+resource)
            if (app/'Contents/embedded.provisionprofile').exists():
                raise ValueError('Existing provisioning profile is unsupported; use an app without a profile')
            main_ent = {'com.apple.security.app-sandbox':True,'com.apple.security.device.audio-input':True,
                        'com.apple.security.network.client':True,'com.apple.security.network.server':True,
                        'com.apple.security.files.user-selected.read-write':True}
            inherit = {'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
            for name, data in [('main.plist', main_ent), ('inherit.plist', inherit)]:
                with (root/'tmp'/name).open('wb') as f: plistlib.dump(data,f)
            # Sign leaf binaries and enclosing frameworks from inside out; do not use --deep to sign.
            binaries=[]; frameworks=[]
            for f in app.rglob('*'):
                if f.is_symlink(): continue
                if f.is_dir() and f.suffix == '.framework': frameworks.append(f)
                elif f.is_file():
                    with f.open('rb') as stream:
                        if stream.read(4) in MAGIC: binaries.append(f)
            main_bin=app/'Contents/MacOS/TalkTuckApp'
            if main_bin not in binaries or any(not (app/x).is_file() for x in HELPERS): raise ValueError('Missing required app binary or helper')
            for f in sorted((x for x in binaries if x != main_bin), key=lambda x:len(x.parts), reverse=True):
                args=['codesign','--force','--sign',a.app_identity]
                if str(f.relative_to(app)) in HELPERS: args += ['--entitlements',root/'tmp/inherit.plist']
                cmd(args+[f])
            for f in sorted(frameworks,key=lambda x:len(x.parts),reverse=True): cmd(['codesign','--force','--sign',a.app_identity,f])
            cmd(['codesign','--force','--sign',a.app_identity,'--entitlements',root/'tmp/main.plist',app])
            cmd(['codesign','--verify','--deep','--strict','--verbose=2',app])
            cmd([sys.executable, ROOT/'Scripts/check-appstore-symbols.py',app])
            pkg=root/'deliverables'/f'TalkTuck-MacAppStore-{a.version}-{a.build}.pkg'
            cmd(['productbuild','--component',app,'/Applications','--sign',a.installer_identity,pkg])
            cmd(['pkgutil','--check-signature',pkg])
            expanded = root/'build/package-check'
            cmd(['pkgutil','--expand-full',pkg,expanded])
            payload_apps = [x for x in expanded.rglob('TalkTuck.app') if x.is_dir() and not x.is_symlink()]
            if len(payload_apps) != 1: raise ValueError('Package must contain exactly one TalkTuck.app')
            packaged = payload_apps[0]
            cmd(['codesign','--verify','--deep','--strict',packaged])
            with (packaged/'Contents/Info.plist').open('rb') as f: package_info = plistlib.load(f)
            if any(package_info.get(k) != values[k] for k in ('CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion')):
                raise ValueError('Package metadata does not match the signed app')
            for relative in ('Contents/MacOS/TalkTuckApp', 'Contents/Resources/Engine/ASR/qwen-asr'):
                if hashlib.sha256((app/relative).read_bytes()).digest() != hashlib.sha256((packaged/relative).read_bytes()).digest():
                    raise ValueError('Packaged binary differs from the signed app: '+relative)
            cmd([sys.executable, ROOT/'Scripts/check-appstore-symbols.py',packaged])
            h=hashlib.sha256()
            with pkg.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024*1024), b''): h.update(chunk)
            sha=h.hexdigest()
            (pkg.parent/(pkg.name+'.sha256')).write_text(f'{sha}  {pkg.name}\n')
            manifest={'version':a.version,'build':a.build,'bundle_id':'com.talktuck.app','package':str(pkg),'sha256':sha,
                      'provenance':provenance,'profile_embedded':False,'testflight_eligible':False,
                      'upload':'not performed','functional_acceptance':'not performed','created':datetime.datetime.now().astimezone().isoformat()}
            (root/'evidence/manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
            if not a.keep_build:
                removed=[]
                for name in ('build','tmp'):
                    path=root/name; shutil.rmtree(path); removed.append(str(path))
                (root/'evidence/cleanup.txt').write_text(datetime.datetime.now().astimezone().isoformat()+'\n'+'\n'.join(removed)+'\n')
            print(f'PASS: {a.version} ({a.build})\nPKG: {pkg}\nSHA256: {sha}\n日志: {logpath}\n未上传；未完成产品功能验收。')
            print('提示：未嵌入描述文件，TestFlight 不可用（90889）。')
            if a.from_app: print('提示：输入为已有 App，未验证与源码提交的对应关系。')
        except (subprocess.CalledProcessError, OSError, ValueError) as exc:
            print(f'FAIL: {exc}\n详细日志: {logpath}', file=sys.stderr)
            raise SystemExit(1)

if __name__=='__main__': main()
