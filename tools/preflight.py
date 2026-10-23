#!/usr/bin/env python3
"""Read-only, narrowly scoped DST launch checks. No account config or save content is read."""
import argparse, contextlib, hashlib, json, os, pathlib, plistlib, re, socket, subprocess, sys, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
if __package__:
 from . import platform_support as host
else:
 import platform_support as host
DEFAULT_CLUSTER=pathlib.Path.home()/'Documents/Klei/DoNotStarveTogether/434082735/Cluster_1'

def read_keyvalues(path):
 """Read the quoted KeyValues subset written by Steam, without shell parsing."""
 text=path.read_text(encoding='utf-8-sig');tokens=[];pos=0
 pattern=re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')
 while pos<len(text):
  match=pattern.match(text,pos)
  if not match:raise ValueError('invalid_steam_metadata')
  token=match.group();pos=match.end()
  if not token.isspace() and not token.startswith('//'):tokens.append(token)
 cursor=0
 def string():
  nonlocal cursor
  if cursor>=len(tokens) or not tokens[cursor].startswith('"'):raise ValueError('invalid_steam_metadata')
  value=re.sub(r'\\(["\\])',r'\1',tokens[cursor][1:-1]);cursor+=1;return value
 def object(nested=False):
  nonlocal cursor
  result={}
  while cursor<len(tokens):
   if tokens[cursor]=='}':
    if not nested:raise ValueError('invalid_steam_metadata')
    cursor+=1;return result
   key=string()
   if key in result or cursor>=len(tokens):raise ValueError('invalid_steam_metadata')
   if tokens[cursor]=='{':cursor+=1;result[key]=object(True)
   else:result[key]=string()
  if nested:raise ValueError('invalid_steam_metadata')
  return result
 return object()

def resolve_dst_executable(steam_root=None,platform=None):
 """Only accept the installed app registered for 322330 in Steam's active catalog."""
 platform=platform or host.platform_name()
 root=pathlib.Path(steam_root) if steam_root is not None else host.steam_root(platform)
 try:
  libraries=read_keyvalues(root/'steamapps/libraryfolders.vdf').get('libraryfolders')
  if not isinstance(libraries,dict):raise ValueError('invalid_steam_metadata')
  found=set()
  for library in libraries.values():
   if not isinstance(library,dict):continue
   apps=library.get('apps',{})
   if not isinstance(apps,dict):raise ValueError('invalid_steam_metadata')
   if '322330' not in apps:continue
   base=pathlib.Path(library.get('path',''))
   if not base.is_absolute():raise ValueError('invalid_steam_library')
   manifest=read_keyvalues(base/'steamapps/appmanifest_322330.acf').get('AppState',{})
   if not isinstance(manifest,dict):raise ValueError('invalid_dst_manifest')
   name=manifest.get('installdir','')
   if manifest.get('appid')!='322330' or not name or name in ('.','..') or '/' in name or '\\' in name:raise ValueError('invalid_dst_manifest')
   installation=base/'steamapps/common'/name
   exe=(installation/'bin64/dontstarve_steam_x64.exe' if platform=='windows' else installation/'dontstarve_steam.app/Contents/MacOS/dontstarve_steam')
   if exe.is_file():found.add(exe.resolve())
 except OSError as error:raise ValueError('steam_install_metadata_unavailable') from error
 if not found:raise ValueError('dst_install_not_found')
 if len(found)!=1:raise ValueError('ambiguous_dst_installs')
 return found.pop()
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
 p=argparse.ArgumentParser();p.add_argument('--json',action='store_true');p.add_argument('--executable',type=pathlib.Path);p.add_argument('--cluster',type=pathlib.Path,default=DEFAULT_CLUSTER);p.add_argument('--launch',action='store_true');p.add_argument('--dry-run',action='store_true');p.add_argument('--out',type=pathlib.Path,default=ROOT/'evidence/render-probe');a=p.parse_args()
 # Actual starts belong to Steam or the user; --dry-run remains diagnostic only.
 if a.launch and not a.dry_run:
  print(json.dumps({'error':'STEAM_START_REQUIRED','message':'Start DST through Steam, or ask the user to start it. Direct executable launch is disabled.'}));return 2
 try:executable=a.executable or resolve_dst_executable()
 except ValueError as error:print(json.dumps({'ready':False,'blockers':[str(error)]}));return 1
 result=preflight(executable,a.cluster);exe=result['executable']['path'];out=a.out.resolve();environment={'DYLD_INSERT_LIBRARIES':result['extension']['path'],'DSTMC_PROBE_DIR':str(out)};cwd=str(pathlib.Path(exe).parent.parent/'data')
 if a.dry_run:print(json.dumps({'executable':exe,'working_directory':cwd,'environment':environment,'preflight':result},indent=2));return 0 if result['ready'] else 1
 print(json.dumps(result,indent=2));return 0 if result['ready'] else 1
if __name__=='__main__':sys.exit(main())
