#!/usr/bin/env python3
"""Read-only, narrowly scoped DST launch checks. No account config or save content is read."""
import argparse, contextlib, hashlib, json, os, pathlib, plistlib, socket, subprocess, sys, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEFAULT_EXE=pathlib.Path.home()/"Library/Application Support/Steam/steamapps/common/Don't Starve Together/dontstarve_steam.app/Contents/MacOS/dontstarve_steam"
DEFAULT_CLUSTER=pathlib.Path.home()/'Documents/Klei/DoNotStarveTogether/434082735/Cluster_1'
def command(args):
 p=subprocess.run(args,capture_output=True,text=True);return p.returncode,p.stdout,p.stderr
def sha256(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
def processes(executable):
 code,out,_=command(['/bin/ps','-axo','pid=,comm='])
 if code:return None
 result=[]
 for line in out.splitlines():
  fields=line.strip().split(None,1)
  if len(fields)==2 and fields[1]==str(executable):result.append(int(fields[0]))
 return result
def preflight(executable,cluster):
 executable=pathlib.Path(executable).resolve();library=ROOT/'native/build/libdstmc_probe.dylib';exists=executable.is_file();blockers=[]
 e={'path':str(executable),'exists':exists,'executable_permission':os.access(executable,os.X_OK)}
 entitlements={}
 if exists:
  e['sha256']=sha256(executable);e['architecture']=command(['/usr/bin/lipo','-archs',str(executable)])[1].strip()
  _,out,err=command(['/usr/bin/codesign','-d','--entitlements',':-',str(executable)])
  for raw in (out,err):
   start=raw.find('<?xml');end=raw.find('</plist>')
   if start>=0 and end>=start:
    try:entitlements=plistlib.loads(raw[start:end+8].encode())
    except (ValueError,plistlib.InvalidFileException):pass
  if 'x86_64' not in e['architecture']:blockers.append('unsupported_architecture')
  if not e['executable_permission']:blockers.append('not_executable')
 else:blockers.append('missing_executable')
 pids=processes(executable)
 if pids is None:blockers.append('process_status_unknown')
 elif pids:blockers.append('dst_already_running')
 ports={}
 for port in (39379,39380):
  with socket.socket() as s:
   try:s.bind(('127.0.0.1',port));ports[str(port)]='available'
   except OSError:ports[str(port)]='in_use_protocol_not_inferred'
 # Task 2 opens no HTTP listener; port occupancy is evidence, not a launch blocker.
 locks=sorted(str(p.relative_to(cluster)) for p in cluster.rglob('*') if p.is_file() and (p.name.endswith('.lock') or p.name.lower()=='lock')) if cluster.is_dir() else []
 lib={'path':str(library),'exists':library.is_file()}
 if library.is_file():lib['sha256']=sha256(library);lib['architecture']=command(['/usr/bin/lipo','-archs',str(library)])[1].strip()
 else:blockers.append('missing_extension')
 return {'schema':1,'timestamp':time.time(),'ready':not blockers,'blockers':blockers,'executable':e,'extension':lib,'permissions':{'allow_dyld_environment_variables':entitlements.get('com.apple.security.cs.allow-dyld-environment-variables'),'disable_library_validation':entitlements.get('com.apple.security.cs.disable-library-validation')},'process_ids':pids,'ports':ports,'save_lock':{'cluster':str(cluster),'status':'unknown','matching_lock_filenames':locks,'note':'No reliable engine save-lock API; absent lock files do not establish unlocked status.'}}
@contextlib.contextmanager
def steam_app_id_hint(cwd):
 """Steamworks debugger hint; ownership checked before cleanup, never overwritten."""
 path=pathlib.Path(cwd)/'steam_appid.txt';owned=None;content=b'322330\n'
 try:
  fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 except FileExistsError:
  if path.read_text().strip()!='322330':raise ValueError('steam_appid_mismatch')
 else:
  owned=os.fstat(fd)
  with os.fdopen(fd,'wb') as stream:stream.write(content)
 try:yield
 finally:
  if owned is not None:
   try:
    current=path.lstat()
    if (current.st_dev,current.st_ino)==(owned.st_dev,owned.st_ino) and path.read_bytes()==content:path.unlink()
   except FileNotFoundError:pass

def run_game(argv,cwd,environment,log_path):
 with steam_app_id_hint(cwd):
  with open(log_path,'ab') as log:return subprocess.run(argv,cwd=cwd,env=environment,stdout=log,stderr=log).returncode

def main():
 p=argparse.ArgumentParser();p.add_argument('--json',action='store_true');p.add_argument('--executable',type=pathlib.Path,default=DEFAULT_EXE);p.add_argument('--cluster',type=pathlib.Path,default=DEFAULT_CLUSTER);p.add_argument('--launch',action='store_true');p.add_argument('--dry-run',action='store_true');p.add_argument('--out',type=pathlib.Path,default=ROOT/'evidence/render-probe');a=p.parse_args()
 # Actual starts belong to Steam or the user; --dry-run remains diagnostic only.
 if a.launch and not a.dry_run:
  print(json.dumps({'error':'STEAM_START_REQUIRED','message':'Start DST through Steam, or ask the user to start it. Direct executable launch is disabled.'}));return 2
 result=preflight(a.executable,a.cluster);exe=result['executable']['path'];out=a.out.resolve();environment={'DYLD_INSERT_LIBRARIES':result['extension']['path'],'DSTMC_PROBE_DIR':str(out)};cwd=str(pathlib.Path(exe).parent.parent/'data')
 if a.dry_run:print(json.dumps({'executable':exe,'working_directory':cwd,'environment':environment,'preflight':result},indent=2));return 0 if result['ready'] else 1
 print(json.dumps(result,indent=2));return 0 if result['ready'] else 1
if __name__=='__main__':sys.exit(main())
