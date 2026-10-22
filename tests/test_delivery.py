import importlib.util
import json
import pathlib
import tempfile
import unittest
import zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'tools'/f'{name}.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
class DeliveryTests(unittest.TestCase):
    def test_package_allowlist_excludes_saves_tokens_symlinks(self):
        pack=module('package_release')
        with tempfile.TemporaryDirectory() as td:
            root=pathlib.Path(td);(root/'dst-mod').mkdir();(root/'dst-mod/modmain.lua').write_text('return {}')
            (root/'dst-mod/token.txt').write_text('private');(root/'mc/run/saves/private').mkdir(parents=True)
            (root/'mc/run/saves/private/level.dat').write_bytes(b'game');(root/'mc/src').mkdir();(root/'mc/src/secret.java').symlink_to(root/'dst-mod/token.txt')
            (root/'native/build').mkdir(parents=True);(root/'native/build/libdstmc_probe.dylib').write_bytes(b'library')
            (root/'mc/build/libs').mkdir(parents=True);(root/'mc/build/libs/dst-mc.jar').write_bytes(b'mod')
            result=pack.package(root,root/'out.zip')
            with zipfile.ZipFile(root/'out.zip')as z:
                names=z.namelist();self.assertIn('dst-mod/modmain.lua',names);self.assertIn('native/build/libdstmc_probe.dylib',names)
                self.assertFalse(any('token' in n or 'level.dat' in n or 'secret.java' in n for n in names))
                self.assertEqual(len(result['files']),len(names)-1)
    def test_frozen_frames_are_not_fps(self):
        acceptance=module('record_acceptance')
        frozen=[{'event':'compose','status':0,'frame':42,'t':i*16}for i in range(3751)]
        self.assertLess(acceptance.frame_metrics(frozen)['unique_frame_fps'],.1)
        report=acceptance.empty_report('current',{'region':'ground'},'epoch')
        self.assertTrue(all(i['result']=='NOT_VERIFIED' for i in report['checks']))
        with self.assertRaises(ValueError):acceptance.apply_observations(report,{'run_id':'old','checks':[]})
