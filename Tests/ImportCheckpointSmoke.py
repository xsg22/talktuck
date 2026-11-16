import json,os,pathlib,sys,tempfile,types,unittest
from unittest.mock import patch

sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
import worker

class CheckpointSmoke(unittest.TestCase):
    def test_interruption_resume_invalidation_and_corruption(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d);model=root/'model';model.mkdir();(model/'weights').write_text('model')
            hints=root/'hints';hints.write_text('{"words":[],"context":""}')
            cache=root/'checkpoints';out=root/'out';calls=[]
            clips=[(dict(start=i,end=i+1,frames=16000),bytes([i])*64000) for i in range(3)]
            core=types.SimpleNamespace(clear_cache=lambda:None,device_info=lambda:{'memory_size':16*1024**3,'max_recommended_working_set_size':12*1024**3},set_memory_limit=lambda _:None,set_cache_limit=lambda _:None)
            mlx=types.ModuleType('mlx');mlx.core=core
            package=types.ModuleType('mlx_audio');package.stt=types.SimpleNamespace(load=lambda _:object())
            modules={'numpy':types.SimpleNamespace(frombuffer=lambda data,dtype:data),'mlx':mlx,'mlx.core':core,'mlx_audio':package,'mlx_audio.stt':package.stt}
            fail=[True]
            def recognize(model,audio,*,start,end,**kw):
                calls.append(start)
                if start==2 and fail[0]:raise RuntimeError('interrupted')
                return dict(start=start,end=end,text='text'+str(start))
            def run():
                with patch.dict(sys.modules,modules),patch.object(worker,'stream_clips',lambda:iter(clips)),patch.object(worker,'recognized_segment',recognize):
                    worker.transcribe_stream(str(model),'en',str(out),str(hints),str(cache))
            with self.assertRaises(RuntimeError):run()
            self.assertEqual(calls,[0,1,2]);self.assertFalse(out.exists())
            fail[0]=False;calls.clear();run()
            self.assertEqual(calls,[2]);self.assertEqual(len(json.loads(out.read_text())['segments']),3)
            self.assertEqual((cache/'00000000.json').stat().st_mode & 0o777,0o600)
            calls.clear();(cache/'00000001.json').write_text('{broken');run()
            self.assertEqual(calls,[1])
            calls.clear();entry=cache/'00000000.json';value=json.loads(entry.read_text());value['segment']['text']='tampered';entry.write_text(json.dumps(value));run()
            self.assertEqual(calls,[0])
            calls.clear();clips[1]=(clips[1][0],b'x'*64000);run()
            self.assertEqual(calls,[1])
            calls.clear();hints.write_text('{"words":[],"context":"changed"}');run()
            self.assertEqual(calls,[0,1,2])
            calls.clear();(model/'weights').write_text('new model contents');run()
            self.assertEqual(calls,[0,1,2])
            calls.clear();weights=model/'weights';before=weights.stat()
            weights.write_text('X'*before.st_size);os.utime(weights,ns=(before.st_atime_ns,before.st_mtime_ns));run()
            self.assertEqual(calls,[0,1,2])
            code=root/'code';code.mkdir();script=code/'worker.py';script.write_text('version one')
            with patch.object(worker,'__file__',str(script)):
                calls.clear();run();self.assertEqual(calls,[0,1,2])
                calls.clear();run();self.assertEqual(calls,[])
                script.write_text('version two');calls.clear();run();self.assertEqual(calls,[0,1,2])

if __name__=='__main__':unittest.main()
