import sys,pathlib
from types import SimpleNamespace
import numpy as np
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from worker import align_words_with_context,with_following

class Model:
 def __init__(self,retry='good'):self.calls=[];self.retry=retry
 def generate(self,*,audio,text,language):
  self.calls.append(len(audio))
  times=[(0,.5),(1.5,1.8)]
  if len(self.calls)>1:
   times=[(0,.5),(.7,.9)] if self.retry=='good' else [(0,.5),(1.6,1.9)]
  return SimpleNamespace(items=[SimpleNamespace(text=t,start_time=a,end_time=b) for t,(a,b) in zip('甲乙',times)])
clip=dict(start=4,end=5); adjacent=dict(start=5,end=9);audio=np.zeros(16000,dtype=np.float32);following=np.zeros(64000,dtype=np.float32)
model=Model(); rows=align_words_with_context(model,audio,'甲乙','Chinese',clip,adjacent,following)
assert model.calls==[16000,64000] and rows[-1]['end']==4.9 and not rows[-1].get('timingUncertain')
model=Model(); rows=align_words_with_context(model,audio,'甲乙','Chinese',clip,dict(start=5.5,end=9.5),following)
assert model.calls==[16000] and rows[-1].get('timingUncertain') and rows[-1]['end']==5
model=Model('still_bad');rows=align_words_with_context(model,audio,'甲乙','Chinese',clip,adjacent,following)
assert len(model.calls)==2 and rows[-1].get('timingUncertain') and ''.join(x['text'] for x in rows)=='甲乙'
assert list(with_following([1,2,3]))==[(1,2),(2,3),(3,None)]
# The bounded aligner cannot receive more than 300 seconds, even on retry.
model=Model();longclip=dict(start=0,end=300);nextclip=dict(start=300,end=304)
# Force an out-of-bounds token while leaving all other timing valid.
class LimitModel(Model):
 def generate(self,**kwargs):
  self.calls.append(len(kwargs['audio']))
  return SimpleNamespace(items=[SimpleNamespace(text='甲',start_time=0,end_time=.5),SimpleNamespace(text='乙',start_time=301,end_time=302)])
model=LimitModel();rows=align_words_with_context(model,np.zeros(300*16000,dtype=np.float32),'甲乙','Chinese',longclip,nextclip,following)
assert model.calls==[300*16000] and rows[-1].get('timingUncertain')
print('PASS: contiguous bounded audio retry, missing context fallback, failed retry fallback, text and time safety')
