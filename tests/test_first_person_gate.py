"""Task4 behavioral tests. Real graphics/input acceptance is a separate evidence gate."""
import json
import os
import shutil
import socket
import struct
import tempfile
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
import pathlib
import subprocess
import unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
NATIVE_BUILD=pathlib.Path(os.environ.get('DSTMC_TEST_NATIVE_BUILD',ROOT/'native/build'))
try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime=None

class NativeGateTests(unittest.TestCase):
    def test_lease_lifecycle(self):
        result=subprocess.run([str(NATIVE_BUILD/'lease_test')],capture_output=True,text=True,check=True)
        self.assertIn('late_camera_ack_rejected',result.stdout)
        self.assertIn('window_proof_current_identity_only',result.stdout)
    def test_real_offscreen_depth_and_state(self):
        result=subprocess.run([str(NATIVE_BUILD/'compositor_test')],capture_output=True,text=True,check=True)
        self.assertIn('transparent_pixel_preserves_host',result.stdout)
        self.assertIn('closer_surface_wins',result.stdout)

class NativeHttpTests(unittest.TestCase):
    def test_exact_frame_ack_expiry_and_malformed_http(self):
        for port in (39379,39380):
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
                try:sock.bind(('127.0.0.1',port))
                except OSError:self.skipTest('test port unavailable; confirm game exit or TCP reuse delay')
        fixture=json.loads((ROOT/'protocol/fixtures/frame-v2.json').read_text())
        key={k:fixture[k] for k in ('pair','epoch','id')}
        with tempfile.TemporaryDirectory(prefix='dstmc-http-fixture-') as temp:
            temp=pathlib.Path(temp);frame=temp/'frame.bin'
            shutil.copyfile(ROOT/'protocol/fixtures/frame-v2.bin',frame)
            status=dict(protocol=2,status='PAIRED',pair=key['pair'],epoch=key['epoch'],latest_frame=key,frame_path=str(frame),width=fixture['width'],height=fixture['height'],generation=1,dst_origin=dict(x=100,y=0,z=-50),mc_origin=dict(x=0,y=64,z=0),axes=[1,0,0,0,1,0,0,0,1])
            class Status(BaseHTTPRequestHandler):
                def do_GET(self):
                    data=json.dumps(status).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
                def log_message(self,*args):pass
            server=HTTPServer(('127.0.0.1',39379),Status)
            thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
            env=os.environ|{'DSTMC_PROBE_DIR':str(temp),'DSTMC_FIRST_PERSON':'1','DSTMC_LEASE_MS':'250','DYLD_INSERT_LIBRARIES':str(NATIVE_BUILD/'libdstmc_probe.dylib')}
            proc=subprocess.Popen([str(NATIVE_BUILD/'lease_test'),'--http-fixture'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            def post(path,body):
                data=body if isinstance(body,bytes) else json.dumps(body).encode()
                request=urllib.request.Request('http://127.0.0.1:39380'+path,data=data,headers={'Content-Type':'application/json'})
                try:response=urllib.request.urlopen(request,timeout=2)
                except urllib.error.HTTPError as error:response=error
                return response.status,json.loads(response.read())
            try:
                for _ in range(500):
                    ready=temp/'camera-gate.jsonl'
                    if ready.exists():
                        events=ready.read_text()
                        self.assertNotIn('camera_service_failed',events)
                        if 'camera_service_started' in events:break
                    if proc.poll() is not None:self.fail('HTTP fixture process exited before listening')
                    time.sleep(.01)
                else:self.fail('HTTP fixture did not become ready within 5 seconds')
                request=dict(protocol=2,pair=key['pair'],epoch=key['epoch'],key=key)
                for invalid in (b'',b'null',b'[]',b'{',b'{}'):
                    code,response=post('/v2/camera/lease',invalid);self.assertEqual(code,409);self.assertEqual(response['error'],'GATE_NOT_READY')
                complete=status.copy()
                status.update({field:None for field in ('frame_path','generation','latest_frame','width','height')})
                code,response=post('/v2/camera/lease',request);self.assertEqual(code,409)
                self.assertIsNone(proc.poll(),'PAIRED null stream must not crash native HTTP')
                status.update(complete)
                for field,value in [('width','2'),('height',True),('generation',None),('generation',1.5),('width',1921)]:
                    status[field]=value
                    code,response=post('/v2/camera/lease',request);self.assertEqual(code,409,(field,value))
                    self.assertIsNone(proc.poll())
                    status.update(complete)
                code,response=post('/v2/camera/lease',request);self.assertEqual(code,200,response);self.assertEqual(response['lease']['key'],key);self.assertEqual(response['lease']['pose']['space'],'DST')
                self.assertTrue(any(struct.unpack_from('<Q',frame.read_bytes(),4096+i*struct.unpack_from('<Q',frame.read_bytes(),32)[0]+8)[0] for i in range(3)))
                code,response=post('/v2/camera/applied',request|{'applied':True});self.assertEqual(code,200);self.assertTrue(response['accepted'])
                code,response=post('/v2/camera/applied',request|{'applied':1});self.assertEqual(code,409)
                # Publish a distinct slot while the previous exact frame is still pinned.
                # A lease must discover it even though the caller still names the old key.
                mailbox_path=pathlib.Path(response.get('mailbox',temp/'camera-mailbox'))
                for frame_id in range(43, 49):
                    data=bytearray(frame.read_bytes());stride=struct.unpack_from('<Q',data,32)[0]
                    source=next(4096+i*stride for i in range(3) if struct.unpack_from('<Q',data,4096+i*stride)[0])
                    target=next(4096+i*stride for i in range(3) if not struct.unpack_from('<Q',data,4096+i*stride+8)[0])
                    block=bytearray(data[source:source+stride]);struct.pack_into('<Q',block,8,0);struct.pack_into('<Q',block,64,frame_id);struct.pack_into('<d',block,248,float(frame_id))
                    with frame.open('r+b') as output:
                        output.seek(target);output.write(block);output.flush()
                    status['latest_frame']=dict(key,id=frame_id)
                    if frame_id>=47:
                        message={'id':str(frame_id),'path':'/v2/camera/cycle','body':request|{'applied':True}}
                        draft=mailbox_path/'test.tmp';draft.write_text(json.dumps(message));draft.replace(mailbox_path/'request.json')
                        until=time.monotonic()+1
                        while time.monotonic()<until:
                            try:answer=json.loads((mailbox_path/'response.json').read_text())
                            except (OSError,ValueError):answer={}
                            if answer.get('id')==str(frame_id):break
                            time.sleep(.005)
                        response=answer.get('value',answer);code=200 if 'value' in answer else 409
                    else:code,response=post('/v2/camera/lease',request)
                    self.assertEqual(code,200,response)
                    self.assertEqual(response['lease']['key']['id'],frame_id,'valid old lease must not bypass new frame discovery')
                    self.assertEqual(response['lease']['pose']['position']['x'],100+frame_id,'pose must advance with pixels')
                    key=dict(key,id=frame_id);request=dict(request,key=key)
                    code,response=post('/v2/camera/applied',request|{'applied':True});self.assertTrue(response['accepted'])
                time.sleep(.26)
                code,response=post('/v2/camera/applied',request|{'applied':True});self.assertEqual(code,200);self.assertFalse(response['accepted'])
                code,response=post('/v2/camera/lease',request);self.assertEqual(code,409)
                # With the expired slot released, publish a fresh fixture ID.
                data=bytearray(frame.read_bytes());stride=struct.unpack_from('<Q',data,32)[0]
                for i in range(3):
                    offset=4096+i*stride
                    self.assertEqual(struct.unpack_from('<Q',data,offset+8)[0],0)
                    if struct.unpack_from('<Q',data,offset)[0]:struct.pack_into('<Q',data,offset+64,49)
                frame.write_bytes(data);key['id']=49;status['latest_frame']=key
                code,response=post('/v2/camera/lease',request);self.assertEqual(code,200,response)
                # Discovery has resized while the old exact frame is still pinned.
                status['width']=fixture['width']+1
                code,response=post('/v2/camera/lease',request);self.assertEqual(code,409,'resize must invalidate a pinned lease')
                code,response=post('/v2/camera/applied',request|{'applied':True});self.assertFalse(response['accepted'])
                self.assertIsNone(proc.poll())
            finally:
                _,stderr=proc.communicate('stop\n' if proc.poll() is None else None,timeout=3)
                if proc.returncode:self.fail('native HTTP fixture exited: '+stderr[-2500:])
                server.shutdown();server.server_close();thread.join(timeout=1)

class WindowActivationTests(unittest.TestCase):
    def test_session_and_dispatch_deadline(self):
        java_home=pathlib.Path('/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home')
        source=ROOT/'mc/src/client/java/dev/jay/dstmc/client/WindowActivation.java'
        harness="""
package dev.jay.dstmc.client;
public class WindowActivationCheck {
    public static void main(String[] args) {
        WindowActivation proof = new WindowActivation();
        Object first = new Object(), second = new Object();
        proof.session(first);
        var stale = proof.dispatch(1_000_000_000L);
        proof.session(second);
        boolean oldAccepted = proof.accept(stale, 1_010_000_000L);
        var late = proof.dispatch(2_000_000_000L);
        boolean lateAccepted = proof.accept(late, 2_201_000_000L);
        if (oldAccepted || lateAccepted)
            throw new AssertionError("old_response_after_repair="+oldAccepted+", completed_response_after_deadline="+lateAccepted);
        var current = proof.dispatch(3_000_000_000L);
        if (!proof.accept(current, 3_100_000_000L) || !proof.active(second, 3_199_000_000L))
            throw new AssertionError("current response must activate");
        if (proof.active(second, 3_200_000_000L) || proof.active(first, 3_110_000_000L))
            throw new AssertionError("proof must expire at dispatch deadline and reject changed session before next tick");
        proof.session(first);
        if (proof.active(first, 3_110_000_000L)) throw new AssertionError("session change must clear cached proof");
        System.out.println("PASS old_response_after_repair completed_response_after_deadline current_response_activates");
    }
}
"""
        with tempfile.TemporaryDirectory(prefix='dstmc-window-policy-') as temp:
            check=pathlib.Path(temp)/'WindowActivationCheck.java';check.write_text(harness)
            subprocess.run([str(java_home/'bin/javac'),'-d',temp,str(source),str(check)],check=True,capture_output=True,text=True)
            result=subprocess.run([str(java_home/'bin/java'),'-cp',temp,'dev.jay.dstmc.client.WindowActivationCheck'],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)

@unittest.skipUnless(LuaRuntime,'Lua behavioral checks require lupa (isolated test environment)')
class LuaCameraTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            clock=0; calls={}; updates=0
            function GetTimeRealSeconds() return clock end
            TheSim={}
            for _,name in ipairs({'SetCameraPos','SetCameraDir','SetCameraUp','SetCameraFOV'}) do
                TheSim[name]=function(self,...) table.insert(calls,{name,...}) end
            end
            TheCamera={Update=function() updates=updates+1 end}
        ''')
        self.camera=self.lua.execute((ROOT/'dst-mod/scripts/dstmc/camera.lua').read_text())
        self.lua.globals().camera=self.camera
        self.lua.execute('''
            lease={key={id=3},pose={space='DST',position={x=1,y=2,z=3},forward={x=0,y=0,z=-1},up={x=0,y=1,z=0},projection={1,0,0,0,0,1,0,0,0,0,-1,-1,0,0,-2,0}}}
            camera.Install(function() end)
        ''')
    def test_pose_applies_on_camera_thread_and_expires_on_real_clock(self):
        self.lua.execute('assert(camera.ApplyLease(lease));assert(#calls==0);TheCamera:Update(0);assert(#calls==4);assert(calls[1][2]==1);clock=1.01;TheCamera:Update(0);assert(#calls==4);assert(updates==2);assert(camera.Key()==nil)')
    def test_avatar_render_alpha_restored_without_entity_visibility_changes(self):
        self.lua.execute("""
            color={.2,.4,.6,.75};visibility_changes=0
            ThePlayer={IsValid=function()return true end,AnimState={}}
            ThePlayer.AnimState.GetMultColour=function()return table.unpack(color)end
            ThePlayer.AnimState.SetMultColour=function(self,r,g,b,a)color={r,g,b,a}end
            ThePlayer.Hide=function()visibility_changes=visibility_changes+1 end
            assert(camera.ApplyLease(lease));TheCamera:Update(0)
            assert(color[4]==0,'leased first-person avatar must be invisible')
            camera.Release();assert(color[4]==.75);assert(color[1]==.2);assert(visibility_changes==0)
            assert(camera.ApplyLease(lease));TheCamera:Update(0);clock=1.01;TheCamera:Update(0);assert(color[4]==.75)
        """)

    def test_release_cannot_restore_from_old_pose(self):
        self.lua.execute('assert(camera.ApplyLease(lease));camera.Release();TheCamera:Update(0);assert(#calls==0);assert(camera.Key()==nil)')
    def test_rejects_invalid_projection(self):
        self.lua.execute('lease.pose.projection[6]=0;assert(not camera.ApplyLease(lease));TheCamera:Update(0);assert(#calls==0)')
    def test_mod_exports_respect_strict_globals(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            GLOBAL=_G
            ThePlayer={DoTaskInTime=function(self,delay,callback)callback()end,ListenForEvent=function()end}
            function AddPrefabPostInit(name,callback)end
            function AddPrefabPostInitAny(callback)end
            function AddPlayerPostInit(callback)callback(ThePlayer)end
            function GetModConfigData(name)return false end
            package.preload['dstmc/world']=function()return {LocalWorld=function()return {}end}end
            package.preload['dstmc/connection']=function()return {Start=function()end,Release=function()end}end
            package.preload['dstmc/camera']=function()return {Calibrate=function()return true end}end
            print=function()end
            setmetatable(_G,{__newindex=function(table,key,value)error('assign to undeclared variable '..key)end})
        """)
        lua.execute((ROOT/'dst-mod/modmain.lua').read_text())
        lua.execute("assert(type(DSTMCFirstPersonCalibrate)=='function');assert(DSTMCFirstPersonCalibrate())")

    def test_all_adapter_sources_parse(self):
        for path in (ROOT/'dst-mod').rglob('*.lua'):
            self.lua.execute('assert(load(...))',path.read_text())

@unittest.skipUnless(LuaRuntime,'Lua behavioral checks require lupa')
class LuaConnectionTests(unittest.TestCase):
    def async_fixture(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
          clock=100;requests={};applied=0;print=function()end
          function GetTimeRealSeconds()return clock end
          package.preload['json']=function()return {encode=function(v)return setmetatable(v,{__concat=function()return 'log'end})end,decode=function(v)return v end}end
          package.preload['dstmc/mailbox']=function()return {Close=function()end,Active=function()return false end,Poll=function()end}end
          package.preload['dstmc/gameplay']=function()return {Release=function()end,Bind=function()end,Update=function()end,Owner=function()end,Sample=function()return {results={}},{ }end,Accept=function()return true end}end
          package.preload['dstmc/world']=function()return {LocalWorld=function()return {world_uuid='world',shard='Master'}end,Origin=function()return {x=0,y=0,z=0}end}end
          package.preload['components/dstmcidentity']=function()return {NewUUID=function()return 'epoch'end}end
          package.preload['dstmc/camera']=function()return {Install=function()end,Release=function()end,Key=function()return nil end,ApplyLease=function()applied=applied+1;return true end}end
          TheSim={QueryServer=function(self,url,cb,method,body)table.insert(requests,{url=url,cb=cb,body=body})end}
          function last(fragment)for i=#requests,1,-1 do if requests[i].url:find(fragment,1,true)then return requests[i]end end end
          function pairup()
            connection.Start(true);connection.Update()
            last('/v2/status').cb({protocol=2,mc_world='mc'},true,200)
            local r=last('/v2/handshake');pair=r.body.pair;r.cb({epoch='epoch',pair=pair},true,200)
          end
        """)
        lua.globals().connection=lua.execute((ROOT/'dst-mod/scripts/dstmc/connection.lua').read_text())
        return lua

    def test_camera_clock_is_independent_and_late_lease_is_discarded(self):
        self.async_fixture().execute("""
          pairup();clock=100.1;connection.Update()
          local status=last('/v2/status');local key={pair=pair,epoch='epoch',id=1}
          status.cb({epoch='epoch',latest_frame=key},true,200)
          local old=last('/v2/camera/lease');local n=#requests
          clock=100.2;connection.Update();assert(#requests==n,'initial camera dispatch must start its own timeout')
          -- Keep the gameplay peer alive; only the camera operation expires.
          last('/v2/exchange').cb({},true,200);clock=102.2;connection.Update()
          local renewed=last('/v2/camera/lease');assert(renewed~=old or last('/v2/status')~=status)
          old.cb({lease={key=key}},true,200);assert(applied==0,'timed-out lease cannot move the camera')
        """)

    def test_old_handshake_callback_cannot_clear_new_pending(self):
        self.async_fixture().execute("""
          connection.Start(true);connection.Update();local old=last('/v2/status')
          connection.Release();connection.Start(true);clock=101;connection.Update()
          local current=last('/v2/status');assert(current~=old)
          old.cb(nil,false,0);local n=#requests;clock=102;connection.Update()
          assert(#requests==n,'old generation must not clear a new handshake guard')
        """)

    def test_camera_activity_cannot_postpone_stuck_exchange(self):
        self.async_fixture().execute("""
          pairup();clock=100.1;connection.Update();local exchange=last('/v2/exchange')
          for i=1,7 do
            local r=last('/v2/status');r.cb({epoch='epoch'},true,200)
            clock=100.1+i*.5;connection.Update()
          end
          assert(last('/v2/exchange')==exchange,'stuck exchange must not dispatch concurrent exchange')
          assert(last('/v2/status').body==nil)
          local n=#requests;clock=105;connection.Update()
          -- The latest status now belongs to handshake and may establish a new epoch.
          last('/v2/status').cb({protocol=2,mc_world='mc'},true,200)
          assert(last('/v2/handshake').body.epoch=='epoch')
          assert(#requests>n,'stuck exchange must be timed out despite camera traffic')
        """)
    def test_late_callback_does_not_reacquire_camera(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            clock=1;requests={};applied=0;released=0;print=function()end
            function GetTimeRealSeconds() return clock end
            package.preload['json']=function() return {encode=function(v)return setmetatable(v,{__concat=function()return "log"end}) end,decode=function(v)return v end} end
            package.preload['dstmc/mailbox']=function()return {Close=function()end,Active=function()return false end,Poll=function()end}end
            package.preload['dstmc/gameplay']=function()return {Release=function()end,Bind=function()end,Update=function()end,Owner=function()end,Sample=function()return {results={}},{ }end,Accept=function()return true end}end
            package.preload['dstmc/world']=function() return {LocalWorld=function()return {world_uuid='world',shard='Master'}end,Origin=function()return {x=0,y=0,z=0}end} end
            package.preload['components/dstmcidentity']=function()return {NewUUID=function()return 'epoch'end}end
            package.preload['dstmc/camera']=function()return {Install=function()end,Release=function()released=released+1 end,Key=function()return nil end,ApplyLease=function()applied=applied+1;return true end}end
            TheSim={QueryServer=function(self,url,cb,method,body)table.insert(requests,{url=url,cb=cb,body=body})end}
        """)
        connection=lua.execute((ROOT/'dst-mod/scripts/dstmc/connection.lua').read_text())
        lua.globals().connection=connection
        lua.execute("""
            connection.Start(true);connection.Update();assert(#requests==1)
            requests[1].cb({protocol=2,fixture=false,mc_world='mc'},true,200);assert(#requests==2)
            pair=requests[2].body.pair
            requests[2].cb({epoch='epoch',pair=pair},true,200)
            connection.Update();assert(#requests==3)
            key={pair=pair,epoch='epoch',id=4}
            requests[3].cb({epoch='epoch',latest_frame=key},true,200);assert(#requests==4)
            connection.Update();assert(#requests==4) -- one camera request in flight
            connection.Release()
            requests[4].cb({lease={key=key}},true,200)
            clock=3;connection.Update();assert(applied==0);assert(#requests==4)
        """)

    def test_empty_stream_and_epoch_change_reconnect_instead_of_dying(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute("""
            clock=1;requests={};print=function()end
            function GetTimeRealSeconds() return clock end
            package.preload['json']=function() return {encode=function(v)return setmetatable(v,{__concat=function()return "log"end}) end,decode=function(v)return v end} end
            package.preload['dstmc/mailbox']=function()return {Close=function()end,Active=function()return false end,Poll=function()end}end
            package.preload['dstmc/gameplay']=function()return {Release=function()end,Bind=function()end,Update=function()end,Owner=function()end,Sample=function()return {results={}},{ }end,Accept=function()return true end}end
            package.preload['dstmc/world']=function() return {LocalWorld=function()return {world_uuid='world',shard='Master'}end,Origin=function()return {x=0,y=0,z=0}end} end
            package.preload['components/dstmcidentity']=function()return {NewUUID=function()return 'epoch'end}end
            package.preload['dstmc/camera']=function()return {Install=function()end,Release=function()end,Key=function()return nil end,ApplyLease=function()return true end}end
            TheSim={QueryServer=function(self,url,cb,method,body)table.insert(requests,{url=url,cb=cb,body=body})end}
            function last_request_matching(fragment,from)
                from=from or 1
                for i=#requests,from,-1 do if requests[i].url:find(fragment,1,true) then return i end end
                return nil
            end
        """)
        connection=lua.execute((ROOT/'dst-mod/scripts/dstmc/connection.lua').read_text())
        lua.globals().connection=connection
        lua.execute("""
            connection.Start(true);connection.Update();assert(#requests==1)
            requests[1].cb({protocol=2,fixture=false,mc_world='mc'},true,200)
            pair=requests[2].body.pair
            requests[2].cb({epoch='epoch',pair=pair},true,200)
            -- PAIRED but the stream is briefly empty: keep the pairing, retry, never disable.
            connection.Update()
            local camera_status=last_request_matching('/v2/status')
            assert(camera_status~=nil and camera_status>1)
            requests[camera_status].cb({epoch='epoch',latest_frame=nil},true,200)
            clock=2;local before=#requests;connection.Update()
            assert(last_request_matching('/v2/status',before+1),'must retry the camera status')
            assert(not last_request_matching('/v2/handshake',before+1),'must not re-pair for an empty stream')
            requests[last_request_matching('/v2/exchange')].cb({protocol=2},true,200)
            -- A rotated epoch must re-handshake instead of disabling the bridge.
            requests[last_request_matching('/v2/status',before+1)].cb({epoch='other',latest_frame=nil},true,200)
            clock=6;before=#requests;connection.Update()
            assert(last_request_matching('/v2/status',before+1),'must ask for a new handshake')
            assert(not last_request_matching('/v2/camera/lease',before+1),'must not lease while unpaired')
        """)

if __name__=='__main__':unittest.main()
