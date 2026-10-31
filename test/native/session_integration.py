"""Independent socket peer checks for the Zig session/channel C boundary."""
import ctypes as c
import struct
import threading


def run(lib, peer, exact, public, decrypt, call_thread, finish):
    P, Z = c.c_void_p, c.c_size_t
    U8, U32 = c.POINTER(c.c_uint8), c.POINTER(c.c_uint32)
    class Requirement(c.Structure):
        _fields_ = [('kind', c.c_uint8), ('id', c.c_uint8), ('serial', c.c_uint64)]
    class Info(c.Structure):
        _fields_ = [(name, c.c_uint32) for name in ('session', 'time', 'supported', 'current', 'agent')]
    class Metadata(c.Structure):
        _fields_ = [('kind',c.c_uint16), ('wire',c.c_uint16), ('protocol',c.c_uint32),
                    ('value',c.c_uint32), ('auxiliary',c.c_uint32), ('opaque',c.c_uint64)]
    signatures = {
        'main_create': ([P],P), 'main_cancel': ([P],None), 'main_destroy': ([P],None),
        'main_bootstrap': ([P,c.POINTER(P)],c.c_int), 'main_bootstrap_destroy': ([P],None),
        'main_bootstrap_info': ([P,c.POINTER(Info)],c.c_int), 'main_bootstrap_channels': ([P,c.POINTER(Z)],U8),
        'main_next': ([P,c.POINTER(P)],c.c_int), 'main_event_destroy': ([P],None),
        'main_event_data': ([P,c.POINTER(Z)],U8), 'main_event_metadata': ([P,c.POINTER(Metadata)],c.c_int),
        'agent_send_token_create': ([],P), 'agent_send_token_destroy': ([P],None),
        'agent_send': ([P,c.c_uint32,c.c_uint32,c.c_uint64,U8,Z,P],c.c_int),
        'session_create': ([Z], P), 'session_cancel': ([P], None), 'session_destroy': ([P], None),
        'session_connect': ([P, c.c_char_p, c.c_uint16, c.c_uint8, c.c_char_p, c.c_char_p, P, Z, c.c_uint32,
                             c.c_uint32, c.c_uint8, c.c_uint8, U32, Z, U32, Z, U8, Z, c.POINTER(P)], c.c_int),
        'channel_receive': ([P, c.POINTER(P)], c.c_int), 'channel_complete': ([P], c.c_int),
        'channel_set_ack': ([P, c.c_uint32, c.c_uint32], None),
        'channel_send': ([P, c.c_uint16, U8, Z], c.c_int),
        'event_destroy': ([P], None), 'event_kind': ([P], c.c_int), 'event_serial': ([P], c.c_uint64),
        'event_data': ([P, c.POINTER(Z)], U8),
        'wait_create': ([], P), 'wait_destroy': ([P], None), 'wait_cancel': ([P, P], None),
        'session_wait': ([P, c.POINTER(Requirement), Z, P], c.c_int),
    }
    fn = {}
    for name, (args, result) in signatures.items():
        f = getattr(lib, 'spice_zig_' + name); f.argtypes = args; f.restype = result; fn[name] = f
    password = (c.c_uint8 * 14).from_buffer_copy(b'synthetic-test')
    caps = (c.c_uint32 * 1)(11)
    def connect(session, port, key, out, tls=0):
        return fn['session_connect'](session, b'127.0.0.1', port, tls, None, None, None, 0, 3000,
                                     0x1234, *key, caps, 1, None, 0, password, len(password), c.byref(out))
    def handshake(conn, key, mini):
        magic, major, minor, size = struct.unpack('<4I', exact(conn, 16))
        assert (magic, major, minor) == (0x51444552, 2, 2)
        request = exact(conn, size)
        assert struct.unpack('<IBB', request[:6]) == (0x1234, *key)
        body = struct.pack('<I', 0) + public + struct.pack('<III', 1, 0, 178) + struct.pack('<I', 11 if mini else 3)
        conn.sendall(struct.pack('<4I', magic, 2, 2, len(body)) + body)
        assert exact(conn, 4) == struct.pack('<I', 1)
        assert decrypt(exact(conn, 128)) == b'synthetic-test\0'
        conn.sendall(bytes(4))
    acked = [threading.Event(), threading.Event()]
    def full(conn, stop):
        handshake(conn, (2, 0), False)
        body = bytes([2, 0, 17, 0, 0, 0, 10, 0, 0, 0, 0x59, 2, 1, 0, 0, 0, 0x61, 0x5a, 2, 2, 0, 0, 0, 0x62, 0x63])
        conn.sendall(struct.pack('<QHII', 42, 8, len(body), 0) + body)
        assert exact(conn, 18) == struct.pack('<QHII', 1, 2, 0, 0)
        acked[0].set(); stop.wait(5)
    def mini(conn, stop):
        handshake(conn, (3, 1), True)
        conn.sendall(struct.pack('<HI', 601, 3) + b'xyz')
        assert exact(conn, 6) == struct.pack('<HI', 2, 0)
        acked[1].set(); stop.wait(5)
    retained = P()
    with peer(full) as (port0, _, _), peer(mini) as (port1, _, _):
        session = fn['session_create'](8); assert session
        token = fn['wait_create'](); assert token
        workers = []
        try:
            a, b = P(), P()
            assert connect(session, port0, (2, 0), a) == 0
            assert connect(session, port1, (3, 1), b) == 0
            duplicate = P()
            assert connect(session, port0, (2, 0), duplicate) == -40 and not duplicate.value
            for channel in (a, b): fn['channel_set_ack'](channel, 7, 1)
            req = (Requirement * 2)(Requirement(2, 0, 42), Requirement(3, 1, 1))
            thread, result = call_thread(lambda: fn['session_wait'](session, req, 2, token)); workers.append(thread)
            event = P()
            assert fn['channel_receive'](a, c.byref(retained)) == 0
            assert fn['event_kind'](retained) == 602 and fn['event_serial'](retained) == 42
            assert fn['channel_complete'](a) == 0
            assert fn['channel_receive'](b, c.byref(event)) == 0
            fn['event_destroy'](event)
            assert fn['channel_complete'](b) == 0
            assert acked[1].wait(2) and not acked[0].is_set()
            assert thread.is_alive(), 'received first LIST child must not satisfy physical serial'
            assert fn['channel_receive'](a, c.byref(event)) == 0
            fn['event_destroy'](event)
            assert fn['channel_complete'](a) == 0
            finish(thread, result, 0); assert acked[0].wait(2)
            thread, result = call_thread(lambda: fn['channel_receive'](a, c.byref(event))); workers.append(thread)
            fn['session_cancel'](session); fn['session_cancel'](session)
            thread.join(3); assert not thread.is_alive() and result[0] in (-31, -34)
        finally:
            fn['session_cancel'](session)
            for worker in workers: worker.join(3); assert not worker.is_alive()
            fn['wait_destroy'](token); fn['session_destroy'](session)
    try:
        size = Z(); data = fn['event_data'](retained, c.byref(size)); assert bytes(data[:size.value]) == b'bc'
    finally: fn['event_destroy'](retained)
    # One cancel interrupts independent in-progress TLS and Link authentication.
    link_arrived = threading.Event()
    def stalled_link(conn, stop):
        exact(conn, 16); link_arrived.set(); stop.wait(5)
    with peer(stalled_link) as (p0, _, _), peer(lambda conn, stop: stop.wait(5)) as (p1, accepted, _):
        session = fn['session_create'](8); workers = []
        try:
            for port, key, tls in [(p0, (1, 0), 0), (p1, (2, 0), 1)]:
                out = P()
                worker, result = call_thread(lambda port=port, key=key, tls=tls, out=out: connect(session, port, key, out, tls))
                workers.append((worker, result))
            assert link_arrived.wait(2) and accepted.wait(2)
            fn['session_cancel'](session)
            for worker, result in workers: finish(worker, result, -31)
        finally:
            fn['session_cancel'](session)
            for worker, _ in workers: worker.join(3); assert not worker.is_alive()
            fn['session_destroy'](session)
    # Individual cancellation is observable without terminating another wait.
    session = fn['session_create'](1); token = fn['wait_create']()
    try:
        req = (Requirement * 1)(Requirement(2, 0, 99))
        thread, result = call_thread(lambda: fn['session_wait'](session, req, 1, token))
        fn['wait_cancel'](session, token); finish(thread, result, -31)
    finally:
        fn['session_cancel'](session); thread.join(3)
        fn['wait_destroy'](token); fn['session_destroy'](session)
    # Exercise the exact protocol body limit through native transport writes.
    payload = (c.c_uint8 * (64*1024*1024+1))()
    c.memset(payload,0x5a,len(payload))
    for mini_mode in (False, True):
        done = threading.Event()
        def maximum_body(conn, stop):
            handshake(conn, (2,0), mini_mode)
            header = exact(conn,6 if mini_mode else 18)
            if mini_mode: kind,size = struct.unpack('<HI',header)
            else:
                serial,kind,size,offset = struct.unpack('<QHII',header)
                assert serial == 1 and offset == 0
            assert kind == 601 and size == 64*1024*1024
            remaining = size
            while remaining:
                chunk = exact(conn,min(65536,remaining)); assert chunk == b'Z'*len(chunk); remaining -= len(chunk)
            footer = exact(conn,6 if mini_mode else 18)
            expected = struct.pack('<HI',602,0) if mini_mode else struct.pack('<QHII',2,602,0,0)
            assert footer == expected
            done.set(); stop.wait(5)
        with peer(maximum_body) as (port,_,_):
            session = fn['session_create'](1)
            try:
                channel=P(); assert connect(session,port,(2,0),channel)==0
                assert fn['channel_send'](channel,601,payload,len(payload))==-6
                assert fn['channel_send'](channel,601,payload,len(payload)-1)==0
                assert fn['channel_send'](channel,602,None,0)==0
                assert done.wait(3)
            finally: fn['session_destroy'](session)
    del payload
    # Full native Main startup followed by Agent receive and send.
    main_done = threading.Event()
    def mini_frame(kind,body=b''): return struct.pack('<HI',kind,len(body))+body
    def read_mini(conn):
        kind,size=struct.unpack('<HI',exact(conn,6)); return kind,exact(conn,size)
    def main_peer(conn,stop):
        handshake(conn,(1,0),True)
        conn.sendall(mini_frame(103,struct.pack('<8I',0x1234,1,3,1,1,2,100,0)))
        assert read_mini(conn)==(105,struct.pack('<H',2))
        assert read_mini(conn)==(106,struct.pack('<I',8))
        assert read_mini(conn)==(104,b'')
        conn.sendall(mini_frame(3,struct.pack('<II',9,2))+mini_frame(4,struct.pack('<IQ',7,123)+b'padding')+
                     mini_frame(104,struct.pack('<I',2)+bytes([2,0,3,1])))
        assert read_mini(conn)==(1,struct.pack('<I',9))
        assert read_mini(conn)==(3,struct.pack('<IQ',7,123))
        assert read_mini(conn)==(2,b'')
        agent=struct.pack('<IIQI',1,4,123,5)+b'hello'
        conn.sendall(mini_frame(109,agent))
        assert read_mini(conn)==(108,struct.pack('<I',1))
        assert read_mini(conn)==(107,struct.pack('<IIQI',1,5,456,5)+b'world')
        main_done.set(); stop.wait(5)
    retained=P()
    with peer(main_peer) as (port,_,_):
        session=fn['session_create'](8); main_handle=None; bootstrap=P(); token=None
        try:
            connection=P(); assert connect(session,port,(1,0),connection)==0
            main_handle=fn['main_create'](connection); assert main_handle
            assert fn['main_bootstrap'](main_handle,c.byref(bootstrap))==0
            info=Info(); assert fn['main_bootstrap_info'](bootstrap,c.byref(info))==0
            assert (info.session,info.time,info.current,info.agent)==(0x1234,100,1,1)
            count=Z(); keys=fn['main_bootstrap_channels'](bootstrap,c.byref(count)); assert bytes(keys[:count.value*2])==bytes([2,0,3,1])
            assert fn['main_next'](main_handle,c.byref(retained))==1
            metadata=Metadata(); assert fn['main_event_metadata'](retained,c.byref(metadata))==0
            assert (metadata.kind,metadata.protocol,metadata.value,metadata.opaque)==(4,1,4,123)
            token=fn['agent_send_token_create'](); data=(c.c_uint8*5).from_buffer_copy(b'world')
            assert fn['agent_send'](main_handle,1,5,456,data,5,token)==1
            assert main_done.wait(2)
        finally:
            if main_handle: fn['main_cancel'](main_handle)
            if token: fn['agent_send_token_destroy'](token)
            fn['main_bootstrap_destroy'](bootstrap)
            if main_handle: fn['main_destroy'](main_handle)
            fn['session_destroy'](session)
    try:
        size=Z(); data=fn['main_event_data'](retained,c.byref(size)); assert bytes(data[:size.value])==b'hello'
    finally: fn['main_event_destroy'](retained)
    return ['multi-channel authenticated session, physical ACK and processed-serial barrier, duplicate rejection, event lifetime',
            'session-wide cancellation of simultaneous stalled TLS and Link authentication; per-wait cancellation',
            'full/mini exact 64MiB bodies over native bounded writes; oversized body has no stream effect',
            'authenticated Main bootstrap, mouse negotiation, Agent startup, padded PING, ACK, channel list, retained Agent receive and send']
