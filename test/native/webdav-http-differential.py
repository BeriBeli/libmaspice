#!/usr/bin/env python3
"""Unmodified production Swift parser vs Zig; arbitrary bytes and Unicode boundaries."""
import ctypes as C,json,random,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]); lib=C.CDLL(str(work/'libwebdav-http.dylib')); parse=lib.webdav_http_parse
parse.argtypes=[C.c_void_p,C.c_size_t,C.c_size_t,C.c_size_t,C.c_uint64,C.c_void_p,C.c_size_t,C.c_void_p];parse.restype=C.c_int
rng=random.Random(0xDA71);cases=[]
def add(data,header=65536,body=67108864,sequence=0):
 if isinstance(data,str):data=data.encode()
 cases.append(dict(bytes=list(data),header=header,body=body,sequence=sequence))
valid=['GET / HTTP/1.1\r\n\r\n','put /é HTTP/1.0\r\nContent-Length: 3\r\n\r\nabc',' HEAD  /  HTTP/1.1 \r\n\r\n']
for text in valid:
 raw=text.encode()
 for n in range(len(raw)+1):add(raw[:n])
 for limit in range(len(raw)+2):add(raw,header=limit)
 add(raw+raw);add(raw,sequence=2**64-1)
for text in ['\ufeffGET / HTTP/1.1\r\n\r\n','GET / HTTP/1.1\r\n\ufeffContent-Length: 0\r\n\r\n','\ufeffGET /e\u0301 HTTP/1.1\r\n\r\n']:
 add(text)
for name in ['Content-Length','CONTENT-LENGTH',' Content-Length\t','\u2003content-length\u00a0']:
 for value in ['0','+0','-0','00003','+3','-1','',' 3 ','1_0','0x3','٣','３','9223372036854775807','9223372036854775808','18446744073709551616','+','\r3','3\n']:
  for body in [0,3,64,2**63-1]:add(f'GET / HTTP/1.1\r\n{name}: {value}\r\n\r\nabc',body=body)
for name in ['é','e\u0301','Å','A\u030a','İ','i\u0307','Σ','σ','K','K']:
 for other in ['é','e\u0301','Å','A\u030a','İ','i\u0307','Σ','σ','K','K']:
  add(f'GET / HTTP/1.1\r\n{name}: a\r\n{other}: b\r\n\r\n')
for space in [' ','\t','\u00a0','\u2003','\u200b','\u2028','\n','\r','\x00']:
 for key in ['X','Content-Length','Transfer-Encoding']:
  add(f'GET / HTTP/1.1\r\n{space}{key}{space}:{space}0{space}\r\n\r\n')
for method in ['get','propfind','straße','iıİ','Ὀδυσσεύς','ſ','ﬃ','ΣΟΣ','\x00']:
 add(f'{method} / HTTP/1.1\r\n\r\n')
# Character-level splitting/colon search must preserve Foundation String semantics.
for weird in [' \u0301',':\u0301','\r\n\u0301',' \u200d',':\ufe0f']:
 add(f'GET{weird}/ HTTP/1.1\r\n\r\n');add(f'GET / HTTP/1.1\r\nX{weird}value\r\n\r\n')
for _ in range(2500):
 raw=bytearray(rng.choice(valid).encode())
 for _ in range(rng.randrange(1,5)):
  if raw:raw[rng.randrange(len(raw))]=rng.randrange(256)
 add(raw,header=rng.choice([16,32,64,65536]),body=rng.choice([0,3,64]))
inputs=''.join(json.dumps(c)+'\n' for c in cases)
p=subprocess.run([str(work/'webdav-http-oracle')],input=inputs,text=True,capture_output=True,check=True)
rows=p.stdout.splitlines();assert len(rows)==len(cases)
for i,(case,line) in enumerate(zip(cases,rows)):
 data=bytes(case['bytes']);out=C.create_string_buffer(1024*1024);meta=(C.c_uint64*6)();status=parse(data,len(data),case['header'],case['body'],case['sequence'],out,len(out),meta)
 actual=dict(status=status,meta=list(meta) if status==1 else [],bytes=list(out.raw[:meta[5]]) if status==1 else [])
 expected=json.loads(line)
 if actual!=expected:raise AssertionError((i,case,expected,actual))
print(json.dumps(dict(cases=len(cases),seed='0xda71',result='exact parser outputs and errors')))
