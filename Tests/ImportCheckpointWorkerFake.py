#!/usr/bin/python3
import os,pathlib,sys,types
sys.path.insert(0,os.environ['TALKTUCK_TEST_RUNTIME'])
import worker

class Model:
    def generate(self,*,audio,**kw):
        calls=pathlib.Path(os.environ['TALKTUCK_TEST_CALLS'])
        count=len(calls.read_text().splitlines()) if calls.exists() else 0
        with calls.open('a') as f:f.write('inference\n')
        if os.environ.get('TALKTUCK_TEST_INTERRUPT')=='1' and count==2:raise RuntimeError('injected interruption')
        return types.SimpleNamespace(text='valid speech',generation_tokens=10,segments=[dict(start=0,end=len(audio)/16000)])
core=types.SimpleNamespace(clear_cache=lambda:None,device_info=lambda:{'memory_size':16*1024**3,'max_recommended_working_set_size':12*1024**3},set_memory_limit=lambda _:None,set_cache_limit=lambda _:None)
mlx=types.ModuleType('mlx');mlx.core=core
package=types.ModuleType('mlx_audio');package.stt=types.SimpleNamespace(load=lambda _:Model())
sys.modules.update({'numpy':types.SimpleNamespace(frombuffer=lambda data,dtype:memoryview(data).cast('f')),'mlx':mlx,'mlx.core':core,'mlx_audio':package,'mlx_audio.stt':package.stt})
try:worker.main()
except Exception as e:print(type(e).__name__,file=sys.stderr);sys.exit(1)
