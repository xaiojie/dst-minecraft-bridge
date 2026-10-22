#!/usr/bin/env python3
"""Build a reviewable development bundle from an explicit source/binary allowlist."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[1]
def package(root,output):
    root=Path(root).resolve();output=Path(output)
    files={}
    patterns=('dst-mod/**/*.lua','mc/src/**/*.java','mc/src/**/*.json','native/src/*.mm','native/src/*.cpp','native/include/*.h','native/tests/*','tools/*.py','tools/*.command','tests/*.py','protocol/*.md','protocol/*.json','protocol/fixtures/*','mc/gradle/wrapper/*')
    for pattern in patterns:
        for p in root.glob(pattern):
            if p.is_file() and not p.is_symlink():files[p.relative_to(root).as_posix()]=p
    for name in ('README.md','THIRD-PARTY-NOTICES.md','docs/development-2026-10-23.md','docs/HANDOFF.md','docs/steam-start.md','native/Makefile','mc/build.gradle','mc/settings.gradle','mc/gradle.properties','mc/gradlew'):
        p=root/name
        if p.is_file() and not p.is_symlink():files[name]=p
    lib=root/'native/build/libdstmc_probe.dylib';jars=[p for p in (root/'mc/build/libs').glob('*.jar') if not p.is_symlink() and not any(x in p.name for x in ('sources','dev'))]
    if not lib.is_file() or lib.is_symlink() or len(jars)!=1:raise ValueError('build exactly one remapped Fabric jar and native library first')
    files['native/build/libdstmc_probe.dylib']=lib;files['mc/build/libs/'+jars[0].name]=jars[0]
    manifest={'kind':'development-build','live_acceptance':'NOT_VERIFIED','files':[]}
    for name,p in sorted(files.items()):
        manifest['files'].append({'path':name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
    output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(output,'x',zipfile.ZIP_DEFLATED)as archive:
        for item in manifest['files']:archive.write(files[item['path']],item['path'])
        archive.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    # Read the produced archive, rather than trusting only the staging list.
    with zipfile.ZipFile(output)as archive:
        if archive.testzip() is not None:raise ValueError('corrupt archive')
        for entry in manifest['files']:
            if hashlib.sha256(archive.read(entry['path'])).hexdigest()!=entry['sha256']:raise ValueError('artifact checksum mismatch')
    return manifest

def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);args=p.parse_args()
    report=package(ROOT,args.out);print(json.dumps({'archive':str(args.out.resolve()),'files':len(report['files']),'live_acceptance':report['live_acceptance']},indent=2))
if __name__=='__main__':main()
