import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

module_path = Path(__file__).resolve().parents[1] / 'Scripts/migrate-storage-root.py'
spec = importlib.util.spec_from_file_location('storage_migration', module_path)
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class StorageMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['RECORD_AI_TEST_ROOT'])
        self.root = Path(self.tmp.name)
        self.source = self.root / 'old-root'
        self.destination = self.root / 'new-root'
        self.backup = self.root / 'backup'
        receipt = self.source / 'Meetings/fixture/analysis/ready.json'
        receipt.parent.mkdir(parents=True)
        receipt.write_text(json.dumps({'key': {'models': {str(self.source / 'Models/model'): 'size:time'}}, 'files': {'voice': 'hash'}}))
        snapshot = self.source / 'AgentData/recordings/fixture/record.json'
        snapshot.parent.mkdir(parents=True)
        snapshot.write_text(json.dumps({'audioFiles': [{'path': str(self.source / 'Meetings/fixture/audio.m4a')}], 'finalText': str(self.source)}))
        (self.source / 'Meetings/fixture/audio.m4a').write_bytes(b'original audio')
        shutil.copytree(self.source, self.backup)

    def tearDown(self): self.tmp.cleanup()

    def invoke(self, *extra):
        args = ['migration', '--source', str(self.source), '--destination', str(self.destination), '--backup', str(self.backup), *extra]
        with patch.object(sys, 'argv', args), patch.object(migration, 'no_app_processes'):
            migration.main()

    def test_migrates_only_paths_and_keeps_verified_backup(self):
        self.invoke('--execute')
        self.assertFalse(self.source.exists())
        self.assertEqual((self.destination / 'Meetings/fixture/audio.m4a').read_bytes(), b'original audio')
        self.assertEqual((self.backup / 'Meetings/fixture/audio.m4a').read_bytes(), b'original audio')
        receipt = json.loads((self.destination / 'Meetings/fixture/analysis/ready.json').read_text())
        self.assertEqual(list(receipt['key']['models']), [str(self.destination / 'Models/model')])
        self.assertEqual(receipt['files'], {'voice': 'hash'})
        snapshot = json.loads((self.destination / 'AgentData/recordings/fixture/record.json').read_text())
        self.assertEqual(snapshot['audioFiles'][0]['path'], str(self.destination / 'Meetings/fixture/audio.m4a'))
        self.assertEqual(snapshot['finalText'], str(self.source))  # transcript content is never rewritten

    def test_mismatch_prevents_move(self):
        (self.backup / 'Meetings/fixture/audio.m4a').write_bytes(b'wrong')
        with self.assertRaisesRegex(RuntimeError, 'Backup does not match'):
            self.invoke('--execute')
        self.assertTrue(self.source.exists())
        self.assertFalse(self.destination.exists())

    def test_write_failure_restores_original_tree(self):
        write = migration.atomic_write
        calls = []
        def fail_after_first(path, content):
            calls.append(path)
            if len(calls) == 2: raise OSError('simulated write failure')
            write(path, content)
        with patch.object(migration, 'atomic_write', side_effect=fail_after_first):
            with self.assertRaisesRegex(OSError, 'simulated write failure'):
                self.invoke('--execute')
        self.assertTrue(self.source.exists())
        self.assertFalse(self.destination.exists())
        self.assertEqual(migration.inventory(self.source), migration.inventory(self.backup))


if __name__ == '__main__': unittest.main()
