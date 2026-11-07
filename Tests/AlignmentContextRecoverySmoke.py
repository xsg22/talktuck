import sys,pathlib
from types import SimpleNamespace
# The policy test uses a tiny fake array; real NumPy/MLX is exercised separately.
class Audio:
 def __init__(self,count):self.count=count
 def __len__(self):return self.count
 def __getitem__(self,key):
  if not isinstance(key,slice):raise TypeError('expected slice')
  start,stop,step=key.indices(self.count);return Audio(len(range(start,stop,step)))
sys.modules['numpy']=SimpleNamespace(concatenate=lambda arrays:Audio(sum(map(len,arrays))))
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Native/QwenRuntime'))
from worker import align_words_with_context,with_following,repair_alignment_seam

class Model:
 def __init__(self,retry='good'):self.calls=[];self.retry=retry
 def generate(self,*,audio,text,language):
  self.calls.append(len(audio))
  times=[(0,.5),(1.5,1.8)]
  if len(self.calls)>1:
   times=[(0,.5),(.7,.9)] if self.retry=='good' else [(0,.5),(1.6,1.9)]
  return SimpleNamespace(items=[SimpleNamespace(text=t,start_time=a,end_time=b) for t,(a,b) in zip('甲乙',times)])
clip=dict(start=4,end=5); adjacent=dict(start=5,end=9);audio=Audio(16000);following=Audio(64000)
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
model=LimitModel();rows=align_words_with_context(model,Audio(300*16000),'甲乙','Chinese',longclip,nextclip,following)
assert model.calls==[300*16000] and rows[-1].get('timingUncertain')
# A boundary retry uses real adjacent audio, preserves all text and separators,
# and only publishes results with reliable times on both sides.
left=dict(start=0,end=2,text='前末',language='zh'); right=dict(start=2,end=4,text='后续',language='zh')
a=[dict(text='前',start=.3,end=.7,separator=''),dict(text='末',start=2,end=2,separator='',timingUncertain=True)]
b=[dict(text='后',start=2,end=2.3,separator='\n'),dict(text='续',start=2.4,end=2.7,separator='')]
class SeamModel:
 def __init__(self,bad=False):self.calls=0;self.bad=bad
 def generate(self,*,audio,text,language):
  self.calls+=1
  assert len(audio)==64000 and text=='前末\n后续'
  times=[(.3,.7),(1.2,1.7),(2.0,2.3),(2.4,2.7)]
  if self.bad:times[1]=(1.2,1.2)
  return SimpleNamespace(items=[SimpleNamespace(text=t,start_time=x,end_time=y) for t,(x,y) in zip('前末后续',times)])
model=SeamModel();x,y=repair_alignment_seam(model,left,Audio(32000),a,right,Audio(32000),b)
assert model.calls==1 and ''.join(w.get('separator','')+w['text'] for w in x+y)=='前末\n后续'
assert not any(w.get('timingUncertain') for w in x+y)
model=SeamModel(True);x,y=repair_alignment_seam(model,left,Audio(32000),a,right,Audio(32000),b)
assert x==a and y==b
model=SeamModel();x,y=repair_alignment_seam(model,left,Audio(32000),a,dict(right,start=2.5),Audio(32000),b)
assert x==a and y==b and model.calls==0
print('PASS: bounded real-audio seam repair, exact text, uncertainty and non-contiguous fallback')
print('PASS: contiguous bounded audio retry, missing context fallback, failed retry fallback, text and time safety')
