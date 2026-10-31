"""Socket-level supervision/migration fixtures, independent of Zig internals."""
import contextlib, ctypes as c, queue, socket, struct, threading, time
from pathlib import Path


def fixtures(work, public, decrypt, library="libsupervisor-fixture.dylib", prefix="supervisor_fixture_"):
    lib=c.CDLL(str(Path(work)/library)) if library else None
    P=c.c_void_p; Z=c.c_size_t; U8=c.POINTER(c.c_uint8)
    class Header(c.Structure):
        _fields_=[('kind',c.c_uint32),('detail',c.c_uint32),('generation',c.c_uint64),('key',c.c_uint16),('value',c.c_uint64)]
    signatures={
        'create':([Z],P), 'connect':([P,c.c_char_p,c.c_uint16,U8,Z],c.c_int),
        'cancel':([P],None), 'destroy':([P],None),
        'next':([P,c.POINTER(Header),c.POINTER(U8),c.POINTER(Z)],P), 'event_destroy':([P],None),
        'send':([P,c.c_uint8,c.c_uint8,c.c_uint16,U8,Z],c.c_int), 'send_agent':([P,U8,Z],c.c_int),
    }
    fn={}
    for name,(args,result) in (signatures.items() if lib else []):
        f=getattr(lib,prefix+name); f.argtypes=args; f.restype=result; fn[name]=f
    secret=(c.c_uint8*14).from_buffer_copy(b'synthetic-test')
    def exact(conn,size):
        data=bytearray()
        while len(data)<size:
            part=conn.recv(size-len(data))
            if not part: raise EOFError
            data.extend(part)
        return bytes(data)
    def frame(kind,body=b''): return struct.pack('<HI',kind,len(body))+body
    def offer(port,seamless=False):
        host=b'127.0.0.1\0'
        body=struct.pack('<HHI',port,0,len(host))+host+struct.pack('<I',0)
        return body+(struct.pack('<I',9) if seamless else b'')
    class Peer:
        def __init__(self,keys=(),target=False,seamless=False,parallel=False,fail_key=None,stall_auth=False,agent=False,pause_agent=False):
            self.keys=keys; self.target=target; self.seamless=seamless; self.parallel=parallel; self.fail_key=fail_key; self.stall_auth=stall_auth; self.agent=agent; self.pause_agent=pause_agent
            self.stop=threading.Event(); self.accepted=threading.Event(); self.agent_prefix=threading.Event(); self.agent_release=threading.Event()
            self.condition=threading.Condition(); self.connections={}; self.sockets=[]; self.threads=[]; self.errors=[]; self.messages=queue.Queue(); self.backlog=[]; self.child_started=0
            self.listener=socket.socket(); self.listener.bind(('127.0.0.1',0)); self.listener.listen(); self.listener.settimeout(.1); self.port=self.listener.getsockname()[1]
        def __enter__(self):
            self.thread=threading.Thread(target=self.accept); self.thread.start(); return self
        def accept(self):
            while not self.stop.is_set():
                try: conn,_=self.listener.accept()
                except socket.timeout: continue
                except OSError: break
                conn.settimeout(8); self.sockets.append(conn); self.accepted.set()
                thread=threading.Thread(target=self.serve,args=(conn,)); self.threads.append(thread); thread.start()
        def serve(self,conn):
            try:
                magic,major,minor,size=struct.unpack('<4I',exact(conn,16)); assert (magic,major,minor)==(0x51444552,2,2)
                request=exact(conn,size); connection_id,kind,identifier=struct.unpack('<IBB',request[:6]); key=(kind,identifier)
                assert connection_id==(0 if key==(1,0) else 0x1234)
                if self.stall_auth: self.stop.wait(8); return
                with self.condition:
                    if key!=(1,0): self.child_started+=1; self.condition.notify_all()
                body=struct.pack('<I',0)+public+struct.pack('<III',1,1,178)+struct.pack('<II',11,13 if key==(1,0) else 0)
                conn.sendall(struct.pack('<4I',magic,2,2,len(body))+body)
                assert exact(conn,4)==struct.pack('<I',1)
                assert decrypt(exact(conn,128))==b'synthetic-test\0'
                if self.parallel and key!=(1,0):
                    with self.condition: assert self.condition.wait_for(lambda:self.child_started>=min(4,len(self.keys)) or self.stop.is_set(),3),'child connections were serialized'
                conn.sendall(struct.pack('<I',1 if key==self.fail_key else 0))
                if key==self.fail_key: return
                if key==(1,0):
                    if self.target:
                        if self.seamless:
                            message,size=struct.unpack('<HI',exact(conn,6)); assert message==110 and exact(conn,size)==struct.pack('<I',9)
                            conn.sendall(frame(117))
                    else:
                        conn.sendall(frame(103,struct.pack('<8I',0x1234,1,3,2,int(self.agent),10000 if self.agent else 0,100,0)))
                        if self.agent:
                            message,size=struct.unpack('<HI',exact(conn,6)); assert message==106 and exact(conn,size)==struct.pack('<I',8)
                        message,size=struct.unpack('<HI',exact(conn,6)); assert (message,size)==(104,0)
                        conn.sendall(frame(104,struct.pack('<I',len(self.keys))+b''.join(bytes(k) for k in self.keys)))
                with self.condition: self.connections[key]=conn; self.condition.notify_all()
                while not self.stop.is_set():
                    message,size=struct.unpack('<HI',exact(conn,6)); payload=exact(conn,size); self.messages.put((key,message,payload))
                    if key==(1,0) and message==107 and self.pause_agent:
                        self.agent_prefix.set(); self.agent_release.wait(8)
            except (EOFError,ConnectionError,OSError): pass
            except BaseException as error: self.errors.append(error)
            finally:
                try: conn.close()
                except OSError: pass
        def connection(self,key):
            with self.condition:
                assert self.condition.wait_for(lambda:key in self.connections or self.errors,4),('missing connection',key,self.errors)
                if self.errors: raise self.errors[0]
                return self.connections[key]
        def send(self,key,kind,body=b''): self.connection(key).sendall(frame(kind,body))
        def message(self,key,kind,timeout=4):
            for index,item in enumerate(self.backlog):
                if item[0]==key and item[1]==kind:
                    self.backlog.pop(index); return item[2]
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                item=self.messages.get(timeout=max(.01,deadline-time.monotonic()))
                if item[0]==key and item[1]==kind:return item[2]
                self.backlog.append(item)
            raise AssertionError(('missing client message',key,kind))
        def __exit__(self,*_):
            self.stop.set(); self.agent_release.set()
            with self.condition:self.condition.notify_all()
            self.listener.close()
            for conn in self.sockets:
                try:conn.shutdown(socket.SHUT_RDWR)
                except OSError:pass
            self.thread.join(3)
            for thread in self.threads:thread.join(4);assert not thread.is_alive(),'peer thread did not stop'
            if self.errors:raise self.errors[0]
    class Client:
        def __init__(self,capacity=256,pump=True):
            self.handle=fn['create'](capacity);assert self.handle;self.events=queue.Queue();self.pump_enabled=pump;self.thread=None
        def connect(self,peer):return fn['connect'](self.handle,b'127.0.0.1',peer.port,secret,len(secret))
        def start(self):
            def pump():
                while True:
                    header=Header();data=U8();size=Z();event=fn['next'](self.handle,c.byref(header),c.byref(data),c.byref(size))
                    if not event:break
                    try:self.events.put((header.kind,header.detail,header.generation,header.key,header.value,bytes(data[:size.value]) if data else b''))
                    finally:fn['event_destroy'](event)
            self.thread=threading.Thread(target=pump);self.thread.start()
        def event(self,kind,detail=None,timeout=5):
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                value=self.events.get(timeout=max(.01,deadline-time.monotonic()))
                if value[0]==kind and (detail is None or value[1]==detail):return value
                assert value[0]!=3,('unexpected session failure',value)
            raise AssertionError(('missing event',kind,detail))
        def close(self):
            fn['cancel'](self.handle)
            if self.thread:self.thread.join(4);assert not self.thread.is_alive(),'event consumer did not stop'
            fn['destroy'](self.handle);self.handle=None
    return Peer, Client, fn, frame, offer


