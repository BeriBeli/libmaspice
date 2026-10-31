"""Real TCP/authenticated Main+Display service acceptance, no fake draw handler."""
import base64,ctypes as c,json,struct
from pathlib import Path
from supervisor_integration import fixtures

def run(work,public,decrypt,native=False):
 Peer,Client,fn,frame,offer=fixtures(work,public,decrypt,'libdisplay-fixture.dylib','display_fixture_')
 library=c.CDLL(str(Path(work)/'libdisplay-fixture.dylib'));pixels=library.display_fixture_pixels;pixels.argtypes=[c.c_void_p,c.c_uint32,c.POINTER(c.c_uint8),c.c_size_t];pixels.restype=c.c_int
 fixture=json.loads((Path(__file__).resolve().parents[2]/'test/fixtures/SpiceCodecsTests/jpeg-8x8.json').read_text());jpeg=base64.b64decode(fixture['jpegBase64']);rgb=base64.b64decode(fixture['expectedRGBBase64']);expected=b''.join(bytes([rgb[i+2],rgb[i+1],rgb[i],255]) for i in range(0,len(rgb),3))
 if native:
  create_native=library.display_fixture_create_native;create_native.argtypes=[c.c_size_t,c.c_char_p];create_native.restype=c.c_void_p
  fn['create']=lambda capacity:create_native(capacity,str(Path(work)/'compositor.metallib').encode())
  submissions=library.display_fixture_native_submissions;submissions.argtypes=[c.c_void_p,c.c_uint32];submissions.restype=c.c_int64
  control=library.display_fixture_frame_control;control.argtypes=[c.c_void_p,c.c_uint8,c.c_uint32,c.c_uint8,c.c_uint64,c.c_uint64];control.restype=c.c_int
 key=(2,0)
 def assert_pixels(client):
  output=(c.c_uint8*256)();assert pixels(client.handle,1,output,256)==0;assert bytes(output)==expected
  if native:assert submissions(client.handle,1)>0
 def reset_clock(peer,client):
  peer.send((1,0),106,struct.pack('<I',0));peer.send((1,0),105,struct.pack('<HH',3,1));client.event(4)
 def data(peer):peer.send(key,123,struct.pack('<III',0,500,len(jpeg))+jpeg)
 checks=[]
 for seamless in (False,True):
  with Peer([key]) as source,Peer([key],target=True,seamless=seamless) as target:
   client=Client()
   try:
    assert client.connect(source)==0;client.start();client.event(1)
    assert source.message(key,101)==struct.pack('<BQBI',1,16*1024*1024,1,8*1024*1024)
    ping=struct.pack('<IQ',11,123456);source.send(key,4,ping+b'bandwidth-padding');assert source.message(key,3)==ping
    source.send(key,3,struct.pack('<II',7,1));assert source.message(key,1)==struct.pack('<I',7)
    source.send(key,314,struct.pack('<5I',1,8,8,32,0));client.event(5,1);assert source.message(key,2)==b''
    create=struct.pack('<IIBBQ4I4iB',1,0,1,1,0,8,8,8,8,0,0,8,8,0)
    source.send(key,122,create);source.message(key,2)
    source.send(key,319,struct.pack('<4I',0,77,1,10000));source.message(key,2)
    reset_clock(source,client);data(source)
    report=source.message(key,102);assert struct.unpack('<6IiI',report)[0:6]==(0,77,500,500,1,0)
    assert source.message(key,2)==b''
    # Receives and physical ACK continue while MJPEG waits for presentation.
    source.send(key,317,struct.pack('<HH7I',1,1,0,1,8,8,0,0,0));assert client.event(5,4)[4]==1;source.message(key,2)
    before=client.event(5,3);assert_pixels(client)
    if native:
     assert control(client.handle,0,1,1,1,0)==0
     assert client.event(14)[1]==5 # Full native publication, no eager CPU payload.
    source.send((1,0),116 if seamless else 101,offer(target.port,seamless));client.event(6,1);source.message((1,0),111 if seamless else 102)
    if seamless:
     for channel in [(1,0),key]:source.send(channel,1,struct.pack('<I',3));source.send(channel,2,bytes(channel)+b'display')
     for channel in [(1,0),key]:assert target.message(channel,5)==bytes(channel)+b'display'
    else:source.send((1,0),112)
    adopted=client.event(6,5);assert adopted[2]>before[2]
    # No Surface/Stream/Display-init recreation: preserved state renders again.
    reset_clock(target,client);data(target);after=client.event(5,3);assert after[2]==adopted[2] and after[4]>before[4];assert_pixels(client)
    target.send(key,315,struct.pack('<I',1));client.event(5,2)
    # Deleted stream and surface cannot accept a late old stream packet.
    data(target);client.event(3);client.event(2)
   finally:client.close()
 checks.append('real Display TCP: init, ACK, MJPEG async presentation, arrival report, owned monitors, exact JPEG pixels and Surface destruction')
 checks.append('real Display state and decoder survive semi/seamless migration; new generation frames publish without recreating stream or Surface')
 with Peer([key]) as source:
  client=Client()
  try:
   assert client.connect(source)==0;client.start();client.event(1);source.message(key,101)
   source.send(key,314,struct.pack('<5I',1,8,8,32,0));client.event(5,1)
   source.send(key,122,struct.pack('<IIBBQ4I4iB',1,0,1,1,0,8,8,8,8,0,0,8,8,0))
   source.send(key,123,struct.pack('<III',0,100000,3)+b'bad');client.event(3);client.event(2)
  finally:client.close()
 checks.append('asynchronous decoder failure terminates the supervised session and joins callbacks; child padded PING matches the common contract')
 if native:return ['native configured desktop owns Metal context after caller release; actual MJPEG GPU composition, exact pixels and native publication survive semi/seamless handoff']
 return checks+run(work,public,decrypt,True)+desktop(work,public,decrypt)+audio_channels(work,public,decrypt)+peripheral_channels(work,public,decrypt)+publication_channels(work,public,decrypt)

