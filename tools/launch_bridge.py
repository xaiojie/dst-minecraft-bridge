#!/usr/bin/env python3
"""Preflight or launch the copied development MC save; DST only goes through Steam."""
import argparse
import json
import os
import socket
from pathlib import Path
import subprocess
import sys
if __package__:
    from . import platform_support as host
else:
    import platform_support as host
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument('--start',action='store_true');p.add_argument('--save',default='DST-MC-FirstPerson-Test');p.add_argument('--assets',type=Path,default=host.default_assets());args=p.parse_args()
    if Path(args.save).name!=args.save or args.save in ('.','..','DST-MC-Test'):raise SystemExit('Use an independent prepared test save name')
    save=ROOT/'mc/run/saves'/args.save;library=host.native_library(ROOT);blockers=[]
    if not (save/'dst-mc-copy-source.json').is_file():blockers.append('Prepare a copy with tools/prepare_test_copy.py first')
    if not library.is_file():blockers.append('Build the native library first')
    if not args.assets.is_dir():blockers.append('Supply the installed Minecraft assets directory with --assets')
    for port in (39379,39380):
        with socket.socket()as s:
            try:s.bind(('127.0.0.1',port))
            except OSError:blockers.append(f'Port {port} is already in use; close the existing bridge session')
    try:java=host.find_java()
    except ValueError as error:java=Path('java');blockers.append(str(error))
    if host.platform_name()=='unsupported':blockers.append('Unsupported runtime platform')
    command=host.gradle_command(ROOT,java,['runClient','-PtestSave='+args.save,'-PfirstPerson=true','-PminecraftAssets='+str(args.assets.resolve())])
    print(json.dumps({'blockers':blockers,'mc_command':command,'steam_launch_option':host.steam_option(ROOT),'live_acceptance':'NOT_VERIFIED'},ensure_ascii=True,indent=2))
    if blockers:return 1
    if not args.start:return 0
    # No Steam settings or save creation are automated. User installs the shown
    # per-game launch option and matching mod, then invokes --start explicitly.
    if host.platform_name()=='windows':os.startfile('steam://rungameid/322330')
    else:subprocess.run(['/usr/bin/open','steam://rungameid/322330'],check=True)
    return subprocess.run(command,cwd=ROOT/'mc',env=dict(os.environ,JAVA_HOME=str(java.parent.parent))).returncode
if __name__=='__main__':raise SystemExit(main())
