import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools import windows_steam
from tests.test_windows_tools import pe


class WindowsSteam(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='Windows 游戏 spaces ');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.exe=self.root/'Steam/游戏/bin64/dontstarve_steam_x64.exe';pe(self.exe)
        self.library=self.root/'native/build-windows/dstmc_bridge.dll';pe(self.library,dll=True)
        self.addCleanup(patch.stopall)
        patch.object(windows_steam,'ROOT',self.root).start()
        patch.object(windows_steam.preflight,'resolve_dst_executable',return_value=self.exe).start()
        patch.object(windows_steam,'running_processes',return_value=[]).start()

    def run_wrapper(self,args=None,env=None):
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            code=windows_steam.main(args if args is not None else [str(self.exe)],environment=env if env is not None else {'SteamAppId':'322330'})
        return code,out.getvalue()

    def test_dry_run_is_read_only_and_refuses_wrong_target_arch_or_steam_id(self):
        code,out=self.run_wrapper(['--dry-run',str(self.exe)])
        self.assertEqual(0,code,out);self.assertFalse((self.root/'evidence').exists())
        self.assertEqual(2,self.run_wrapper(env={})[0])
        self.assertEqual(2,self.run_wrapper([str(self.exe.with_name('other.exe'))])[0])
        pe(self.library,0x14c,True)
        self.assertNotEqual(0,self.run_wrapper()[0]);self.assertFalse((self.root/'evidence').exists())

    def test_success_preserves_argv_environment_and_waits_for_verified_load(self):
        calls=[]
        class Process:
            pid=12345
            def poll(self):return None
            def wait(self,timeout=None):return 0
            def terminate(self):raise AssertionError('successful game terminated')
        def create(argv,**kwargs):
            calls.append((argv,kwargs))
            directory=Path(kwargs['env']['DSTMC_PROBE_DIR'])
            self.assertTrue((directory/'request.json').is_file())
            (directory/'loaded.json').write_text(json.dumps({'pid':12345,'architecture':'x86_64'}))
            return Process()
        with patch.object(windows_steam.subprocess,'Popen',side_effect=create),patch.object(windows_steam,'inject_library')as inject:
            env={'SteamAppId':'322330','SECRET_TOKEN':'never-log-this'}
            code,out=self.run_wrapper([str(self.exe),'-console','argument with spaces & % !'],env)
            self.assertEqual(0,code,out)
            self.assertEqual([str(self.exe),'-console','argument with spaces & % !'],calls[0][0])
            self.assertFalse(calls[0][1].get('shell',False))
            self.assertEqual('never-log-this',calls[0][1]['env']['SECRET_TOKEN'])
            inject.assert_called_once_with(12345,self.library.resolve())
            content=''.join(p.read_text()for p in (self.root/'evidence').rglob('*.json'))
            self.assertNotIn('never-log-this',content)
            self.assertTrue(list((self.root/'evidence').rglob('completion.json')))

    def test_load_failure_terminates_only_the_child_and_returns_failure(self):
        class Process:
            pid=12345;terminated=False
            def poll(self):return None
            def terminate(self):self.terminated=True
            def wait(self,timeout=None):return 7
        process=Process()
        with patch.object(windows_steam.subprocess,'Popen',return_value=process),patch.object(windows_steam,'inject_library',side_effect=OSError('load failed')):
            code,out=self.run_wrapper()
        self.assertNotEqual(0,code);self.assertTrue(process.terminated)
        completion=json.loads(next((self.root/'evidence').rglob('completion.json')).read_text())
        self.assertFalse(completion['native_loaded'])
