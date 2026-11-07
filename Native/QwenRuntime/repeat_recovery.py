"""Conservatively re-recognize long repeated model output before publication.

A confirmed result always carries the first model candidate for durable recovery.
This does not inspect or modify previously saved user text.
"""
import difflib,unicodedata
from inference_policy import RATE

MIN_REPEAT=80
MAX_REPEAT=400
MIN_AGREEMENT=.99

def normalized(text):
    return ''.join(c.casefold() for c in text if unicodedata.category(c)[0] in 'LN')

def find_repeat(text):
    value=normalized(text)
    if len(value)<2*MIN_REPEAT or len(value)>3000:return None
    for i in range(len(value)-2*MIN_REPEAT+1):
        pattern=value[i:i+MIN_REPEAT];limit=min(len(value),i+MAX_REPEAT)+MIN_REPEAT
        j=value.find(pattern,i+MIN_REPEAT,limit)
        while j>=0 and j-i<=MAX_REPEAT:
            n=j-i
            if value[i:j]==value[j:j+n]:return value,value[:i]+value[j:]
            j=value.find(pattern,j+1,limit)
    return None

def similarity(a,b):
    return difflib.SequenceMatcher(None,a,b,autojunk=False).ratio()

def trim_overlap(previous,current):
    left=normalized(previous);right=normalized(current);best_score=0;best_count=0
    for n in range(6,min(40,len(left))+1):
        for m in range(max(6,n-3),min(len(right),n+3)+1):
            ratio=similarity(left[-n:],right[:m]);score=ratio*min(n,m)
            if ratio>=.92 and score>best_score:best_score,best_count=score,m
    if not best_count:return current,False
    count=0;cut=0
    for i,c in enumerate(current):
        if unicodedata.category(c)[0] in 'LN':count+=len(c.casefold())
        if count>=best_count:cut=i+1;break
    while cut<len(current) and unicodedata.category(current[cut])[0] not in 'LN':cut+=1
    return current[cut:],True

def windowed(model,audio,start,language,hotwords,generate,seconds):
    step=(seconds-3)*RATE;size=seconds*RATE;cursor=0;previous='';parts=[];end_previous=0
    while cursor<len(audio):
        end=min(len(audio),cursor+size)
        raw=generate(model,audio[cursor:end],language=language,hotwords=hotwords).text.strip()
        text,trimmed=trim_overlap(previous,raw) if previous else (raw,False)
        if text:
            part_start=max(cursor,end_previous) if trimmed else cursor
            if part_start>=end:return None
            parts.append(dict(text=text,start=start+part_start/RATE,end=start+end/RATE))
        previous=raw;end_previous=end
        if end==len(audio):break
        cursor+=step
    if not parts:return None
    return dict(text=''.join(x['text'] for x in parts),alignmentParts=parts)

def recover(model,audio,original,start,language,hotwords,generate):
    # Restrict automatic correction to the explicitly calibrated language and
    # bounded output; genuine long repeated speech must survive both probes.
    if language!='Chinese' or len(audio)<48*RATE:return None
    detected=find_repeat(original)
    if not detected:return None
    baseline,target=detected
    try:
        first=windowed(model,audio,start,language,hotwords,generate,24)
        if first is None:return None
        a=normalized(first['text']);score_a=similarity(a,target)
        if score_a<MIN_AGREEMENT or score_a-similarity(a,baseline)<.04:return None
        second=windowed(model,audio,start,language,hotwords,generate,30)
        if second is None:return None
        b=normalized(second['text']);score_b=similarity(b,target)
        if score_b<MIN_AGREEMENT or score_b-similarity(b,baseline)<.04 or similarity(a,b)<MIN_AGREEMENT:return None
        chosen=first if score_a>=score_b else second
        chosen['originalText']=original
        return chosen
    except (ValueError,RuntimeError,MemoryError):
        return None