def desktop(work,public,decrypt):
 Peer,Client,fn,frame,offer=fixtures(work,public,decrypt,'libdisplay-fixture.dylib','display_fixture_')
 library=c.CDLL(str(Path(work)/'libdisplay-fixture.dylib'));send=library.display_fixture_input
 send.argtypes=[c.c_void_p,c.c_uint8,c.c_uint8,c.c_int32,c.c_int32];send.restype=c.c_int
 cursor_header=struct.pack('<QB4H',77,0,2,1,0,0);pixels=bytes(range(1,9))
 initial=struct.pack('<hhHHBH',10,20,2,3,1,2)+cursor_header+pixels
 cached=struct.pack('<hhBH',11,21,1,4)+cursor_header
 keys=[(2,0),(3,0),(4,0)];checks=[]
 for seamless in (False,True):
  with Peer(keys) as source,Peer(keys,target=True,seamless=seamless) as target:
   client=Client()
   try:
    assert client.connect(source)==0;client.start();client.event(1);source.message((2,0),101)
    source.send((3,0),101,struct.pack('<H',1));assert client.event(7,1)[4]==1
    source.send((3,0),102,struct.pack('<H',3));assert client.event(7,2)[4]==3
    source.send((3,0),111);client.event(7,3)
    for code,kind,expected in [(0,101,struct.pack('<I',0x4be0)),(1,102,struct.pack('<I',0xcbe0))]:
     assert send(client.handle,0,code,0x14b,0)==0;assert source.message((3,0),kind)==expected
    assert send(client.handle,0,5,1,0)==0;assert source.message((3,0),113)==b'\x01\x01\0'
    source.send((4,0),101,initial);assert client.event(8,1)[4:]==(1,pixels)
    source.send((2,0),314,struct.pack('<5I',1,8,8,32,0));client.event(5,1)
    source.send((1,0),116 if seamless else 101,offer(target.port,seamless));client.event(6,1);source.message((1,0),111 if seamless else 102)
    if seamless:
     for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,bytes(key)+b'desktop')
     for key in [(1,0),*keys]:assert target.message(key,5)==bytes(key)+b'desktop'
    else:source.send((1,0),112)
    adopted=client.event(6,5)
    # Stateful sends and cursor references use the adopted service, not a reset.
    assert send(client.handle,0,3,-2,4)==0;assert target.message((3,0),111)==struct.pack('<iiH',-2,4,1)
    assert send(client.handle,0,6,1,0)==0;assert target.message((3,0),114)==b'\x01\0\0'
    target.send((4,0),103,cached);event=client.event(8,2);assert event[2]==adopted[2] and event[4:]==(1,pixels)
    target.send((4,0),107,struct.pack('<Q',77));assert client.event(8,4)[5]==pixels
    target.send((4,0),103,cached);client.event(3);client.event(2)
   finally:client.close()
 checks.append('real Display+Inputs+Cursor semi/seamless migration preserves mouse button state and cached cursor ownership; invalid cache use terminates session')
 with Peer([(4,0)]) as source:
  client=Client()
  try:
   assert client.connect(source)==0;client.start();client.event(1)
   source.send((4,0),101,initial);client.event(8,1)
   source.send((4,0),101,struct.pack('<hhHHBH',0,0,0,0,0,1));assert client.event(8,1)[4:]==(0,b'')
   source.send((4,0),103,cached);client.event(3);client.event(2)
  finally:client.close()
 checks.append('repeated Cursor Init clears cache and state without reconnect; Inputs extended scan codes and ACK events match Swift')
 return checks

