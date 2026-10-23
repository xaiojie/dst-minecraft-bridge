import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from tools.windows_loader import inject_library
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.name=='nt','requires a real Windows x64 process')
class NativeLoader(unittest.TestCase):
    def test_created_child_loads_unicode_dll_and_emits_marker(self):
        candidates=[ROOT/'native/build-windows/Release/loader_fixture.dll',ROOT/'native/build-windows/loader_fixture.dll']
        library=next((path for path in candidates if path.is_file()),None)
        self.assertIsNotNone(library,'build CMake loader_fixture before Windows checks')
        import shutil
        with tempfile.TemporaryDirectory(prefix='bridge 注入 path ')as td:
            directory=Path(td);copied=directory/'测试 bridge.dll';shutil.copyfile(library,copied)
            marker=directory/'loaded.txt'
            child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],env=dict(os.environ,DSTMC_LOADER_MARKER=str(marker)))
            try:
                inject_library(child.pid,copied)
                deadline=time.monotonic()+5
                while not marker.exists()and time.monotonic()<deadline:time.sleep(.02)
                self.assertEqual('loaded',marker.read_text())
            finally:child.terminate();child.wait(timeout=10)
