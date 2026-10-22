#!/usr/bin/env python3
"""Build and run offline contracts, saving raw outputs and explicit live exclusions."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
MODULES=['tests.test_axis_contract','tests.test_test_copy','tests.test_steam_dst','tests.test_first_person_gate','tests.test_handshake_contract','tests.test_gameplay','tests.test_delivery','tests.test_live_frames.LiveSampleEvaluation']
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);args=p.parse_args()
    # These tests own the bridge ports and rebuild the native image. Refuse a live session.
    for port in (39379,39380):
        with socket.socket()as s:
            try:s.bind(('127.0.0.1',port))
            except OSError:raise SystemExit(f'Port {port} is occupied; close the test games before building')
    processes=subprocess.run(['/bin/ps','-axo','command='],capture_output=True,text=True,check=True).stdout
    if any(('dontstarve_steam.app/Contents/MacOS/' in line or 'net.minecraft.client.main.Main' in line or 'net.fabricmc.devlaunchinjector.Main' in line) for line in processes.splitlines()):
        raise SystemExit('A game process is running; close it before rebuilding')
    environment=dict(os.environ)
    if not environment.get('JAVA_HOME'):
        environment['JAVA_HOME']=subprocess.run(['/usr/libexec/java_home','-v','21'],capture_output=True,text=True,check=True).stdout.strip()
    args.out.mkdir(parents=True,exist_ok=False)
    commands=[('java',[str(ROOT/'mc/gradlew'),'-p',str(ROOT/'mc'),'clean','check','build','--console','plain']),('native',['make','-C','native','all','contract-test','gl-test','lease-test','reader-test','loader-test','http-framing-test','transform-status-test','pipeline-test']),('python',[sys.executable,'-m','unittest',*MODULES,'-v'])]
    report={'kind':'offline-development-validation','created_at':datetime.now(timezone.utc).isoformat(),'live_acceptance':'NOT_VERIFIED','excluded':['tests.test_live_frames.LiveFrames','both-game visual/input/gameplay/save/performance acceptance'],'checks':[]}
    for name,command in commands:
        print('Running '+name+' checks',flush=True)
        with (args.out/(name+'.log')).open('w')as log:
            result=subprocess.run(command,cwd=ROOT,env=environment,stdout=log,stderr=subprocess.STDOUT)
        report['checks'].append({'name':name,'result':'PASS' if result.returncode==0 else 'FAIL','exit_code':result.returncode,'log':name+'.log'})
        (args.out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        if result.returncode:print('See '+str(args.out/(name+'.log')));return result.returncode
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