def audio_channels(work,public,decrypt):
 Peer,Client,fn,frame,offer=fixtures(work,public,decrypt,'libdisplay-fixture.dylib','display_fixture_')
 library=c.CDLL(str(Path(work)/'libdisplay-fixture.dylib'));record=library.display_fixture_record;report=library.display_fixture_playback_delay;delay=library.display_fixture_clock_delay
 record.argtypes=[c.c_void_p,c.c_uint8,c.c_bool,c.c_uint32,c.POINTER(c.c_uint8),c.c_size_t];record.restype=c.c_int
 report.argtypes=[c.c_void_p,c.c_uint8,c.c_uint32];report.restype=c.c_int;delay.argtypes=[c.c_void_p];delay.restype=c.c_int64
 keys=[(5,0),(6,0)];pcm=b'\x01\x02\x03\x04';buffer=(c.c_uint8*4).from_buffer_copy(pcm)
 for seamless in (False,True):
  with Peer(keys) as source,Peer(keys,target=True,seamless=seamless) as target:
   client=Client()
   try:
    assert client.connect(source)==0;client.start();client.event(1)
    assert report(client.handle,0,20)==-1;assert record(client.handle,0,True,10,buffer,0)==-1
    source.send((5,0),102,struct.pack('<IH',100,1));client.event(9,1)
    source.send((5,0),103,struct.pack('<IHII',2,1,48000,100));client.event(9,2)
    assert report(client.handle,0,20)==-1
    source.send((5,0),101,struct.pack('<I',120)+pcm);assert client.event(9,3)[4:]==(120,pcm)
    assert report(client.handle,0,20)==0 and delay(client.handle)==20
    source.send((6,0),101,struct.pack('<IHI',2,1,48000));client.event(10,2)
    assert record(client.handle,0,False,11,buffer,4)==-1
    assert record(client.handle,0,True,10,buffer,0)==0
    assert source.message((6,0),102)==struct.pack('<IH',10,1);assert source.message((6,0),103)==struct.pack('<I',10)
    source.send((1,0),116 if seamless else 101,offer(target.port,seamless));client.event(6,1);source.message((1,0),111 if seamless else 102)
    if seamless:
     for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,bytes(key)+b'audio')
     for key in [(1,0),*keys]:assert target.message(key,5)==bytes(key)+b'audio'
    else:source.send((1,0),112)
    client.event(6,5);assert delay(client.handle)==20
    assert record(client.handle,0,False,11,buffer,4)==0;assert target.message((6,0),101)==struct.pack('<I',11)+pcm
    target.send((5,0),101,struct.pack('<I',140)+pcm);assert client.event(9,3)[4:]==(140,pcm)
    assert report(client.handle,0,30)==0 and delay(client.handle)==30
    for key,event,vol,mute in [((5,0),9,105,106),((6,0),10,103,104)]:
     target.send(key,vol,struct.pack('<BHH',2,100,200));assert client.event(event,5)[4]==2
     target.send(key,mute,b'\1');assert client.event(event,6)[4]==1
    target.send((5,0),107,struct.pack('<I',40));assert client.event(9,7)[4]==40
    target.send((5,0),104);client.event(9,4);assert delay(client.handle)==-1
    target.send((6,0),102);client.event(10,4);assert record(client.handle,0,False,12,buffer,4)==-1
    target.send((5,0),101,struct.pack('<I',141)+pcm);client.event(3);client.event(2)
   finally:client.close()
 return ['real Playback/Record RAW S16 audio, MODE/START_MARK ordering, owned PCM events, sink-delay clock synchronization and semi/seamless state preservation; STOP clears feedback and rejects stale PCM']

