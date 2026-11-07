#!/usr/bin/env python3
import json,struct,sys
from pathlib import Path
assert sys.argv[1]=='--transcribe-stream'
assert json.loads(Path(sys.argv[5]).read_text())['recoverRepeatedOutput'] is True
s=sys.stdin.buffer;rows=[]
while True:
 prefix=s.read(4)
 if not prefix:break
 size=struct.unpack('<I',prefix)[0];clip=json.loads(s.read(size));n=clip['frames']*4
 while n:
  chunk=s.read(min(n,65536));assert chunk;n-=len(chunk)
 rows.append(dict(start=clip['start'],end=clip['end'],text='复核正文。',originalText='首版重复。首版重复。',alignmentParts=[dict(text='复核正文。',start=clip['start'],end=clip['end'])]))
Path(sys.argv[4]).write_text(json.dumps(dict(segments=rows),ensure_ascii=False))
