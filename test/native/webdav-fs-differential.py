#!/usr/bin/env python3
"""Unchanged production Swift HTTP/filesystem server vs descriptor-relative Zig."""
import ctypes as C,json,os,shutil,subprocess,sys,tempfile
from pathlib import Path
work=Path(sys.argv[1]);lib=C.CDLL(str(work/'libwebdav-fs.dylib'))
run=lib.webdav_fs_execute;run.argtypes=[C.c_char_p,C.c_uint8,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_void_p),C.POINTER(C.c_size_t)];run.restype=C.c_int
free=lib.webdav_fs_free;free.argtypes=[C.c_void_p,C.c_size_t]
def request(method,target='/',headers=None,body=b''):
 if isinstance(body,str):body=body.encode()
 return f'{method} {target} HTTP/1.1\r\nContent-Length: {len(body)}\r\n'.encode()+b''.join(f'{k}: {v}\r\n'.encode() for k,v in (headers or {}).items())+b'\r\n'+body
def fixture(root):
 root.mkdir();(root/'folder').mkdir();(root/'folder'/'nested').write_bytes(b'nested')
 for name in ['hello','a&b','A','z','é','Å','ä','中','😊','.hidden']:(root/name).write_bytes(('contents '+name).encode())
 (root/'empty').write_bytes(b'');
 for name in ['locked','locked-put']:(root/name).write_bytes(b'permission fixture');(root/name).chmod(0)
 (root/'link').symlink_to('hello');(root/'dir-link').symlink_to('folder');(root/'escape').symlink_to('/etc/passwd');(root/'dangling').symlink_to('missing')
 for p in list(root.rglob('*'))+[root]:os.utime(p,(1700000000,1700000000),follow_symlinks=False)
def zig(root,rw,limit,data):
 ptr=C.c_void_p();size=C.c_size_t();status=run(os.fsencode(root),rw,limit,data,len(data),C.byref(ptr),C.byref(size));result=dict(status=status,bytes=list(C.string_at(ptr,size.value)) if ptr.value else [])
 if ptr.value:free(ptr,size.value)
 return result
count=0
with tempfile.TemporaryDirectory(prefix='spice-zig-webdav-oracle-') as temp:
 base=Path(temp);shared=base/'read';fixture(shared)
 groups=[]
 # Both implementations inspect exactly the same inode metadata for read-only PROPFIND.
 for limit in [0,4,128,4096,65536]:
  commands=[]
  for target in ['/','/hello','/empty','/folder','/link','/dir-link','/escape','/dangling','/missing','/absent/child','/%2e%2e/x','/%00','/%GG','?/hello?query','http://host/hello?q','/a%26b','/é','/e\u0301','//hello','/hello?\u0301q','/locked']:
   for method in ['GET','HEAD','PROPFIND','OPTIONS','BAD']:
    commands.append(request(method,target,{'Depth':'0'} if method=='PROPFIND' else None))
  for depth in ['0','1','infinity','2','01']:commands.append(request('PROPFIND','/',{'Depth':depth}))
  for method in ['PUT','MKCOL','DELETE','COPY','MOVE']:commands.append(request(method,'/hello',{'Destination':'/copy'}))
  groups.append((shared,shared,False,limit,commands))
 # Depth-one golden ordering without deliberately escaping/dangling children.
 clean=base/'clean';fixture(clean);(clean/'escape').unlink();(clean/'dangling').unlink();os.mkfifo(clean/'fifo');os.utime(clean/'fifo',(1700000000,1700000000));os.utime(clean,(1700000000,1700000000))
 groups.append((clean,clean,False,65536,[request('PROPFIND','/',{'Depth':'1'}),request('PROPFIND','/folder',{'Depth':'1'})]))
 # Mutations run on two independent owned roots; responses and final trees compare.
 left=base/'left';right=base/'rght';fixture(left);fixture(right)
 commands=[request('MKCOL','/new'),request('PUT','/new/data',body='abc'),request('GET','/new/data'),request('PUT','/new/data',body='updated'),request('COPY','/new/data',{'Destination':'/copy'}),request('COPY','/new/data',{'Destination':'/copy','Overwrite':'F'}),request('MOVE','/copy',{'Destination':'/moved'}),request('HEAD','/moved'),request('COPY','/link',{'Destination':'/copy-link'}),request('PUT','/link',body='link replacement'),request('GET','/hello'),request('DELETE','/copy-link'),request('GET','/hello'),request('DELETE','/new'),request('DELETE','/'),request('MKCOL','/folder'),request('MKCOL','/unmade',body='x'),request('PUT','/absent/child',body='x'),request('COPY','/folder',{'Destination':'/bad'}),request('MOVE','/hello',{'Destination':'/absent/child'}),request('COPY','/missing',{'Destination':'/absent/child'})]
 commands += [request('COPY','/hello',{'Destination':'/metadata-copy'}),request('PROPFIND','/locked',{'Depth':'0'}),request('PUT','/locked-put',body='changed'),request('MOVE','/locked',{'Destination':'/locked-moved'}),request('GET','/locked-moved'),request('PROPFIND','/locked-moved',{'Depth':'0'})]
 groups.append((left,right,True,65536,commands))
 payload=''.join(json.dumps(dict(root=str(left),write=rw,limit=limit,requests=[list(x) for x in commands]))+'\n' for left,right,rw,limit,commands in groups)
 result=subprocess.run([str(work/'webdav-fs-oracle')],input=payload,text=True,capture_output=True,check=True)
 rows=result.stdout.splitlines();assert len(rows)==len(groups),(result.stderr,rows)
 for group,row in zip(groups,rows):
  left,right,rw,limit,commands=group
  expected=json.loads(row)
  for index,(data,want) in enumerate(zip(commands,expected)):
   actual=zig(right,rw,limit,data);count+=1
   if actual!=want:raise AssertionError((str(right),limit,index,data,want['status'],actual['status'],bytes(want['bytes']),bytes(actual['bytes'])))
 def contents(p):
  mode=p.stat().st_mode & 0o777
  try:p.chmod(mode|0o400);return p.read_bytes(),mode
  finally:p.chmod(mode)
 def tree(root):
  result={}
  for p in root.rglob('*'):
   key=str(p.relative_to(root));result[key]=('link',os.readlink(p)) if p.is_symlink() else ('dir',) if p.is_dir() else ('file',)+contents(p)
  return result
 for root in [left,right]:assert (root/'metadata-copy').stat().st_mtime_ns==(root/'hello').stat().st_mtime_ns
 assert tree(left)==tree(right),(tree(left),tree(right))
print(json.dumps(dict(cases=count,result='exact response bytes and final mutation tree')))
