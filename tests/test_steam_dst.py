"""Steam wrapper behavior; the real macOS open/game boundary is never invoked."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class SteamWrapperTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[1] / 'tools/steam_dst.py'
        self.assertTrue(source.is_file(), 'Steam-mediated wrapper is not implemented')
        spec = importlib.util.spec_from_file_location('tools.steam_dst', source)
        self.wrapper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.wrapper)
        self.temp = tempfile.TemporaryDirectory(prefix="Steam wrapper's ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "Steam games/Don't Starve Together/dontstarve_steam.app"
        self.exe = self.app / 'Contents/MacOS/dontstarve_steam'
        self.exe.parent.mkdir(parents=True)
        self.exe.write_bytes(b'fixture executable')
        self.library = self.root / 'native/build/libdstmc_probe.dylib'
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b'fixture dylib')
        self.result = {
            'schema': 1, 'timestamp': 123, 'ready': True, 'blockers': [],
            'executable': {'path': str(self.exe), 'exists': True,
                           'executable_permission': True, 'sha256': 'exe-sha',
                           'architecture': 'x86_64'},
            'extension': {'path': str(self.library), 'exists': True,
                          'sha256': 'module-sha', 'architecture': 'x86_64'},
            'permissions': {'allow_dyld_environment_variables': True,
                            'disable_library_validation': True},
            'process_ids': [], 'ports': {'39379': 'available', '39380': 'available'},
            'save_lock': {'cluster': str(self.root / 'cluster'), 'status': 'unknown',
                          'matching_lock_filenames': [], 'note': 'fixture'},
        }
        self.calls = []
        self.preflight_calls = []
        self.open_returncode = 0
        self.addCleanup(patch.stopall)
        patch.object(self.wrapper, 'ROOT', self.root).start()
        patch.object(self.wrapper.preflight, 'DEFAULT_EXE', self.exe).start()
        patch.object(self.wrapper.preflight, 'preflight', self.check).start()
        patch.object(self.wrapper.subprocess, 'run', self.open_boundary).start()

    def check(self, executable, cluster):
        self.preflight_calls.append((executable, cluster))
        return copy.deepcopy(self.result)

    def open_boundary(self, argv, **kwargs):
        # The request must already be durable when the launch boundary is reached.
        manifests = list((self.root / 'evidence/steam-launches').glob('*/request.json'))
        self.assertTrue(manifests)
        self.calls.append((argv, kwargs, [json.loads(p.read_text()) for p in manifests]))
        return type('Completed', (), {'returncode': self.open_returncode})()

    def run_wrapper(self, args=None, env=None):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                code = self.wrapper.main(args if args is not None else [str(self.app)],
                                         environment=env if env is not None else {'SteamAppId': '322330'})
            except SystemExit as error:
                code = error.code
        return code, output.getvalue()

    def assert_no_launch_effects(self):
        self.assertEqual([], self.calls)
        self.assertFalse((self.root / 'evidence').exists())

    # Break: treating absent, foreign, empty, or contradictory Steam IDs as authorized.
    def test_steam_marker_rejected_before_preflight_or_writes(self):
        for env in ({}, {'SteamAppId': '1'}, {'SteamGameId': '1'},
                    {'SteamAppId': '322330', 'SteamGameId': '1'},
                    {'SteamAppId': '', 'SteamGameId': '322330'}):
            with self.subTest(env=env):
                code, _ = self.run_wrapper(env=env)
                self.assertNotEqual(0, code)
                self.assert_no_launch_effects()
                self.assertEqual([], self.preflight_calls)

    # Break: accepting another app, a raw executable, or a wrapper option as a target.
    def test_only_canonical_app_is_accepted(self):
        for args in ([], [str(self.root / 'other.app')], [str(self.exe)], ['--unknown']):
            with self.subTest(args=args):
                code, _ = self.run_wrapper(args=args)
                self.assertNotEqual(0, code)
                self.assert_no_launch_effects()
                self.assertEqual([], self.preflight_calls)

    # Break: ignoring an existing preflight blocker permits open to start a second game.
    def test_preflight_blockers_prevent_open(self):
        for reason in ('dst_already_running', 'unsupported_architecture',
                       'process_status_unknown', 'missing_extension'):
            with self.subTest(reason=reason):
                self.result.update(ready=False, blockers=[reason])
                code, _ = self.run_wrapper()
                self.assertNotEqual(0, code)
                self.assert_no_launch_effects()
        self.assertEqual(self.exe, self.preflight_calls[0][0])

    # Break: trusting preflight.ready without checking the required library and entitlements.
    def test_library_architecture_and_both_entitlements_are_required(self):
        for architecture in ('arm64', 'not_x86_64', ''):
            with self.subTest(architecture=architecture):
                self.result['extension']['architecture'] = architecture
                code, _ = self.run_wrapper()
                self.assertNotEqual(0, code)
                self.assert_no_launch_effects()
        self.result['extension']['architecture'] = 'x86_64 arm64'
        for permission in ('allow_dyld_environment_variables', 'disable_library_validation'):
            for value in (False, None, 'true', 1):
                with self.subTest(permission=permission, value=value):
                    self.result['permissions'][permission] = value
                    code, _ = self.run_wrapper()
                    self.assertNotEqual(0, code)
                    self.assert_no_launch_effects()
            self.result['permissions'][permission] = True

    # Break: shell reconstruction, overlay replacement, or inherited DYLD changes argv/env.
    def test_open_argv_environment_and_manifest_preserve_launch_intent(self):
        overlay = "/Steam overlay's folder/gameoverlayrenderer.dylib"
        other = '/Other overlay/lib.dylib'
        env = {'SteamGameId': '322330', 'PATH': '/usr/bin:/bin', 'SteamOverlayGameId': '322330',
               'STEAM_DYLD_INSERT_LIBRARIES': f'{overlay}:{self.library}',
               'DYLD_INSERT_LIBRARIES': f'{other}:{overlay}',
               'DYLD_FORCE_FLAT_NAMESPACE': '1', 'PRIVATE_TOKEN': 'never-log-me'}
        game_args = ['-console', "argument with spaces and 'apostrophe'", '--dry-run', '$(touch nope)']
        original_env = env.copy()
        code, output = self.run_wrapper([str(self.app), *game_args], env)
        self.assertEqual(0, code, output)
        self.assertEqual(original_env, env)
        self.assertEqual(1, len(self.calls))
        argv, options, manifests = self.calls[0]
        launch_dirs = list((self.root / 'evidence/steam-launches').iterdir())
        self.assertEqual(1, len(launch_dirs))
        launch_dir = launch_dirs[0]
        self.assertEqual([
            '/usr/bin/open', '--env', f'DYLD_INSERT_LIBRARIES={overlay}:{self.library}:{other}',
            '--env', f'DSTMC_PROBE_DIR={launch_dir}', '--env', 'DSTMC_FIRST_PERSON=1',
            '-n', '-W', str(self.app), '--args', *game_args,
        ], argv)
        self.assertFalse(options.get('shell', False))
        self.assertEqual({key: value for key, value in env.items() if not key.startswith('DYLD_')}, options['env'])
        manifest = manifests[0]
        self.assertEqual(os.getpid(), manifest['pid'])
        self.assertEqual(str(self.app), manifest['app'])
        self.assertEqual(str(self.exe), manifest['executable'])
        self.assertEqual({'path': str(self.library), 'sha256': 'module-sha'}, manifest['module'])
        self.assertEqual(str(launch_dir), manifest['output_dir'])
        self.assertEqual({'SteamGameId': '322330'}, manifest['steam_app_id_marker'])
        self.assertEqual(argv, manifest['open_argv'])
        self.assertTrue(manifest['timestamp'])
        completion = json.loads((launch_dir / 'completion.json').read_text())
        self.assertEqual(0, completion['returncode'])
        self.assertTrue((launch_dir / 'preflight.json').is_file(), 'capture tool needs preflight evidence')
        self.assertEqual(self.result, json.loads((launch_dir / 'preflight.json').read_text()))
        recorded = output + ''.join(p.read_text() for p in launch_dir.iterdir())
        self.assertNotIn('never-log-me', recorded)
        self.assertFalse((self.exe.parent / 'steam_appid.txt').exists())

    # Break: a fixed output path mixes evidence from separate Steam launch requests.
    def test_each_launch_has_unique_evidence_and_returns_open_failure(self):
        self.open_returncode = 7
        for env in ({'SteamAppId': '322330'}, {'SteamAppId': '322330', 'SteamGameId': '322330'}):
            code, _ = self.run_wrapper(env=env)
            self.assertEqual(7, code)
        directories = list((self.root / 'evidence/steam-launches').iterdir())
        self.assertEqual(2, len(directories))
        for directory in directories:
            self.assertEqual(7, json.loads((directory / 'completion.json').read_text())['returncode'])

    # Break: an unavailable open command loses the completion evidence or leaks exception text.
    def test_open_os_error_is_recorded_without_exception_details(self):
        with patch.object(self.wrapper.subprocess, 'run',
                          side_effect=FileNotFoundError(2, 'private exception detail')):
            code, output = self.run_wrapper()
        self.assertEqual(127, code)
        directory = next((self.root / 'evidence/steam-launches').iterdir())
        completion = json.loads((directory / 'completion.json').read_text())
        self.assertEqual(127, completion['returncode'])
        self.assertEqual(2, completion['errno'])
        self.assertNotIn('private exception detail', output + (directory / 'completion.json').read_text())

    # Break: read-only diagnostics become an alternate real launch path or write evidence.
    def test_dry_run_reports_missing_marker_and_preflight_blockers_without_effects(self):
        self.result.update(ready=False, blockers=['dst_already_running'])
        code, output = self.run_wrapper(['--dry-run', str(self.app), '-console'], {})
        self.assertNotEqual(0, code)
        diagnostic = json.loads(output)
        self.assertIn('steam_app_id_missing', diagnostic['blockers'])
        self.assertIn('dst_already_running', diagnostic['blockers'])
        self.assertEqual(['--args', '-console'], diagnostic['open_argv'][-2:])
        self.assert_no_launch_effects()

    def test_ready_dry_run_and_help_are_read_only(self):
        code, output = self.run_wrapper(['--dry-run', str(self.app)])
        self.assertEqual(0, code, output)
        self.assertTrue(json.loads(output)['dry_run'])
        self.assert_no_launch_effects()
        code, output = self.run_wrapper(['--help'], {})
        self.assertEqual(0, code)
        self.assertIn('%command%', output)
        self.assert_no_launch_effects()


class FreshInterpreterReadOnlyTests(unittest.TestCase):
    # Break: importing local helpers before suppression writes cache on otherwise read-only paths.
    def test_diagnostic_and_rejected_startup_never_write_local_module_cache(self):
        source = Path(__file__).resolve().parents[1] / 'tools/steam_dst.py'
        with tempfile.TemporaryDirectory(prefix='steam-read-only-') as temporary:
            root = Path(temporary).resolve()
            tools = root / 'tools'
            tools.mkdir()
            script = tools / 'steam_dst.py'
            script.write_bytes(source.read_bytes())
            app = root / 'Game.app'
            (tools / 'preflight.py').write_text(
                'from pathlib import Path\n'
                f'DEFAULT_EXE = Path({str(app / "Contents/MacOS/game")!r})\n'
                f'DEFAULT_CLUSTER = Path({str(root / "cluster")!r})\n'
                'def preflight(executable, cluster):\n'
                '    return {"ready": False, "blockers": ["fixture_blocker"],\n'
                '            "extension": {"path": "/fixture/probe.dylib", "architecture": "x86_64"},\n'
                '            "permissions": {"allow_dyld_environment_variables": True,\n'
                '                            "disable_library_validation": True}}\n')
            # Even a regression must never cross a real external launch boundary.
            (tools / 'subprocess.py').write_text(
                'def run(*args, **kwargs):\n'
                '    raise AssertionError("external launch forbidden in cache test")\n')
            cases = [
                ('help', ['--help'], {}, 0),
                ('dry-run', ['--dry-run', str(app)], {}, 1),
                ('missing-marker', [str(app)], {}, 2),
                ('wrong-marker', [str(app)], {'SteamAppId': '1'}, 2),
                ('conflicting-markers', [str(app)],
                 {'SteamAppId': '322330', 'SteamGameId': '1'}, 2),
                ('wrong-app', [str(root / 'Other.app')], {'SteamAppId': '322330'}, 2),
            ]
            for name, args, marker, expected_code in cases:
                with self.subTest(path=name):
                    cache = root / ('cache-' + name)
                    result = subprocess.run(
                        [sys.executable, '-S', str(script), *args],
                        env={'PATH': os.environ.get('PATH', ''),
                             'PYTHONPYCACHEPREFIX': str(cache), **marker},
                        capture_output=True, text=True)
                    self.assertEqual(expected_code, result.returncode, result.stderr)
                    # Python bootstrap can populate its own stdlib cache before script
                    # execution. Only imports caused by our wrapper are in this subtree.
                    local_cache = cache / str(tools).lstrip('/')
                    self.assertFalse(local_cache.exists(),
                                     f'{name} wrote wrapper/helper cache: {list(local_cache.rglob("*"))}')
                    self.assertFalse((tools / '__pycache__').exists())
                    self.assertFalse((root / 'evidence').exists())


if __name__ == '__main__':
    unittest.main()
