"""Live tests: require the newly launched, dedicated DST-MC-Frame-Fixture client.
No disk fallback. Every sample is selected by an HTTP FrameKey and read under a
native slot lease. A fixture-only scene change proves pixels came from this run.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import unittest
import urllib.request
import uuid
import zlib

ROOT=Path(__file__).resolve().parents[1]

def request(path, data=None):
    body=None if data is None else json.dumps(data).encode()
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:39379'+path,body,{'Content-Type':'application/json'}),timeout=8) as r:return json.load(r)

def png(path,w,h,rgba):
    def chunk(k,v):return struct.pack('>I',len(v))+k+v+struct.pack('>I',zlib.crc32(k+v)&0xffffffff)
    rows=b''.join(b'\0'+rgba[y*w*4:(y+1)*w*4] for y in range(h-1,-1,-1))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))

class LiveFrames(unittest.TestCase):
    def test_fresh_game_frames(self):
        try:status=request('/v2/status')
        except Exception as e:self.fail('new live MC v2 server unavailable: '+str(e))
        self.assertTrue(status['fixture'], 'refuse to bind the final intended save to a mock DST world')
        self.assertEqual(int(os.environ['DSTMC_EXPECT_PID']),status['pid'],'wrong game process')
        self.assertGreaterEqual(status['started_at_ms'],int(os.environ['DSTMC_LAUNCH_AFTER_MS']))
        os.kill(status['pid'],0)
        from jsonschema import Draft202012Validator
        schema=json.loads((ROOT/'protocol/http-v2.schema.json').read_text())
        validator=Draft202012Validator({'$ref':'#/$defs/StatusResponse', '$defs':schema['$defs']})
        validator.validate(status)
        pair={'dst_world':'15fdff60-cf13-4198-bc7e-d7bb9ed3af77','dst_shard':'surface','mc_world':status['mc_world'],'mc_dimension':'dst_mc_bridge:stage','region':'ground'}
        response=request('/v2/handshake',{'protocol':2,'pair':pair,'epoch':str(uuid.uuid4()),'dst_origin':{'x':10,'y':0,'z':20},'mc_origin':{'x':0,'y':64,'z':0}})
        self.assertEqual(pair,response['pair'])
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            status=request('/v2/status')
            if status.get('latest_frame'):break
            time.sleep(.2)
        self.assertIsNotNone(status.get('latest_frame'),'no complete world+HUD frame')
        validator.validate(status)
        self.assertEqual(pair,status['latest_frame']['pair'])
        self.assertEqual(response['epoch'],status['latest_frame']['epoch'])
        evidence=ROOT/'evidence'/('task3-live-'+status['run_id']);evidence.mkdir(parents=True,exist_ok=True)
        helper=evidence/'read-frame'
        # Real native reader used from test utility, with exact key and RAII lease.
        source=evidence/'read-frame.cpp'
        source.write_text(r'''
#include "frame_protocol.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <fstream>
#include <iostream>
#include <string>
int main(int n,char** a){if(n!=6)return 2;int fd=open(a[1],O_RDWR);struct stat st{};if(fd<0||fstat(fd,&st))return 3;void* m=mmap(nullptr,st.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);dstmc::FrameKey k{};
for(int i=0;i<32;i++)k.pair_hash[i]=std::stoi(std::string(a[2]+i*2,2),nullptr,16);
for(int i=0;i<16;i++)k.epoch[i]=std::stoi(std::string(a[3]+i*2,2),nullptr,16);k.id=std::stoull(a[4]);
{auto frame=dstmc::read_frame(m,st.st_size,k);if(!frame)return 4;std::cout<<frame->pose.position.x<<" "<<frame->pose.position.y<<" "<<frame->pose.position.z<<" "<<frame->pose.forward.x<<" "<<frame->pose.forward.y<<" "<<frame->pose.forward.z;
std::ofstream out(a[5],std::ios::binary);uint32_t w=frame->width,h=frame->height;out.write((char*)&w,4);out.write((char*)&h,4);out.write((char*)frame->color,w*h*4);out.write((char*)frame->depth,w*h*4);out.write((char*)frame->hud,w*h*4);}munmap(m,st.st_size);close(fd);}
''')
        subprocess.run(['clang++','-arch','x86_64','-std=c++17','-O2','-I'+str(ROOT/'native/include'),str(source),'-o',str(helper)],check=True)
        canonical=json.dumps(pair,separators=(',',':'))
        pairhash=hashlib.sha256(canonical.encode()).hexdigest()
        def sample(name):
            for _ in range(50):
                s=request('/v2/status');validator.validate(s);key=s.get('latest_frame')
                if key:
                    out=evidence/(name+'.raw')
                    result=subprocess.run([str(helper),s['frame_path'],pairhash,key['epoch'].replace('-',''),str(key['id']),str(out)],capture_output=True,text=True)
                    if result.returncode==0:
                        b=out.read_bytes();w,h=struct.unpack_from('<II',b);size=w*h*4
                        color=b[8:8+size];depth=struct.unpack('<'+'f'*(w*h),b[8+size:8+2*size]);hud=b[8+2*size:]
                        png(evidence/(name+'-world.png'),w,h,color);png(evidence/(name+'-hud.png'),w,h,hud)
                        pose=list(map(float,result.stdout.split()));(evidence/(name+'-pose.json')).write_text(json.dumps({'position':pose[:3],'forward':pose[3:]}))
                        for actual,expected in zip(pose[:3],[.5,65.62,.5]):self.assertAlmostEqual(actual,expected,delta=.1,msg='fixture camera moved unexpectedly')
                        self.assertLess(pose[4],-.1);self.assertGreater(pose[5],.9)
                        return s,w,h,color,depth,hud
                time.sleep(.02)
            self.fail('could not lease a current exact frame')
        request('/test/scene',{'stone':True})
        time.sleep(2)
        s,w,h,color,depth,hud=sample('stone')
        self.assertLessEqual(w,1920);self.assertLessEqual(h,1080)
        opaque=sum(a>240 for a in color[3::4]);clear=sum(a==0 for a in color[3::4])
        self.assertGreater(opaque,500,'no real block pixels');self.assertGreater(clear,w*h*.5,'background not transparent')
        self.assertTrue(all(color[i]==color[i+1]==color[i+2]==0 for i in range(0,len(color),4) if color[i+3]==0),'transparent background RGB dirty')
        self.assertGreater(sum(0<d<.99999 for d in depth),500,'world depth lost before capture')
        greys={tuple(color[i:i+3]) for i in range(0,len(color),4) if color[i+3]>240}
        self.assertGreater(len(greys),16,'missing actual stone texture variation')
        self.assertGreater(sum(a>0 for a in hud[3::4]),100,'hand/HUD absent')
        # Break: a straight-alpha layer leaks RGB brighter than its alpha into DST.
        for layer in (color,hud):
            self.assertTrue(all(max(layer[i:i+3])<=layer[i+3]+1 for i in range(0,len(layer),4)),
                            'layer is not premultiplied RGBA')
        request('/test/scene',{'stone':False});time.sleep(2)
        empty=sample('removed-stone');self.assertGreater(empty[0]['latest_frame']['id'],s['latest_frame']['id'])
        self.assertLess(sum(a>240 for a in empty[3][3::4]),opaque*.25,'removing actual stone did not remove pixels')
        request('/test/scene',{'stone':True})
        samples=[];start=time.monotonic();lastid=empty[0]['latest_frame']['id']
        while time.monotonic()-start<60:
            state=request('/v2/status');validator.validate(state)
            self.assertEqual(status['run_id'],state['run_id']);self.assertEqual(status['pid'],state['pid'])
            samples.append({'elapsed':time.monotonic()-start,'frame':state['latest_frame']['id'],'heartbeat':state['heartbeat'],'width':state['width'],'height':state['height']})
            time.sleep(.5)
        fps=(samples[-1]['frame']-samples[0]['frame'])/(samples[-1]['elapsed']-samples[0]['elapsed'])
        self.assertGreater(samples[-1]['frame'],lastid+100,'no continuous new frames')
        (evidence/'result.json').write_text(json.dumps({'status':s,'opaque_pixels':opaque,'clear_pixels':clear,'texture_colors':len(greys),'fps':fps,'samples':samples},indent=2))
        print('LIVE EVIDENCE',evidence,'FPS',fps,flush=True)
