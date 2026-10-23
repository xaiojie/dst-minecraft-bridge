"""Preview or reversibly install the matching Lua mod; never opens or edits saves."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import uuid
if __package__:
    from . import preflight,platform_support as host
else:
    import preflight,platform_support as host
ROOT=Path(__file__).resolve().parents[1]


def plan(source,destination):
    source=Path(source).resolve();destination=Path(destination).absolute()
    if not (source/'modinfo.lua').is_file()or not (source/'modmain.lua').is_file():raise ValueError('invalid source mod')
    if source==destination or source in destination.parents:raise ValueError('destination is inside source')
    if destination.is_symlink()or (destination.exists()and not destination.is_dir()):raise ValueError('unsafe destination')
    files=[]
    for path in sorted(source.rglob('*')):
        if path.is_symlink():raise ValueError('source contains a symlink')
        if path.is_file():files.append({'path':path.relative_to(source).as_posix(),'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    return {'source':str(source),'destination':str(destination),'files':files,'live_acceptance':'NOT_VERIFIED'}


def apply(value):
    # Revalidate just before mutation so a stale dry plan cannot deploy changed files.
    if plan(value['source'],value['destination'])!=value:raise ValueError('deployment source changed')
    destination=Path(value['destination']);parent=destination.parent
    parent.mkdir(parents=True,exist_ok=True)
    identifier=uuid.uuid4().hex;stage=parent/('.dstmc-stage-'+identifier)
    receipt_dir=parent/'.dstmc-backups'/identifier;backup=receipt_dir/'original';moved=False;installed=False
    try:
        shutil.copytree(value['source'],stage)
        receipt_dir.mkdir(parents=True,exist_ok=False)
        if destination.exists():destination.replace(backup);moved=True
        stage.replace(destination);installed=True
        receipt=dict(value,backup=str(backup)if moved else None,receipt_dir=str(receipt_dir))
        (receipt_dir/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        return receipt
    except BaseException:
        if installed:shutil.rmtree(destination)
        if moved:backup.replace(destination)
        raise
    finally:
        if stage.exists():shutil.rmtree(stage)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--apply',action='store_true');args=parser.parse_args()
    if host.platform_name()=='windows':
        if __package__:from .windows_steam import running_processes
        else:from windows_steam import running_processes
        executable=preflight.resolve_dst_executable(platform='windows');installation=executable.parents[1]
        processes=running_processes(executable)
    else:
        executable=preflight.resolve_dst_executable();installation=executable.parents[3]
        processes=preflight.processes(executable)
    value=plan(ROOT/'dst-mod',installation/'mods/dst_mc_first_person')
    if args.apply:
        if processes is None or processes:raise SystemExit('Close DST before installing; process state must be known')
        value=apply(value)
    print(json.dumps(value,ensure_ascii=True,indent=2))
    return 0
if __name__=='__main__':raise SystemExit(main())
