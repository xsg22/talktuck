"""隔离的离线MLX推理进程；音频由Silero分段，文字不交给Gemma改写。"""
import os
# 在导入运行时之前关闭模型/分词器的任何在线回退。
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
import json,math,pathlib,struct,sys,wave
from language_policy import recognition_language, alignment_language
from inference_policy import MAX_ASR_SECONDS, MAX_ALIGNMENT_SECONDS, validate_clip, generate_complete, configure_memory, TokenLimitReached, RATE

def select_hotwords(words, context, limit=12):
    matched=[w for w in words if w.casefold() in context.casefold()]
    return (matched + [w for w in reversed(words) if w not in matched])[:limit]

def extract_hotwords(model_path,input_path,output_path):
    import mlx.core as mx
    from mlx_audio.lm.models import qwen2
    from mlx_audio.lm.generate import generate
    from mlx_audio.utils import load_config,load_weights,apply_quantization
    from transformers import AutoTokenizer
    model_path=pathlib.Path(model_path).resolve(strict=True)
    payload=json.loads(pathlib.Path(input_path).read_text())
    system,prompt=payload['system'],payload['prompt']
    if not isinstance(system,str) or not isinstance(prompt,str) or len(system)+len(prompt)>7000:raise ValueError('Invalid extraction input')
    config=load_config(model_path)
    if config.get('model_type')!='qwen2':raise ValueError('Invalid extraction model')
    model=qwen2.Model(qwen2.ModelArgs.from_dict(config))
    weights=load_weights(model_path);apply_quantization(model,config,weights)
    model.load_weights(list(model.sanitize(weights).items()));mx.eval(model.parameters())
    tokenizer=AutoTokenizer.from_pretrained(model_path,local_files_only=True,trust_remote_code=False)
    # Qwen2.5's fixed chat framing; escape transcript-supplied special-token delimiters.
    system=system.replace('<|','＜|');prompt=prompt.replace('<|','＜|')
    text=f'<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{prompt}<|im_end|>\n<|im_start|>assistant\n'
    answer=generate(model,tokenizer,text,max_tokens=384,verbose=False)
    pathlib.Path(output_path).write_text(json.dumps({'text':answer},ensure_ascii=False))

def pcm_chunks(stream):
    while True:
        data=stream.read(240000*4)
        if not data:return
        if len(data)%4:raise ValueError('Incomplete PCM stream')
        yield data

def diarize(model_path,audio_path,output,streaming=False,checkpoint=None):
    import miniaudio,numpy as np
    import mlx.core as mx
    from mlx_audio.vad import load
    configure_memory(mx)
    model=load(pathlib.Path(model_path).resolve(strict=True),strict=True)
    from speaker_timeline import SpeakerTimeline
    from diarization_checkpoint import restore,save
    state,base=restore(model,checkpoint,mx) if checkpoint else (model.init_streaming_state(),0.0)
    skip=float(json.loads(pathlib.Path(checkpoint).read_text()).get('skipSeconds',0)) if checkpoint and pathlib.Path(checkpoint).exists() else 0
    if not 0<=skip<=3.001:raise ValueError('Invalid diarization overlap')
    remaining=round(skip*16000)
    offset=0.0
    frame_duration=model.config.processor_config.hop_length*model.config.fc_encoder_config.subsampling_factor/16000
    timeline=SpeakerTimeline(frame_duration)
    chunks=(pcm_chunks(sys.stdin.buffer) if streaming else miniaudio.stream_file(audio_path,output_format=miniaudio.SampleFormat.FLOAT32,nchannels=1,sample_rate=16000,frames_to_read=240000))
    for chunk in chunks:
        samples=(np.frombuffer(chunk,dtype='<f4') if streaming else np.asarray(chunk,dtype=np.float32));duration=len(samples)/16000
        if remaining:
            n=min(remaining,len(samples));samples=samples[n:];remaining-=n;offset+=n/16000;duration=len(samples)/16000
            if not len(samples):continue
        # Offline finalization can revise the preceding chunk after more voice
        # context. Retain two transport chunks in a bounded FIFO, not a new
        # speaker identity space per ASR window.
        result,state=model.feed(samples,state,sample_rate=16000,threshold=0.5,min_duration=0.12,merge_gap=0.16,fifo_max=376)
        scores=np.asarray(result.speaker_probs).tolist()
        revised=np.asarray(state.fifo_preds)[0].tolist()
        # Earlier FIFO frames are already in the durable prior job; preserve
        # their identity cache but only revise frames present in this job.
        revised=revised[-(len(timeline.scores)+len(scores)):] if scores or timeline.scores else []
        timeline.append(scores,offset,duration,revised)
        offset+=duration;mx.clear_cache()
        print('Sortformer: %.1fs'%offset,file=sys.stderr,flush=True)
    pathlib.Path(output).write_text(json.dumps(dict(turns=timeline.turns(),frames=timeline.frames(),duration=offset,retrospectiveFIFO=True,frameCount=len(timeline.times))))
    if checkpoint:save(state,checkpoint,base+offset-skip,mx)

