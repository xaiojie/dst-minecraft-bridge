import importlib.util, json, os, pathlib, struct, subprocess, sys, tempfile, unittest
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('preflight',ROOT/'tools/preflight.py')
preflight=importlib.util.module_from_spec(spec);spec.loader.exec_module(preflight)
capture_spec=importlib.util.spec_from_file_location('capture',ROOT/'tools/capture_render_probe.py')
capture=importlib.util.module_from_spec(capture_spec);capture_spec.loader.exec_module(capture)
class ToolsTest(unittest.TestCase):
 def test_request_remains_old_until_complete_publication(self):
  # A renderer may read at any write boundary. It must see old or complete-new,
  # never a public partial request. The adapter still writes real files.
  with tempfile.TemporaryDirectory() as d:
   directory=pathlib.Path(d);public=directory/'capture.request'
   public.write_text('default\n');observed=[];real_open=pathlib.Path.open
   class ObservedWriter:
    def __init__(self, stream):self.stream=stream
    def __enter__(self):return self
    def __exit__(self,*args):return self.stream.__exit__(*args)
    def write(self,text):
     split=len(text)//2
     self.stream.write(text[:split]);self.stream.flush()
     observed.append(public.read_text() if public.exists() else None)
     self.stream.write(text[split:]);self.stream.flush()
     observed.append(public.read_text() if public.exists() else None)
     return len(text)
   def observed_open(path,*args,**kwargs):
    stream=real_open(path,*args,**kwargs)
    mode=args[0] if args else kwargs.get('mode','r')
    return ObservedWriter(stream) if 'w' in mode else stream
   request='checkpoints 3 5\n'
   with patch.object(pathlib.Path,'open',observed_open):capture.publish_request(directory,request)
   self.assertEqual(public.read_text(),request)
   self.assertTrue(observed);self.assertEqual(observed,['default\n','default\n'])
   self.assertEqual({p.name for p in directory.iterdir()},{'capture.request'})

 def test_failed_request_write_preserves_public_request(self):
  with tempfile.TemporaryDirectory() as d:
   directory=pathlib.Path(d);public=directory/'capture.request'
   public.write_text('metadata\n');real_open=pathlib.Path.open
   class FailingWriter:
    def __init__(self,stream):self.stream=stream
    def __enter__(self):return self
    def __exit__(self,*args):return self.stream.__exit__(*args)
    def write(self,text):
     self.stream.write(text[:3]);self.stream.flush()
     raise OSError('injected write failure')
   def failing_open(path,*args,**kwargs):
    stream=real_open(path,*args,**kwargs)
    mode=args[0] if args else kwargs.get('mode','r')
    return FailingWriter(stream) if 'w' in mode else stream
   with patch.object(pathlib.Path,'open',failing_open):
    with self.assertRaisesRegex(OSError,'injected write failure'):capture.publish_request(directory,'checkpoints 3 5\n')
   self.assertEqual(public.read_text(),'metadata\n')
   self.assertEqual({p.name for p in directory.iterdir()},{'capture.request'})

 def test_draw_selection_keeps_captured_context_and_frame(self):
  with tempfile.TemporaryDirectory() as d:
   directory=pathlib.Path(d);meta=directory/'ctx2-f7-d1.json'
   (directory/'color.rgba').write_bytes(bytes([1,2,3,255]));(directory/'depth.f32').write_bytes(struct.pack('<f',.5))
   meta.write_text(json.dumps({'probe':{'context_id':2,'frame_no':7,'draw_no':1,'stage':'before-present','viewport':[0,0,1,1],'target_id':0,'program':0},'color':'color.rgba','depth':'depth.f32','error':''}))
   rows=[{'context_id':1,'frame_no':7,'draw_no':1},{'context_id':2,'frame_no':7,'draw_no':1},{'context_id':2,'frame_no':8,'draw_no':1}]
   log=directory/'draws.jsonl';log.write_text(''.join(json.dumps(row)+'\n' for row in rows))
   selected=capture.select_draws(log,[capture.summarize_capture(meta)])
   self.assertEqual(selected,[{'context_id':2,'frame_no':7,'draw_no':1}])

 def test_checkpoint_request_is_bounded(self):
  self.assertEqual(capture.checkpoint_request('109,117,134,260'),'checkpoints 109 117 134 260\n')
  for invalid in ('0','1,1','1,2,3,4,5,6,7,8','20001','x'):
   with self.assertRaises(ValueError):capture.checkpoint_request(invalid)
 def test_batch_preserves_previous_evidence_and_refuses_overwrite(self):
  with tempfile.TemporaryDirectory() as d:
   source=pathlib.Path(d);meta=source/'ctx1-f3-d2.json';meta.write_text(json.dumps({'color':'a.rgba','depth':'a.f32'}));(source/'a.rgba').write_bytes(b'color');(source/'a.f32').write_bytes(b'depth');(source/'summary.json').write_text('prior-summary')
   destination=capture.write_batch(source,'late-scene',[meta],[{'frame_no':3}])
   self.assertTrue((source/'late-scene'/'a.rgba').exists());self.assertEqual((destination/'a.f32').read_bytes(),b'depth');self.assertEqual((source/'summary.json').read_text(),'prior-summary')
   with self.assertRaises(FileExistsError):capture.write_batch(source,'late-scene',[meta],[])

 def test_capture_preserves_explicit_unsupported_target_reason(self):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d);meta=root/'capture.json';(root/'color.rgba').write_bytes(b'');(root/'depth.f32').write_bytes(b'')
   meta.write_text(json.dumps({'probe':{'viewport':[0,0,2,2]},'color':'color.rgba','depth':'depth.f32','error':'disabled_read_buffer'}))
   with self.assertRaisesRegex(ValueError,'disabled_read_buffer'):capture.summarize_capture(meta)

 def test_launcher_supplies_hint_and_cleans_owned_file_on_child_failure(self):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d)
   child="import pathlib,sys; assert pathlib.Path('steam_appid.txt').read_text().strip()=='322330'; sys.exit(17)"
   self.assertEqual(preflight.run_game([sys.executable,'-c',child],root,os.environ.copy(),root/'log'),17)
   self.assertFalse((root/'steam_appid.txt').exists())
 def test_launcher_preserves_existing_matching_hint(self):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d);hint=root/'steam_appid.txt';hint.write_text('322330');before=hint.stat()
   self.assertEqual(preflight.run_game([sys.executable,'-c','raise SystemExit(17)'],root,os.environ.copy(),root/'log'),17)
   self.assertEqual(hint.read_text(),'322330');self.assertEqual(hint.stat().st_ino,before.st_ino);self.assertEqual(hint.stat().st_mtime_ns,before.st_mtime_ns)
 def test_launcher_rejects_wrong_existing_hint_before_child(self):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d);hint=root/'steam_appid.txt';hint.write_text('999')
   with self.assertRaisesRegex(ValueError,'steam_appid_mismatch'):
    preflight.run_game([sys.executable,'-c',"open('child-ran','w').close()"],root,os.environ.copy(),root/'log')
   self.assertEqual(hint.read_text(),'999');self.assertFalse((root/'child-ran').exists())
 def test_launcher_keeps_hint_if_child_changed_it(self):
  with tempfile.TemporaryDirectory() as d:
   root=pathlib.Path(d)
   child="import pathlib; pathlib.Path('steam_appid.txt').write_text('changed'); raise SystemExit(17)"
   self.assertEqual(preflight.run_game([sys.executable,'-c',child],root,os.environ.copy(),root/'log'),17)
   self.assertEqual((root/'steam_appid.txt').read_text(),'changed')
 def test_preflight_missing_executable_blocks_launch(self):
  result=subprocess.run([sys.executable,str(ROOT/'tools/preflight.py'),'--json','--executable','/nonexistent/dstmc-test'],capture_output=True,text=True)
  self.assertNotEqual(result.returncode,0)
  data=json.loads(result.stdout);self.assertIn('executable',data);self.assertFalse(data['executable']['exists']);self.assertFalse(data['ready']);self.assertIn('missing_executable',data['blockers'])
 def test_capture_refuses_stale_or_absent_extension(self):
  with tempfile.TemporaryDirectory() as d:
   pathlib.Path(d,'loaded.json').write_text('{"pid":99999999}')
   result=subprocess.run([sys.executable,str(ROOT/'tools/capture_render_probe.py'),'--seconds','0.1','--out',d],capture_output=True,text=True)
   self.assertNotEqual(result.returncode,0);self.assertIn('extension_not_running',result.stdout);self.assertFalse(pathlib.Path(d,'capture.request').exists())
 def test_launcher_dry_run_is_scoped_and_writes_no_evidence(self):
  with tempfile.TemporaryDirectory() as d:
   result=subprocess.run([str(ROOT/'tools/launch_dst.command'),'--dry-run','--executable',str(ROOT/'native/build/loader_test'),'--out',d],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr+result.stdout);data=json.loads(result.stdout)
   self.assertEqual(data['environment']['DYLD_INSERT_LIBRARIES'],str(ROOT/'native/build/libdstmc_probe.dylib'))
   self.assertEqual(data['working_directory'],str(pathlib.Path(data['executable']).parent.parent/'data'));self.assertEqual(list(pathlib.Path(d).iterdir()),[])
if __name__=='__main__': unittest.main()
