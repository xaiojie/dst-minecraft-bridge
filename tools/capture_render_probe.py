#!/usr/bin/env python3
"""Request two bounded frames from the loaded extension, retaining raw GL evidence."""
import argparse, hashlib, json, math, os, pathlib, shutil, struct, sys, time, zlib

def png(path,width,height,rgba):
 def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
 rows=b''.join(b'\0'+rgba[y*width*4:(y+1)*width*4] for y in range(height-1,-1,-1))
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))
def summarize_capture(meta_path):
 meta=json.loads(meta_path.read_text());p=meta['probe'];w,h=p['viewport'][2:];base=meta_path.parent
 if not (0<w<=1920 and 0<h<=1080):raise ValueError('unsupported viewport')
 color=(base/meta['color']).read_bytes();depth=(base/meta['depth']).read_bytes()
 if len(color)!=w*h*4:raise ValueError(meta.get('error') or 'incomplete color capture')
 png(meta_path.with_suffix('.png'),w,h,color)
 result={'metadata':meta_path.name,'frame_no':p['frame_no'],'draw_no':p['draw_no'],'stage':p['stage'],'viewport':p['viewport'],'target_id':p['target_id'],'program':p['program'],'error':meta.get('error'),'color_sha256':hashlib.sha256(color).hexdigest(),'depth_sha256':hashlib.sha256(depth).hexdigest()}
 if depth:
  if len(depth)!=w*h*4:raise ValueError('incomplete depth capture')
  values=struct.unpack('<'+'f'*(w*h),depth);finite=sorted(x for x in values if math.isfinite(x));result['depth_stats']={'finite':len(finite),'total':w*h,'min':finite[0] if finite else None,'max':finite[-1] if finite else None,'below_clear_one':sum(x<.999999 for x in finite),'distinct_values':len(set(finite))}
  view=bytearray()
  for x in values:
   level=round(max(0,min(1,x))*255) if math.isfinite(x) else 0;view.extend((level,level,level,255))
  png(meta_path.with_name(meta_path.stem+'-depth.png'),w,h,view)
 return result

def checkpoint_request(value):
 values=[int(x) for x in value.split(',')]
 if not 1<=len(values)<=7 or len(set(values))!=len(values) or any(x<1 or x>20000 for x in values):raise ValueError('checkpoints require 1 to 7 unique draws in 1..20000')
 return 'checkpoints '+' '.join(str(x) for x in values)+'\n'
def write_batch(source,name,metas,draws):
 if not name or pathlib.Path(name).name!=name or name in ('.','..'):raise ValueError('batch must be one directory name')
 destination=source/name;destination.mkdir(exist_ok=False)
 for meta in metas:
  data=json.loads(meta.read_text())
  for path in [meta,source/data['color'],source/data['depth'],meta.with_suffix('.png'),meta.with_name(meta.stem+'-depth.png')]:
   if path.exists():shutil.copy2(path,destination/path.name)
 for name in ('preflight.json','loaded.json'):
  if (source/name).exists():shutil.copy2(source/name,destination/name)
 (destination/'draws.jsonl').write_text(''.join(json.dumps(d)+'\n' for d in draws))
 return destination

def main():
 p=argparse.ArgumentParser();p.add_argument('--seconds',type=float,default=10);p.add_argument('--metadata-only',action='store_true',help='record all draw metadata and only two before-present images');p.add_argument('--draws',help='1 to 7 comma-separated draw endpoints from a prior sample');p.add_argument('--batch',help='new evidence subdirectory; never overwritten');p.add_argument('--out',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[1]/'evidence/render-probe');a=p.parse_args();out=a.out.resolve()
 try:
  loaded=json.loads((out/'loaded.json').read_text());pid=loaded['pid'];os.kill(pid,0)
 except (OSError,ValueError,KeyError):print(json.dumps({'error':'extension_not_running','out':str(out)}));return 1
 if not 0<a.seconds<=60:print(json.dumps({'error':'seconds_must_be_in_0_60'}));return 1
 # Reject stale PID reuse / stalled presentation; process existence alone is insufficient.
 heartbeat=out/'heartbeat.json'
 try:
  beat=json.loads(heartbeat.read_text());assert beat['pid']==pid and time.time()-heartbeat.stat().st_mtime<5
 except (OSError,ValueError,KeyError,AssertionError):print(json.dumps({'error':'no_fresh_present_heartbeat'}));return 1
 try:
  if a.metadata_only and a.draws:raise ValueError('metadata-only and draws are mutually exclusive')
  request='metadata\n' if a.metadata_only else checkpoint_request(a.draws) if a.draws else 'default\n'
  if a.batch and (pathlib.Path(a.batch).name!=a.batch or a.batch in ('.','..') or (out/a.batch).exists()):raise ValueError('batch must be a new directory name')
 except ValueError as error:print(json.dumps({'error':str(error)}));return 1
 start=time.time();(out/'capture.request').write_text(request);time.sleep(a.seconds)
 captures=[];errors=[];metas=[]
 for path in sorted(out.glob('ctx*-f*-d*.json')):
  if path.stat().st_mtime<start:continue
  metas.append(path)
  try:captures.append(summarize_capture(path))
  except (OSError,ValueError,KeyError) as error:errors.append({'file':path.name,'error':str(error)})
 frames={(x['frame_no']) for x in captures};draws=[]
 if (out/'draws.jsonl').exists():
  for line in (out/'draws.jsonl').read_text().splitlines():
   try:d=json.loads(line)
   except ValueError:continue
   if d['frame_no'] in frames:draws.append(d)
 groups={}
 for d in draws:
  key=(d['context_id'],d['program'],d['target_id'],d['depth_enabled'],d['depth_mask'])
  g=groups.setdefault(key,{'context_id':key[0],'program':key[1],'target_id':key[2],'depth_enabled':key[3],'depth_mask':key[4],'draw_count':0,'uniform_names':set(),'classification':'unverified','first_draw':d['draw_no'],'last_draw':d['draw_no']});g['draw_count']+=1;g['last_draw']=d['draw_no'];g['uniform_names'].update(m['name'] for m in d['shader_matrices']);g['program_fingerprint']=d.get('program_fingerprint','');g['shader_sources']=d.get('shader_sources',[]);g['classification_evidence']='Observed target/depth state and draw range only; scene/UI requires matching captured images. Source discard token is not proof that its branch executed.';g['sample_matrices']=d['shader_matrices'];g['stage']=d['stage']
 preflight=json.loads((out/'preflight.json').read_text()) if (out/'preflight.json').exists() else {}
 destination=write_batch(out,a.batch,metas,draws) if a.batch else out
 identification={'schema':1,'executable_sha256':preflight.get('executable',{}).get('sha256'),'extension_sha256':preflight.get('extension',{}).get('sha256'),'runtime_pid':pid,'accepted':False,'reason':'Manual ground/tree/creature/UI and alpha-edge review required; depth statistics alone are insufficient.','groups':[{**g,'uniform_names':sorted(g['uniform_names'])} for g in groups.values()]}
 (destination/'identification.json').write_text(json.dumps(identification,indent=2));summary={'schema':1,'requested_at':start,'seconds':a.seconds,'pid':pid,'draw_count':len(draws),'capture_count':len(captures),'captures':captures,'errors':errors,'requested_draws':a.draws,'runtime_acceptance':'pending_manual_scene_and_alpha_review'};(destination/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps({'capture_count':len(captures),'draw_count':len(draws),'errors':errors,'out':str(destination)}));return 0 if captures and draws and not errors else 1
if __name__=='__main__':sys.exit(main())
