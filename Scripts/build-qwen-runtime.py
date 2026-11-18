#!/usr/bin/env python3
import hashlib,json,os,pathlib,stat,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent.parent
venv=ROOT/'.tools/asr-venv';python=venv/'bin/python'
lock=ROOT/'Native/QwenRuntime/requirements.lock'
if sys.version_info[:2] != (3,12):raise SystemExit('构建Qwen隔离组件需要Python 3.12；最终用户无需安装Python')
if not lock.exists():raise SystemExit('缺少已经验收的Qwen运行时依赖清单')
if not python.exists():subprocess.run([sys.executable,'-m','venv',str(venv)],check=True)
requirements_hash=hashlib.sha256(lock.read_bytes()).hexdigest()
marker=venv/'.talktuck-lock-sha256'
if not marker.exists():
    # Preserve a previously verified environment across a marker rename without
    # deleting its cache or downloading its existing dependencies again.
    for previous in venv.glob('.*-lock-sha256'):
        if previous.is_file() and previous.read_text()==requirements_hash:
            marker.write_text(requirements_hash)
            break
if not marker.exists() or marker.read_text()!=requirements_hash:
    subprocess.run([str(python),'-m','pip','install','--disable-pip-version-check','-r',str(lock)],check=True)
    marker.write_text(requirements_hash)
runtime_root=ROOT/'.build/qwen-runtime'
stamp=runtime_root/'.source-sha256'
integrity=runtime_root/'.runtime-sha256'
inputs=sorted((ROOT/'Native/QwenRuntime').glob('*.py'))+[lock,ROOT/'Scripts/qwen-runtime.spec',ROOT/'Resources/SentenceRules.json']
installed=subprocess.check_output([str(python),'-m','pip','freeze','--all'])
version=hashlib.sha256(b''.join(str(p.relative_to(ROOT)).encode()+p.read_bytes() for p in inputs)+sys.version.encode()+installed).hexdigest()

def runtime_digest(root):
    h=hashlib.sha256()
    for path in sorted(root.rglob('*')):
        rel=str(path.relative_to(root)).encode(); mode=path.lstat().st_mode
        h.update(len(rel).to_bytes(4,'big')+rel+stat.S_IFMT(mode).to_bytes(4,'big')+(mode & 0o111).to_bytes(2,'big'))
        if path.is_symlink():
            target=os.readlink(path).encode(); h.update(len(target).to_bytes(4,'big')+target)
        elif path.is_file():
            with path.open('rb') as f:
                h.update(hashlib.file_digest(f,'sha256').digest())
    return h.hexdigest()

runtime=runtime_root/'qwen-asr'
if stamp.exists() and integrity.exists() and stamp.read_text()==version and (runtime/'qwen-asr').is_file() and integrity.read_text()==runtime_digest(runtime):
    print('复用已校验的Qwen3-ASR隔离运行时');sys.exit(0)
subprocess.run([str(python),'-m','PyInstaller','--noconfirm','--clean','--distpath',str(runtime_root),
                '--workpath',str(ROOT/'.build/qwen-freezer'),str(ROOT/'Scripts/qwen-runtime.spec')],check=True,cwd=ROOT)
if not (runtime/'qwen-asr').is_file(): raise SystemExit('Qwen runtime executable missing')
integrity.write_text(runtime_digest(runtime))
stamp.write_text(version)