def peripheral_channels(work,public,decrypt):
 Peer,Client,fn,frame,offer=fixtures(work,public,decrypt,'libdisplay-fixture.dylib','display_fixture_')
 library=c.CDLL(str(Path(work)/'libdisplay-fixture.dylib'));card=library.display_fixture_smartcard;usb=library.display_fixture_usb;web=library.display_fixture_webdav
 P=c.c_void_p;U8=c.POINTER(c.c_uint8);Z=c.c_size_t
 card.argtypes=[P,c.c_uint8,c.c_uint32,c.c_uint32,U8,Z];card.restype=c.c_int
 usb.argtypes=[P,c.c_uint8,U8,Z];usb.restype=c.c_int;web.argtypes=[P,c.c_uint8,c.c_int64,U8,Z];web.restype=c.c_int
 def buffer(data):return (c.c_uint8*len(data)).from_buffer_copy(data)
 def card_message(kind,reader,data=b''):return struct.pack('<III',kind,reader,len(data))+data
 keys=[(8,0),(9,0),(11,0)];name=b'org.spice-space.webdav.0\0';request=struct.pack('<qH',7,6)+b'GET /\n';reader_name=b'test-reader';atr=b'\x3b\0'
 for seamless in (False,True):
  with Peer(keys) as source,Peer(keys,target=True,seamless=seamless) as target:
   client=Client()
   try:
    assert client.connect(source)==0;client.start();client.event(1)
    source.send((8,0),101,card_message(1,0xffffffff,struct.pack('<III',0x44435356,2,0)));assert client.event(11,1)[4:]==(2,b'\0'*4)
    assert card(client.handle,0,3,0xffffffff,buffer(reader_name),len(reader_name))==0
    assert source.message((8,0),101)==card_message(3,0xffffffff,reader_name)
    assert card(client.handle,0,5,2,buffer(atr),len(atr))==0
    source.send((11,0),201,struct.pack('<IIB',len(name),9,1)+name);assert client.event(13,1)[4:]==(1,name[:-1])
    source.send((11,0),101,request[:5]);ping=struct.pack('<IQ',1,2);source.send((11,0),4,ping);assert source.message((11,0),3)==ping
    source.send((9,0),101,b'usb-before');assert client.event(12)[5]==b'usb-before'
    source.send((1,0),116 if seamless else 101,offer(target.port,seamless));client.event(6,1);source.message((1,0),111 if seamless else 102)
    if seamless:
     for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,bytes(key)+b'peripheral')
     for key in [(1,0),*keys]:assert target.message(key,5)==bytes(key)+b'peripheral'
    else:source.send((1,0),112)
    client.event(6,5)
    target.send((8,0),101,card_message(2,2,struct.pack('<I',0)));assert client.event(11,2)[4]==3<<32
    assert target.message((8,0),101)==card_message(5,2,atr)
    target.send((8,0),101,card_message(2,2,struct.pack('<I',0)));assert client.event(11,2)[4]==5<<32
    target.send((8,0),101,card_message(7,2,b'APDU'));assert client.event(11,3)[4:]==(2,b'APDU')
    target.send((8,0),101,card_message(8,2));assert client.event(11,4)[4]==2
    assert card(client.handle,0,9,2,buffer(b''),0)==0;assert target.message((8,0),101)==card_message(9,2)
    target.send((11,0),101,request[5:]+struct.pack('<qH',-1,0));assert client.event(13,3)[4:]==(7,b'GET /\n');assert client.event(13,4)[4]==2**64-1
    assert web(client.handle,0,7,buffer(b'OK'),2)==0;assert target.message((11,0),101)==struct.pack('<qH',7,2)+b'OK'
    target.send((11,0),202,b'\1');client.event(13,2);assert web(client.handle,0,7,buffer(b'OK'),2)==-1
    assert usb(client.handle,0,buffer(b'usb-after'),9)==0;assert target.message((9,0),101)==b'usb-after'
    target.send((9,0),102,b'unnegotiated');client.event(3);client.event(2)
   finally:client.close()
 return ['real Smartcard control queue/APDU/flush, USB VMC and fragmented WebDAV mux survive semi/seamless migration; port close and unnegotiated compression fail explicitly']