def run(work, public, decrypt):
    Peer, Client, fn, frame, offer = fixtures(work, public, decrypt)
    checks=[]
    keys=[(2,i) for i in range(6)]
    with Peer(keys,parallel=True) as source:
        client=Client()
        try:
            assert client.connect(source)==0;client.start();client.event(1)
            source.send((2,3),601,b'first');event=client.event(5);assert event[4:]==(1,b'first')
            source.connection((2,2)).shutdown(socket.SHUT_RDWR);client.event(3);client.event(2)
        finally:client.close()
    checks.append('bounded concurrent child establishment and whole-session child failure supervision')
    with Peer(keys,parallel=True,fail_key=(2,2)) as source:
        client=Client()
        try:assert client.connect(source)==-1
        finally:client.close()
    with Peer(stall_auth=True) as source:
        client=Client();result=[];thread=threading.Thread(target=lambda:result.append(client.connect(source)));thread.start()
        try:
            assert source.accepted.wait(2);fn['cancel'](client.handle);thread.join(4);assert not thread.is_alive() and result==[-1]
        finally:fn['cancel'](client.handle);thread.join(4);client.close()
    checks.append('failed parallel preparation drains siblings; cancellation interrupts stalled session authentication')
    for seamless in (False,True):
        keys=[(2,0),(3,1)]
        with Peer(keys) as source,Peer(keys,target=True,seamless=seamless) as target:
            client=Client()
            try:
                assert client.connect(source)==0;client.start();client.event(1)
                source.send((2,0),601,b'before');before=client.event(5)
                source.send((1,0),116 if seamless else 101,offer(target.port,seamless))
                preparing=client.event(6,0);ready=client.event(6,1);assert ready[4]==preparing[4]
                source.message((1,0),111 if seamless else 102)
                if seamless:
                    for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,bytes(key)+b'migration')
                    for key in [(1,0),*keys]:assert target.message(key,5)==bytes(key)+b'migration'
                else:source.send((1,0),112)
                completed=client.event(6,5);assert completed[4]==ready[4] and completed[2]>before[2]
                target.send((2,0),601,b'after');after=client.event(5);assert after[4:]==(2,b'after') and after[2]==completed[2]
                target.send((1,0),105,struct.pack('<HH',3,1));mouse=client.event(4);assert mouse[4]==1
            finally:client.close()
    checks.append('semi-seamless and all-channel seamless commit preserve child state and advance generation; migration payloads reach corresponding targets')
    for cancel_first in (False,True):
        with Peer([(2,0)]) as source,Peer([(2,0)],target=True,seamless=True) as target:
            client=Client()
            try:
                assert client.connect(source)==0;client.start();client.event(1)
                source.send((1,0),116,offer(target.port,True));client.event(6,1);source.message((1,0),111)
                if not cancel_first:source.send((2,0),1,struct.pack('<I',0))
                source.send((1,0),102);client.event(6,2)
                if cancel_first:source.send((2,0),1,struct.pack('<I',0))
                source.send((2,0),601,b'resumed');assert client.event(5)[5]==b'resumed'
                # The cancelled handoff permits only its one outstanding boundary.
                source.send((2,0),1,struct.pack('<I',0));client.event(3);client.event(2)
            finally:client.close()
    checks.append('cancelled partial seamless migration resumes paused source channels')
    with Peer([(2,0)]) as source,Peer([(2,0)]) as target:
        client=Client()
        try:
            assert client.connect(source)==0;client.start();client.event(1)
            source.send((2,0),601,b'old');before=client.event(5)
            source.send((1,0),111,offer(target.port));completed=client.event(6,5)
            target.send((2,0),601,b'fresh');after=client.event(5)
            assert after[4:]==(1,b'fresh') and after[2]>before[2] and after[2]==completed[2]
        finally:client.close()
    checks.append('switch-host performs fresh Main/child bootstrap and resets child state')
    with Peer([]) as source,Peer(target=True,stall_auth=True) as old_target,Peer(target=True) as new_target:
        client=Client()
        try:
            assert client.connect(source)==0;client.start();client.event(1)
            source.send((1,0),101,offer(old_target.port));old=client.event(6,0);assert old_target.accepted.wait(2)
            source.send((1,0),101,offer(new_target.port));client.event(6,2);new=client.event(6,0);ready=client.event(6,1)
            assert old[4]!=new[4] and ready[4]==new[4]
            source.message((1,0),102);source.send((1,0),112);assert client.event(6,5)[4]==new[4]
        finally:client.close()
    checks.append('new migration offer cancels obsolete preparation and ignores its late failure')
    with Peer([(2,0)]) as source:
        client=Client(capacity=1,pump=False)
        try:
            assert client.connect(source)==0
            for _ in range(64):source.send((2,0),601,b'queue-pressure')
        finally:client.close()
    checks.append('disconnect unblocks bounded event queue producers and joins receiver/control threads')
    # A blocked old Agent sender must not prevent the target receiving updates.
    for cancel_during_drain in (False,True):
        with Peer([],agent=True,pause_agent=True) as source,Peer([],target=True,seamless=True) as target:
            client=Client();sender=None;result=[]
            try:
                assert client.connect(source)==0;client.start();client.event(1)
                source.send((1,0),116,offer(target.port,True));client.event(6,1);source.message((1,0),111)
                payload=(c.c_uint8*(16*1024*1024))()
                sender=threading.Thread(target=lambda:result.append(fn['send_agent'](client.handle,payload,len(payload))));sender.start()
                assert source.agent_prefix.wait(3)
                source.send((1,0),1,struct.pack('<I',0));client.event(6,5)
                target.send((1,0),105,struct.pack('<HH',3,1));assert client.event(4)[4]==1
                if cancel_during_drain:fn['cancel'](client.handle)
                else:source.agent_release.set()
                sender.join(6);assert not sender.is_alive();assert result==([-1] if cancel_during_drain else [1]),result
            finally:
                fn['cancel'](client.handle);source.agent_release.set()
                if sender:sender.join(4);assert not sender.is_alive()
                client.close()
    checks.append('target processing proceeds during retired Main Agent drain; cancellation joins active sender and drain safely')
    return checks