def stream_clips(max_seconds=MAX_ASR_SECONDS):
    stream=sys.stdin.buffer
    while True:
        prefix=stream.read(4)
        if not prefix:return
        if len(prefix)!=4:raise ValueError('Incomplete clip header')
        size=struct.unpack('<I',prefix)[0]
        if not 0<size<=65536:raise ValueError('Invalid clip header size')
        raw=stream.read(size)
        if len(raw)!=size:raise ValueError('Incomplete clip metadata')
        item=json.loads(raw);frames=item.get('frames')
        start,end=item.get('start'),item.get('end')
        validate_clip(item,max_seconds)
        data=stream.read(frames*4)
        if len(data)!=frames*4:raise ValueError('Incomplete clip PCM')
        yield item,data

def recognized_segment(model,audio,*,start,end,language,hotwords=None,recover_repeats=False):
    try:
        generated=generate_complete(model,audio,language=language,hotwords=hotwords)
    except TokenLimitReached:
        # Keep each sample exactly once; prefer a quiet point near the middle.
        # Bound recursion so a looping decoder cannot run indefinitely.
        if len(audio)<4*RATE:
            raise
        middle=len(audio)//2; step=RATE//10
        radius=min(2*RATE,len(audio)//4)
        candidates=range(middle-radius,middle+radius+1,step)
        cut=min(candidates,key=lambda n:(sum(float(x)*float(x) for x in audio[n-step//2:n+step//2]),abs(n-middle)))
        print('Qwen3-ASR: token limit; retrying bounded subwindows',file=sys.stderr,flush=True)
        # Do not discard repeat-recovery candidates belonging to a child.
        left=recognized_segment(model,audio[:cut],start=start,end=start+cut/RATE,language=language,hotwords=hotwords)
        right=recognized_segment(model,audio[cut:],start=start+cut/RATE,end=end,language=language,hotwords=hotwords)
        parts=[]
        for child in (left,right):
            if not child['text']:continue
            pieces=child.get('alignmentParts') or [dict(text=child['text'],start=child['start'],end=child['end'])]
            if parts and parts[-1]['text'][-1:].isascii() and not parts[-1]['text'][-1:].isspace() and pieces[0]['text'][:1].isascii() and pieces[0]['text'][:1].isalnum():
                pieces[0]=dict(pieces[0],text=' '+pieces[0]['text'])
            parts.extend(pieces)
        segment=dict(text=''.join(p['text'] for p in parts),start=start,end=end)
        if parts:segment['alignmentParts']=parts
        return segment
    text=generated.text.strip();segment=dict(text=text,start=start,end=end)
    if text and recover_repeats:
        from repeat_recovery import recover
        corrected=recover(model,audio,text,start,language,hotwords,generate_complete)
        if corrected:
            segment.update(corrected);text=segment['text']
            print('Qwen3-ASR: repeated output rechecked with two bounded windows; original retained',file=sys.stderr,flush=True)
    if text and 'alignmentParts' not in segment and len(audio)/16000>MAX_ALIGNMENT_SECONDS:
        from alignment_windows import prepare,AlignmentWindowError
        try:
            parts=prepare(model,audio,text,language=language,hotwords=hotwords)
            segment['alignmentParts']=[dict(text=p['text'],start=start+p['start'],end=start+p['end']) for p in parts]
        except (AlignmentWindowError,ValueError) as error:
            # Recognition remains authoritative; optional speaker/timestamp
            # analysis must not invent timing or erase this completed text.
            segment['alignmentIssue']=str(error)
            print('Bounded alignment preparation unavailable: '+str(error),file=sys.stderr,flush=True)
    return segment

def transcribe_stream(model_path,language,output,hints_path):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    hints=json.loads(pathlib.Path(hints_path).read_text());words=hints.get('words',[]);context=hints.get('context','')
    if not isinstance(words,list) or len(words)>1000 or any(not isinstance(w,str) or not 2<=len(w)<=40 or '\n' in w or '\r' in w for w in words):raise ValueError('Invalid hotwords')
    if not isinstance(context,str) or len(context)>2000:raise ValueError('Invalid hotword context')
    recover_repeats=hints.get('recoverRepeatedOutput',False)
    if not isinstance(recover_repeats,bool):raise ValueError('Invalid repeat recovery option')
    configure_memory(mx)
    model=load(pathlib.Path(model_path).resolve(strict=True));selected_language=recognition_language(language);result=[]
    for clip,data in stream_clips():
        segment=recognized_segment(model,np.frombuffer(data,dtype='<f4'),start=clip['start'],end=clip['end'],language=selected_language,hotwords=select_hotwords(words,context) or None,recover_repeats=recover_repeats)
        result.append(segment)
        context=(context+' '+segment['text'])[-2000:];mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

def adjacent_context(clip, following, following_audio, audio_frames):
    """Return up to 3s of contiguous audio after the clip, bounded by the model limit."""
    if following is None or following_audio is None:return None
    end=float(clip['end']); start=float(following['start'])
    duration=end-float(clip['start'])
    if abs(len(following_audio)-round((float(following['end'])-start)*16000))>1:return None
    if abs(audio_frames-round(duration*16000))>1:return None
    if start>end+1/16000 or float(following['end'])<=end:return None
    begin=max(0,round((end-start)*16000))
    count=min(3*16000,MAX_ALIGNMENT_SECONDS*16000-audio_frames,len(following_audio)-begin)
    return following_audio[begin:begin+count] if count>0 else None

def align_words_with_context(model,audio,text,language,clip,following=None,following_audio=None):
    import numpy as np
    from speaker_attribution import aligned_words
    duration=clip['end']-clip['start']
    def generate(samples):
        result=model.generate(audio=samples,text=text,language=language)
        return [dict(text=i.text,start=i.start_time,end=i.end_time) for i in result.items]
    items=generate(audio)
    outside=lambda x:x['start']>duration or x['end']>duration+.3
    if any(outside(x) for x in items):
        context=adjacent_context(clip,following,following_audio,len(audio))
        if context is not None:
            try:
                retried=generate(np.concatenate((audio,context)))
                if not any(outside(x) for x in retried):
                    rows=aligned_words(text,retried,clip['start'],duration)
                    print('ForcedAligner: recovered with contiguous audio context',file=sys.stderr,flush=True)
                    return rows
            except (ValueError,RuntimeError) as error:
                print('ForcedAligner: context retry unavailable: '+type(error).__name__,file=sys.stderr,flush=True)
    return aligned_words(text,items,clip['start'],duration)

def repair_alignment_seam(model,left,left_audio,left_rows,right,right_audio,right_rows):
    """Re-align a bounded contiguous seam without changing any recognized text."""
    import numpy as np
    from speaker_attribution import aligned_words
    if not left_rows or not right_rows:return left_rows,right_rows
    end=float(left['end']);start=float(right['start'])
    if abs(end-start)>1/16000:return left_rows,right_rows
    if abs(len(left_audio)-round((end-float(left['start']))*16000))>1:return left_rows,right_rows
    if abs(len(right_audio)-round((float(right['end'])-start)*16000))>1:return left_rows,right_rows
    tail=left_rows[-1]
    if not (tail.get('timingUncertain') and abs(tail['start']-end)<=.001 and abs(tail['end']-end)<=.001):return left_rows,right_rows
    if alignment_language(left.get('language','auto'),left['text']) != alignment_language(right.get('language','auto'),right['text']):return left_rows,right_rows
    before=min(12*16000,len(left_audio));after=min(12*16000,len(right_audio))
    if before<16000 or after<16000:return left_rows,right_rows
    lo=end-before/16000;hi=end+after/16000
    first=next((i for i,w in enumerate(left_rows) if w['start']>=lo),len(left_rows))
    last=0
    while last<len(right_rows) and right_rows[last]['end']<=hi:last+=1
    if first==len(left_rows) or last==0:return left_rows,right_rows
    selected=left_rows[first:]+right_rows[:last]
    if not any(not w.get('timingUncertain') and w['end']>w['start'] for w in left_rows[first:]):return left_rows,right_rows
    if not any(not w.get('timingUncertain') and w['end']>w['start'] for w in right_rows[:last]):return left_rows,right_rows
    expected=''.join(w.get('separator','')+w['text'] for w in selected)
    prefix=selected[0].get('separator','');text=expected[len(prefix):]
    if not text or len(text)>10000:return left_rows,right_rows
    try:
        samples=np.concatenate((left_audio[-before:],right_audio[:after]))
        result=model.generate(audio=samples,text=text,language=alignment_language(left.get('language','auto'),text))
        items=[dict(text=w.text,start=w.start_time,end=w.end_time) for w in result.items]
        repaired=aligned_words(text,items,lo,len(samples)/16000)
        if not repaired or any(w.get('timingUncertain') for w in repaired):return left_rows,right_rows
        repaired[0]['separator']=prefix
        if ''.join(w.get('separator','')+w['text'] for w in repaired)!=expected:return left_rows,right_rows
        if first and repaired[0]['start']<left_rows[first-1]['end']-.3:return left_rows,right_rows
        if last<len(right_rows) and repaired[-1]['end']>right_rows[last]['start']+.3:return left_rows,right_rows
        print('ForcedAligner: repaired boundary with contiguous audio',file=sys.stderr,flush=True)
        return left_rows[:first]+repaired,right_rows[last:]
    except (ValueError,RuntimeError) as error:
        print('ForcedAligner: boundary retry unavailable: '+type(error).__name__,file=sys.stderr,flush=True)
        return left_rows,right_rows

def with_following(items):
    iterator=iter(items)
    current=next(iterator,None)
    while current is not None:
        following=next(iterator,None)
        yield current,following
        current=following

def align_stream(model_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    configure_memory(mx)
    from sentence_speakers import attribute_sentences
    voice=json.loads(pathlib.Path(turns_path).read_text())
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    hotwords=[];pending=None
    for index,((clip,data),following) in enumerate(with_following(stream_clips(MAX_ALIGNMENT_SECONDS))):
        text=clip.get('text');language=clip.get('language','auto')
        if not isinstance(text,str) or not text or len(text)>100000:raise ValueError('Invalid alignment text')
        next_clip,next_data=following if following is not None else (None,None)
        audio=np.frombuffer(data,dtype='<f4')
        next_audio=np.frombuffer(next_data,dtype='<f4') if next_data is not None else None
        rows=align_words_with_context(model,audio,text,alignment_language(language,text),clip,next_clip,next_audio)
        hotwords.extend(clip.get('hotwords',[]))
        if rows:rows[0]['separator']=clip.get('separator','' if index==0 else '\n')
        if pending is not None:
            prev_clip,prev_audio,prev_rows=pending
            prev_rows,rows=repair_alignment_seam(model,prev_clip,prev_audio,prev_rows,clip,audio,rows)
            paragraphs.extend(prev_rows)
        pending=(clip,audio,rows);mx.clear_cache()
    if pending is not None:paragraphs.extend(pending[2])
    words=paragraphs
    paragraphs=attribute_sentences(words,voice['turns'],frames=voice.get('frames'),protected_words=hotwords)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs,alignedWords=words,attributionPolicy='sentence-v1'),ensure_ascii=False))

def align_speakers(model_path,manifest_path,turns_path,output):
    import numpy as np
    import mlx.core as mx
    from mlx_audio.stt import load
    configure_memory(mx)
    from sentence_speakers import attribute_sentences
    manifest=pathlib.Path(manifest_path).resolve(strict=True);clips=json.loads(manifest.read_text())
    voice=json.loads(pathlib.Path(turns_path).read_text())
    model=load(pathlib.Path(model_path).resolve(strict=True));paragraphs=[]
    hotwords=[];pending=None
    def read_audio(clip):
        path=pathlib.Path(clip['audio']).resolve(strict=True)
        if path.parent!=manifest.parent:raise ValueError('Invalid alignment audio path')
        with wave.open(str(path),'rb') as w:
            if w.getframerate()!=16000 or w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('Invalid alignment audio format')
            return np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768
    def inputs():
        for clip in clips:yield clip,read_audio(clip)
    for index,((clip,audio),following) in enumerate(with_following(inputs())):
        next_clip,next_audio=following if following is not None else (None,None)
        language=alignment_language(clip.get('language','auto'),clip['text'])
        rows=align_words_with_context(model,audio,clip['text'],language,clip,next_clip,next_audio)
        hotwords.extend(clip.get('hotwords',[]))
        if rows:rows[0]['separator']=clip.get('separator','' if index==0 else '\n')
        if pending is not None:
            prev_clip,prev_audio,prev_rows=pending
            prev_rows,rows=repair_alignment_seam(model,prev_clip,prev_audio,prev_rows,clip,audio,rows)
            paragraphs.extend(prev_rows)
        pending=(clip,audio,rows);mx.clear_cache()
        print('ForcedAligner: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
    if pending is not None:paragraphs.extend(pending[2])
    words=paragraphs
    paragraphs=attribute_sentences(words,voice['turns'],frames=voice.get('frames'),protected_words=hotwords)
    pathlib.Path(output).write_text(json.dumps(dict(paragraphs=paragraphs,alignedWords=words,attributionPolicy='sentence-v1'),ensure_ascii=False))

def main():
    if len(sys.argv)==7 and sys.argv[1]=='--splice-seam':
        from overlap_words import splice_prefix
        source,prefix,count,seconds,output=sys.argv[2:]
        old=json.loads(pathlib.Path(source).read_text());new=json.loads(pathlib.Path(prefix).read_text())
        words=splice_prefix(old['alignedWords'],new['alignedWords'],int(count),float(seconds))
        pathlib.Path(output).write_text(json.dumps(dict(alignedWords=words),ensure_ascii=False));return
    if len(sys.argv)==7 and sys.argv[1]=='--crop-speakers':
        from speaker_attribution import normalized
        from sentence_speakers import attribute_sentences
        source,voice,cut,prior,output=sys.argv[2:];cut=float(cut)
        data=json.loads(pathlib.Path(source).read_text());words=data['alignedWords'];hints=json.loads(pathlib.Path(prior).read_text());context=hints['context']
        from overlap_words import crop
        proof=[];words,dropped=crop(words,cut,context,proof)
        if words:words[0]['separator']=''
        v=json.loads(pathlib.Path(voice).read_text());rows=attribute_sentences(words,v['turns'],frames=v.get('frames'),protected_words=hints['words'])
        pathlib.Path(output).write_text(json.dumps(dict(paragraphs=rows,text=''.join(r.get('separator','')+r['text']for r in rows),discardedOverlap=''.join(w['text']for w in dropped),seamOwnership=proof),ensure_ascii=False));return
    if len(sys.argv)==5 and sys.argv[1]=='--diarize-stream-checkpoint':
        diarize(sys.argv[2],None,sys.argv[3],streaming=True,checkpoint=sys.argv[4]);return
    if len(sys.argv)==6 and sys.argv[1]=='--diarize-checkpoint':
        diarize(sys.argv[2],sys.argv[3],sys.argv[4],checkpoint=sys.argv[5]);return
    if len(sys.argv)==6 and sys.argv[1]=='--transcribe-stream':
        transcribe_stream(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--align-stream':
        align_stream(*sys.argv[2:]);return
    if len(sys.argv)==4 and sys.argv[1]=='--diarize-stream':
        diarize(sys.argv[2],None,sys.argv[3],streaming=True);return
    if len(sys.argv) in (4,5) and sys.argv[1]=='--live':
        from live_transcription import run_live
        run_live(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--extract-hotwords':
        extract_hotwords(*sys.argv[2:]);return
    if len(sys.argv)==5 and sys.argv[1]=='--diarize':
        diarize(*sys.argv[2:]);return
    if len(sys.argv)==6 and sys.argv[1]=='--align-speakers':
        align_speakers(*sys.argv[2:]);return
    if len(sys.argv) not in (5,6):raise ValueError('usage: qwen-asr modelDirectory segmentsJSON language outputJSON [hotwordsJSON]')
    model_path,manifest,language,output=sys.argv[1:5]
    hints=json.loads(pathlib.Path(sys.argv[5]).read_text()) if len(sys.argv)==6 else {}
    words=hints.get('words',[])
    if not isinstance(words,list) or len(words)>1000 or any(not isinstance(w,str) or not 2<=len(w)<=40 or '\n' in w or '\r' in w for w in words):raise ValueError('Invalid hotwords')
    context=hints.get('context','')
    if not isinstance(context,str) or len(context)>2000:raise ValueError('Invalid hotword context')
    model_path=pathlib.Path(model_path).resolve(strict=True)
    manifest=pathlib.Path(manifest).resolve(strict=True)
    clips=json.loads(manifest.read_text())
    selected_language=recognition_language(language)
    for clip in clips:
        start,end=clip['start'],clip['end']
        path=pathlib.Path(clip['audio']).resolve(strict=True)
        if path.parent!=manifest.parent or not (math.isfinite(start) and math.isfinite(end) and 0<=start<end and end-start<=MAX_ASR_SECONDS):
            raise ValueError('Invalid speech clip')
        with wave.open(str(path),'rb') as w:
            if w.getframerate()!=16000 or w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('Expected mono PCM16 16kHz')
    result=[]
    if clips:
        import numpy as np
        import mlx.core as mx
        from mlx_audio.stt import load
        configure_memory(mx)
        model=load(model_path)
        for index,clip in enumerate(clips):
            with wave.open(clip['audio'],'rb') as w:audio=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768
            validate_clip(dict(frames=len(audio),start=clip['start'],end=clip['end']))
            selected=select_hotwords(words,context)
            segment=recognized_segment(model,audio,start=clip['start'],end=clip['end'],language=selected_language,hotwords=selected or None)
            result.append(segment)
            context=(context+' '+segment['text'])[-2000:]
            print('Qwen3-ASR: %d/%d'%(index+1,len(clips)),file=sys.stderr,flush=True)
            mx.clear_cache()
    output=pathlib.Path(output);temp=output.with_suffix('.partial')
    temp.write_text(json.dumps({'segments':result},ensure_ascii=False));temp.replace(output)

if __name__=='__main__':
    # 冻结运行时的资源追踪子进程必须先分流，不能误作ASR请求。
    import multiprocessing
    multiprocessing.freeze_support()
    try:
        from inference_lock import exclusive
        if len(sys.argv)>1 and sys.argv[1]=='--live':main()
        else:
            with exclusive():main()
    except Exception as e:
        print('本地Qwen3-ASR推理失败：'+str(e),file=sys.stderr,flush=True)
        sys.exit(1)