def publication_channels(work,public,decrypt):
 import time
 Peer,Client,fn,frame,offer=fixtures(work,public,decrypt,'libdisplay-fixture.dylib','display_fixture_')
 library=c.CDLL(str(Path(work)/'libdisplay-fixture.dylib'));control=library.display_fixture_frame_control;snapshots=library.display_fixture_frame_snapshots
 control.argtypes=[c.c_void_p,c.c_uint8,c.c_uint32,c.c_uint8,c.c_uint64,c.c_uint64];control.restype=c.c_int;snapshots.argtypes=[c.c_void_p,c.c_uint8];snapshots.restype=c.c_int64
 def fill(peer,color):peer.send((2,0),302,struct.pack('<I4iBBIH',1,0,0,8,8,0,1,color,8)+b'\0'*13)
 for seamless in (False,True):
  with Peer([(2,0)]) as source,Peer([(2,0)],target=True,seamless=seamless) as target:
   client=Client();pending=[]
   def expect(kind,detail=None):
    for index,event in enumerate(pending):
     if event[0]==kind and (detail is None or event[1]==detail):return pending.pop(index)
    deadline=time.monotonic()+5
    while True:
     event=client.events.get(timeout=max(.01,deadline-time.monotonic()))
     if event[0]==kind and (detail is None or event[1]==detail):return event
     assert event[0]!=3,('unexpected failure',event)
     pending.append(event);assert time.monotonic()<deadline
   def action(operation,lifecycle=1,revision=0):assert control(client.handle,0,1,operation,lifecycle,revision)==0
   try:
    assert client.connect(source)==0;client.start();expect(1);source.message((2,0),101)
    source.send((2,0),314,struct.pack('<5I',1,8,8,32,0));expect(5,1)
    fill(source,0x112233);expect(5,3);action(3);assert snapshots(client.handle,0)==0
    action(1);first=expect(14);assert first[1]==1 and first[5]==bytes([0x33,0x22,0x11,255])*64
    fill(source,0x445566);expect(5,3);action(3);assert snapshots(client.handle,0)==1
    action(2,revision=first[4]);second=expect(14);assert second[5]==bytes([0x66,0x55,0x44,255])*64
    action(0);action(3);action(1);resumed=expect(14);assert resumed[1]==1 and resumed[4]==second[4] and resumed[5]==second[5]
    source.send((1,0),116 if seamless else 101,offer(target.port,seamless));expect(6,1);source.message((1,0),111 if seamless else 102)
    if seamless:
     for key in [(1,0),(2,0)]:source.send(key,1,struct.pack('<I',3));source.send(key,2,b'publication')
     for key in [(1,0),(2,0)]:assert target.message(key,5)==b'publication'
    else:source.send((1,0),112)
    adopted=expect(6,5);rebound=expect(14);assert rebound[2]==adopted[2] and rebound[1]==1 and rebound[5]==second[5]
    action(2,revision=rebound[4]);fill(target,0x778899);latest=expect(14);assert latest[5]==bytes([0x99,0x88,0x77,255])*64
    target.send((2,0),315,struct.pack('<I',1));expect(5,2)
    target.send((2,0),314,struct.pack('<5I',1,8,8,32,0));expect(5,1);fill(target,0xabcdef);recreated=expect(14);assert recreated[1]==1 and recreated[5]==bytes([0xef,0xcd,0xab,255])*64
   finally:client.close()
 return ['real demand publication: hidden draws take no snapshots, consumer ACK gates next frame, resume redraws without mutation, immutable exact pixels and explicit demand survive migration and same-ID recreation']
