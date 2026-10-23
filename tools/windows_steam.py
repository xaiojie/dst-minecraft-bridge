"""Steam %command% wrapper for the Windows x64 build, with durable diagnostics."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
if __package__:
    from . import platform_support as host,preflight
    from .windows_loader import inject_library
else:
    import platform_support as host,preflight
    from windows_loader import inject_library
ROOT=Path(__file__).resolve().parents[1]


def running_processes(executable):
    if os.name!='nt':return None
    # The path travels through an environment value, never PowerShell source.
    script="@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -eq $env:DSTMC_CHECK_EXE} | Select-Object -ExpandProperty ProcessId) | ConvertTo-Json -Compress"
    try:
        result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',script],
            env=dict(os.environ,DSTMC_CHECK_EXE=str(executable)),capture_output=True,text=True,timeout=15)
        if result.returncode:return None
        value=json.loads(result.stdout)if result.stdout.strip()else[]
        if isinstance(value,int):return [value]
        if isinstance(value,list)and all(isinstance(item,int)for item in value):return value
    except (OSError,ValueError,subprocess.TimeoutExpired):pass
    return None


def inspect(executable,library):
    blockers=[];entries=[]
    for path,dll in ((executable,False),(library,True)):
        record={'path':str(path),'exists':path.is_file()}
        try:
            record.update(host.pe_info(path))
            if record['architecture']!='x86_64' or record['is_dll']!=dll:blockers.append('unsupported_'+('extension'if dll else'executable'))
            record['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
        except (OSError,ValueError):blockers.append('invalid_'+('extension'if dll else'executable'))
        entries.append(record)
    pids=running_processes(executable)
    if pids is None:blockers.append('process_status_unknown')
    elif pids:blockers.append('dst_already_running')
    return {'schema':1,'platform':'windows','ready':not blockers,'blockers':blockers,
            'executable':entries[0],'extension':entries[1],'process_ids':pids,'live_acceptance':'NOT_VERIFIED'}


def write_json(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')


def main(argv=None,*,environment=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run',action='store_true');parser.add_argument('executable',nargs='?');parser.add_argument('game_args',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv);environment=dict(os.environ if environment is None else environment)
    def emit(value):print(json.dumps(value,ensure_ascii=True,indent=2))
    if not args.dry_run and not host.steam_authorized(environment):
        emit({'blockers':['Steam must supply matching SteamAppId/SteamGameId=322330']});return 2
    try:executable=preflight.resolve_dst_executable(platform='windows')
    except ValueError as error:emit({'blockers':[str(error)]});return 1
    if args.executable is not None and Path(args.executable).resolve()!=executable:
        emit({'blockers':['noncanonical_executable']});return 2
    if args.executable is None and not args.dry_run:emit({'blockers':['Steam must supply %command%']});return 2
    library=host.native_library(ROOT,'windows').resolve();result=inspect(executable,library)
    command=[str(executable),*args.game_args]
    if args.dry_run:emit(dict(result,dry_run=True,command=command));return 0 if result['ready']else 1
    if not result['ready']:emit(result);return 1
    launches=ROOT/'evidence/steam-launches';launches.mkdir(parents=True,exist_ok=True)
    directory=Path(tempfile.mkdtemp(prefix='windows-',dir=launches));process=None;loaded=False;code=1;error=None
    write_json(directory/'preflight.json',result)
    write_json(directory/'request.json',{'timestamp':datetime.now(timezone.utc).isoformat(),'command':command,
        'module':result['extension'],'output_dir':str(directory),
        'steam_app_id_marker':{key:environment[key]for key in ('SteamAppId','SteamGameId')if key in environment}})
    try:
        with (directory/'game.log').open('ab')as log:
            process=subprocess.Popen(command,cwd=executable.parent,env=dict(environment,DSTMC_PROBE_DIR=str(directory),DSTMC_FIRST_PERSON='1'),
                stdin=subprocess.DEVNULL,stdout=log,stderr=log)
            inject_library(process.pid,library)
            deadline=time.monotonic()+15
            while time.monotonic()<deadline and process.poll()is None:
                try:
                    marker=json.loads((directory/'loaded.json').read_text(encoding='utf-8'))
                    if marker.get('pid')==process.pid and marker.get('architecture')=='x86_64':loaded=True;break
                except (OSError,ValueError):pass
                time.sleep(.05)
            if not loaded:raise RuntimeError('native startup marker absent or mismatched; inspect camera-gate.jsonl')
            code=process.wait()
    except (OSError,RuntimeError,subprocess.TimeoutExpired)as failure:
        error=type(failure).__name__+': '+str(failure)
        if process is not None and process.poll()is None:
            process.terminate()
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait()
    finally:
        write_json(directory/'completion.json',{'returncode':code,'native_loaded':loaded,'error':error,'live_acceptance':'NOT_VERIFIED'})
    emit({'output_dir':str(directory),'returncode':code,'native_loaded':loaded,'live_acceptance':'NOT_VERIFIED'})
    return code
