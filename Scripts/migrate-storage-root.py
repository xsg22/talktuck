#!/usr/bin/env python3
"""Migrate one stopped TalkTuck library after a verified independent backup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def no_app_processes():
    processes = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    prefixes = ['/Applications/TalkTuck.app/Contents/MacOS/TalkTuckApp',
                '/Applications/TalkTuck.app/Contents/Resources/Engine/ASR/']
    if any(line.strip().startswith(tuple(prefixes)) for line in processes):
        raise RuntimeError('TalkTuck or its inference engine is running')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def inventory(root):
    result = {}
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(folder, name)
            relative = str(path.relative_to(root))
            if path.is_symlink(): result[relative] = ('link', os.readlink(path))
            elif path.is_file(): result[relative] = ('file', path.stat().st_size, digest(path))
            elif path.is_dir(): result[relative] = ('directory',)
            else: raise RuntimeError('Unsupported library item')
    return result


def replacements(root, old, new):
    changes = {}
    # These are derived Agent snapshots, not user transcript text.
    for path in (root / 'AgentData' / 'recordings').glob('*/record.json'):
        data = json.loads(path.read_text())
        changed = False
        for row in data.get('audioFiles', []):
            value = row.get('path')
            if isinstance(value, str) and value.startswith(old + '/'):
                row['path'] = new + value[len(old):]; changed = True
        if changed: changes[path.relative_to(root)] = (json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    # Model paths are keys in reusable recognition checkpoints. Their hashes and
    # audio data remain untouched; only keys rooted in this library move.
    for path in (root / 'Meetings').rglob('ready.json'):
        data = json.loads(path.read_text())
        models = data.get('key', {}).get('models')
        if not isinstance(models, dict): continue
        renamed = {(new + k[len(old):] if k.startswith(old + '/') else k): v for k, v in models.items()}
        if len(renamed) != len(models): raise RuntimeError('Model checkpoint path collision')
        if renamed != models:
            data['key']['models'] = renamed
            changes[path.relative_to(root)] = (json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    setup = root / 'AgentData' / 'SETUP.md'
    if setup.is_file():
        before = setup.read_text()
        if old in before: changes[setup.relative_to(root)] = before.replace(old, new).encode()
    return changes


def atomic_write(path, content):
    fd, temporary = tempfile.mkstemp(prefix='.migration-', dir=path.parent)
    try:
        os.fchmod(fd, path.stat().st_mode & 0o777)
        with os.fdopen(fd, 'wb') as out:
            out.write(content); out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    parser.add_argument('--backup', required=True, type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    source, destination, backup = (p.expanduser().absolute() for p in (args.source, args.destination, args.backup))
    if not source.is_dir() or not backup.is_dir() or source.is_symlink() or destination.exists() or destination.is_symlink():
        raise RuntimeError('Source, destination or backup preconditions not met')
    if source == backup or backup.is_relative_to(source) or source.is_relative_to(backup) or source.parent != destination.parent:
        raise RuntimeError('Backup must be separate; source and destination must share a parent')
    no_app_processes()
    original = inventory(source)
    if original != inventory(backup): raise RuntimeError('Backup does not match current library')
    changes = replacements(source, str(source), str(destination))
    print(json.dumps({'verifiedItems': len(original), 'metadataFilesToUpdate': len(changes), 'execute': args.execute}), flush=True)
    if not args.execute: return
    no_app_processes()
    os.rename(source, destination)
    changed = []
    try:
        for relative, content in changes.items():
            no_app_processes()
            atomic_write(destination / relative, content)
            changed.append(relative)
        no_app_processes()
        if replacements(destination, str(source), str(destination)):
            raise RuntimeError('A migrated metadata reference remains')
        expected = dict(original)
        for relative, content in changes.items():
            expected[str(relative)] = ('file', len(content), hashlib.sha256(content).hexdigest())
        if inventory(destination) != expected:
            raise RuntimeError('Post-migration content verification failed')
        no_app_processes()
    except BaseException:
        # Only restore while stopped; if a process started, preserve both the
        # destination and verified backup for manual recovery.
        no_app_processes()
        for relative in changed: shutil.copy2(backup / relative, destination / relative)
        if source.exists(): raise RuntimeError('Rollback source unexpectedly exists')
        os.rename(destination, source)
        raise
    print(json.dumps({'migrated': True, 'metadataFilesUpdated': len(changed)}), flush=True)


if __name__ == '__main__': main()
