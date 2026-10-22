#!/usr/bin/env python3
"""Steam Launch Options wrapper; never invokes the DST executable directly."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if __package__:
    from . import preflight
else:
    import preflight

ROOT = Path(__file__).resolve().parents[1]
APP_ID = '322330'


def steam_marker(environment):
    marker = {key: environment[key] for key in ('SteamAppId', 'SteamGameId')
              if key in environment}
    if not marker:
        return marker, ['steam_app_id_missing']
    if any(value != APP_ID for value in marker.values()):
        return {}, ['steam_app_id_mismatch_or_conflict']
    return marker, []


def library_list(environment, library):
    libraries = []
    for value in (environment.get('STEAM_DYLD_INSERT_LIBRARIES', ''),
                  environment.get('DYLD_INSERT_LIBRARIES', ''), str(library)):
        for path in value.split(':'):
            if path and path not in libraries:
                libraries.append(path)
    return ':'.join(libraries)


def open_argv(app, game_args, library, output_dir, environment):
    return ['/usr/bin/open', '--env',
            'DYLD_INSERT_LIBRARIES=' + library_list(environment, library),
            '--env', 'DSTMC_PROBE_DIR=' + str(output_dir),
            '--env', 'DSTMC_FIRST_PERSON=1', '-n', '-W', str(app),
            '--args', *game_args]


def emit(value):
    print(json.dumps(value, indent=2))


def main(argv=None, *, environment=None):
    parser = argparse.ArgumentParser(
        description='Invoked by Steam as "ABSOLUTE_WRAPPER_PATH" %command%. '
                    'A Steam app ID marker is an operational guard, not authentication.',
        epilog='Wrapper flags precede APP. Everything after APP is passed unchanged '
               'as game arguments. Dry-run never writes evidence or launches anything.')
    parser.add_argument('--dry-run', action='store_true', help='read-only launch diagnostics')
    parser.add_argument('app', nargs='?', metavar='APP', help='canonical DST .app supplied by Steam')
    parser.add_argument('game_args', nargs=argparse.REMAINDER, metavar='GAME_ARG')
    args = parser.parse_args(argv)
    environment = dict(os.environ if environment is None else environment)
    marker, blockers = steam_marker(environment)
    executable = preflight.DEFAULT_EXE.resolve()
    app = executable.parents[2]
    if args.app is None and not args.dry_run:
        emit({'blockers': ['missing_app'], 'message': 'Steam must supply the canonical APP via %command%.'})
        return 2
    if args.app is not None and Path(args.app).resolve() != app:
        emit({'blockers': ['noncanonical_app'], 'message': 'Only the canonical DST .app is accepted.'})
        return 2
    if blockers and not args.dry_run:
        emit({'blockers': blockers, 'message': 'Actual starts require SteamAppId or SteamGameId=322330; '
              'all supplied IDs must agree. Start through Steam.'})
        return 2

    result = preflight.preflight(executable, preflight.DEFAULT_CLUSTER)
    blockers.extend(result['blockers'])
    if not result['ready'] and not result['blockers']:
        blockers.append('preflight_not_ready')
    library = Path(result['extension']['path']).resolve()
    if 'x86_64' not in result['extension'].get('architecture', '').split():
        blockers.append('extension_requires_x86_64')
    for permission in ('allow_dyld_environment_variables', 'disable_library_validation'):
        if result['permissions'].get(permission) is not True:
            blockers.append('required_entitlement_' + permission)
    blockers = list(dict.fromkeys(blockers))
    if args.dry_run:
        planned_dir = ROOT / 'evidence/steam-launches/<unique-per-launch>'
        emit({'dry_run': True, 'blockers': blockers,
              'open_argv': open_argv(app, args.game_args, library, planned_dir, environment),
              'message': 'Read-only plan. Actual module loading and live callbacks remain unverified.'})
        return 1 if blockers else 0
    if blockers:
        emit({'blockers': blockers})
        return 1

    launches = ROOT / 'evidence/steam-launches'
    launches.mkdir(parents=True, exist_ok=True)
    output_dir = Path(tempfile.mkdtemp(prefix=f'{os.getpid()}-', dir=launches))
    command = open_argv(app, args.game_args, library, output_dir, environment)
    request = {'timestamp': datetime.now(timezone.utc).isoformat(), 'pid': os.getpid(),
               'app': str(app), 'executable': str(executable),
               'module': {'path': str(library), 'sha256': result['extension']['sha256']},
               'output_dir': str(output_dir), 'steam_app_id_marker': marker,
               'open_argv': command}
    (output_dir / 'request.json').write_text(json.dumps(request, indent=2) + '\n')
    (output_dir / 'preflight.json').write_text(json.dumps(result, indent=2) + '\n')
    # Only the target app receives DYLD settings, via open's per-app --env options.
    open_environment = {key: value for key, value in environment.items()
                        if not key.startswith('DYLD_')}
    try:
        returncode = subprocess.run(command, env=open_environment).returncode
    except OSError as error:
        returncode = 127
        # Record the OS error class/number only, without dumping environment or credentials.
        completion = {'error': type(error).__name__, 'errno': error.errno}
    else:
        completion = {}
    completion.update(timestamp=datetime.now(timezone.utc).isoformat(), returncode=returncode)
    (output_dir / 'completion.json').write_text(json.dumps(completion, indent=2) + '\n')
    emit({'output_dir': str(output_dir), 'returncode': returncode,
          'message': 'open completion is not proof of native loading or online state. '
                     'Check loaded.json and live callbacks separately.'})
    return returncode


if __name__ == '__main__':
    sys.exit(main())
