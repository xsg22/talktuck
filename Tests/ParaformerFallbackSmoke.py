import contextlib,io,json,os,pathlib,subprocess,sys,tempfile,time,types,unittest
from unittest.mock import patch

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
import worker

class FallbackSmoke(unittest.TestCase):
    def test_packaged_app_ignores_development_path_overrides(self):
        with patch.object(sys,'frozen',True,create=True),patch.dict(os.environ,{'TALKTUCK_PARAFORMER_EXECUTABLE':'/untrusted','TALKTUCK_PARAFORMER_MODEL':'/untrusted-model'}):
            exe,model=worker.fallback_resources(pathlib.Path('/models/Qwen3ASR'))
            self.assertEqual(exe,pathlib.Path(sys.executable).with_name('paraformer-live'))
            self.assertEqual(model,pathlib.Path('/models/Paraformer'))

    def test_preview_fallback_preserves_repetitions_and_offsets(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);exe=root/'preview';model=root/'model';model.mkdir()
            exe.write_text('''#!/usr/bin/python3\nimport json,sys\nsys.stdin.buffer.read()\nfor e in [dict(type="commit",text="yes yes yes",start=0.1,end=1.0),dict(type="commit",text="yes again",start=1.0,end=2.0),dict(type="done",end=2.0)]:print(json.dumps(e))\n''')
            exe.chmod(0o700)
            clip=dict(start=10.,end=12.,frames=32000)
            with patch.dict(os.environ,{'TALKTUCK_PARAFORMER_EXECUTABLE':str(exe),'TALKTUCK_PARAFORMER_MODEL':str(model)}):
                result=worker.paraformer_fallback(bytes(32000*4),clip,'auto',root)
            self.assertTrue(result['fallback']);self.assertEqual(result['text'],'yes yes yes\nyes again')
            self.assertEqual([(p['start'],p['end']) for p in result['alignmentParts']],[(10.1,11.),(11.,12.)])
            self.assertEqual(''.join(p['text'] for p in result['alignmentParts']),result['text'])

    def test_unsupported_language_and_unavailable_model_fail_safely(self):
        with tempfile.TemporaryDirectory() as d:
            clip=dict(start=0.,end=1.,frames=16000)
            with self.assertRaises(ValueError):worker.paraformer_fallback(bytes(64000),clip,'ja',pathlib.Path(d))
            with patch.dict(os.environ,{'TALKTUCK_PARAFORMER_EXECUTABLE':str(pathlib.Path(d)/'missing'),'TALKTUCK_PARAFORMER_MODEL':d}):
                with self.assertRaises(ValueError):worker.paraformer_fallback(bytes(64000),clip,'auto',pathlib.Path(d))

    def test_missing_completion_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);exe=root/'preview';exe.write_text('#!/usr/bin/python3\nimport sys\nsys.stdin.buffer.read()\n');exe.chmod(0o700)
            with patch.dict(os.environ,{'TALKTUCK_PARAFORMER_EXECUTABLE':str(exe),'TALKTUCK_PARAFORMER_MODEL':d}):
                with self.assertRaises(ValueError):worker.paraformer_fallback(bytes(64000),dict(start=0.,end=1.,frames=16000),'auto',root)

    def test_cancellation_terminates_fallback_process(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);exe=root/'preview';pidfile=root/'pid'
            exe.write_text('#!/usr/bin/python3\nimport os,pathlib,sys,time\npathlib.Path(os.environ["FALLBACK_TEST_PID"]).write_text(str(os.getpid()))\nsys.stdin.buffer.read()\ntime.sleep(60)\n');exe.chmod(0o700)
            env=dict(os.environ,TALKTUCK_PARAFORMER_EXECUTABLE=str(exe),TALKTUCK_PARAFORMER_MODEL=d,FALLBACK_TEST_PID=str(pidfile),PYTHONPATH=str(pathlib.Path(worker.__file__).parent))
            code='import worker,pathlib; worker.paraformer_fallback(bytes(64000),dict(start=0.,end=1.,frames=16000),"auto",pathlib.Path("."))'
            parent=subprocess.Popen([sys.executable,'-c',code],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if pidfile.exists():break
                    time.sleep(.05)
                self.assertTrue(pidfile.exists());pid=int(pidfile.read_text());parent.terminate();parent.wait(timeout=8)
                with self.assertRaises(ProcessLookupError):os.kill(pid,0)
            finally:
                if parent.poll() is None:parent.kill();parent.wait()

    def test_cached_fallback_is_invalidated_when_fallback_model_changes(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);qwen=root/'qwen';qwen.mkdir();(qwen/'weight').write_text('qwen')
            alt=root/'para';alt.mkdir()
            for name in ('encoder.int8.onnx','decoder.int8.onnx','tokens.txt','silero_vad.onnx'):(alt/name).write_text(name)
            executable=root/'preview';executable.write_text('executable');hints=root/'hints';hints.write_text('{"words":[],"context":"","allowParaformerFallback":true}')
            core=types.SimpleNamespace(clear_cache=lambda:None,device_info=lambda:{'memory_size':16*1024**3,'max_recommended_working_set_size':12*1024**3},set_memory_limit=lambda _:None,set_cache_limit=lambda _:None)
            mlx=types.ModuleType('mlx');mlx.core=core;package=types.ModuleType('mlx_audio');package.stt=types.SimpleNamespace(load=lambda _:object())
            modules={'numpy':types.SimpleNamespace(frombuffer=lambda data,dtype:data),'mlx':mlx,'mlx.core':core,'mlx_audio':package,'mlx_audio.stt':package.stt}
            clip=dict(start=0.,end=1.,frames=16000);payload=bytes(64000);calls=[]
            def fallback(data,clip,language,model_root):
                calls.append(1);return dict(start=0.,end=1.,text='safe preview',fallback=True)
            def run():
                with patch.dict(sys.modules,modules),patch.dict(os.environ,{'TALKTUCK_PARAFORMER_EXECUTABLE':str(executable),'TALKTUCK_PARAFORMER_MODEL':str(alt)}),patch.object(worker,'stream_clips',lambda:iter([(clip,payload)])),patch.object(worker,'recognized_segment',side_effect=worker.TokenLimitReached('limit')),patch.object(worker,'paraformer_fallback',fallback):
                    worker.transcribe_stream(str(qwen),'auto',str(root/'out'),str(hints),str(root/'checkpoints'))
            log=io.StringIO()
            with contextlib.redirect_stderr(log):run()
            self.assertIn('TALKTUCK_FALLBACK attempt token_limit',log.getvalue())
            self.assertIn('TALKTUCK_FALLBACK succeeded token_limit',log.getvalue())
            self.assertEqual(len(calls),1);run();self.assertEqual(len(calls),1)
            (alt/'tokens.txt').write_text('changed');run();self.assertEqual(len(calls),2)

if __name__=='__main__':unittest.main()
