#!/usr/bin/python3
import json,pathlib,struct,sys
assert sys.argv[1]=='--transcribe-stream'
hints=json.loads(pathlib.Path(sys.argv[5]).read_text());assert hints['allowParaformerFallback'] is True
rows=[]
while True:
 prefix=sys.stdin.buffer.read(4)
 if not prefix:break
 size=struct.unpack('<I',prefix)[0];clip=json.loads(sys.stdin.buffer.read(size));remaining=clip['frames']*4
 while remaining:
  data=sys.stdin.buffer.read(min(remaining,65536));assert data;remaining-=len(data)
 index=len(rows);text=['alpha repeated shared text','repeated shared text beta','beta next'][index]
 rows.append(dict(start=clip['start'],end=clip['end'],text=text,fallback=(index==1)))
pathlib.Path(sys.argv[4]).write_text(json.dumps(dict(segments=rows)))
