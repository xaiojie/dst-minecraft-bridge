"""Copy an inactive Minecraft save while holding its actual session lock.

Minecraft FileChannel locks use POSIX fcntl record locks on macOS/Linux. lockf
uses the same lock family (flock does not). Existing lock bytes are never changed.
"""
import argparse
import errno
import os
if os.name == 'nt':
    import msvcrt
else:
    import fcntl
import json
from pathlib import Path
import shutil
from datetime import datetime, timezone

def prepare(source, dest):
    source, dest = Path(source).resolve(), Path(dest).absolute()
    if dest.exists():
        raise FileExistsError(dest)
    if source == dest or source in dest.parents:
        raise ValueError('destination must be outside source save')
    if not (source / 'level.dat').is_file():
        raise ValueError('source is not a Minecraft save')
    # Refuse an unknown locking state instead of creating/modifying source files.
    with (source / 'session.lock').open('r+b') as lock:
        try:
            if os.name == 'nt':
                lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1)
            else:fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB, 0)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                raise RuntimeError('source save is active / locked') from error
            raise
        try:
            # Do not follow links outside the save or reproduce bridge identity.
            if any(p.is_symlink() for p in source.rglob('*')):
                raise ValueError('source save contains symlinks')
            shutil.copytree(source, dest, ignore=shutil.ignore_patterns('session.lock', 'dst-mc-bridge', 'dst-mc-copy-source.json'))
            (dest / 'dst-mc-copy-source.json').write_text(json.dumps({
                'source': str(source), 'copied_at': datetime.now(timezone.utc).isoformat(),
                'source_lock': ('Windows byte-range' if os.name=='nt' else 'POSIX record')+' lock held throughout copy',
            }, indent=2) + '\n')
        finally:
            if os.name == 'nt':
                lock.seek(0);msvcrt.locking(lock.fileno(),msvcrt.LK_UNLCK,1)
            else:fcntl.lockf(lock, fcntl.LOCK_UN)
    return dest

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--dest', required=True, type=Path)
    args = parser.parse_args()
    print(prepare(args.source, args.dest))
