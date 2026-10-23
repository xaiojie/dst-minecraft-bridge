from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from tools import deploy_dst_mod


class Deployment(unittest.TestCase):
    def test_dry_plan_has_no_writes_and_apply_keeps_old_mod(self):
        with tempfile.TemporaryDirectory()as td:
            root=Path(td);source=root/'repository/dst-mod';source.mkdir(parents=True)
            (source/'modinfo.lua').write_text('name="bridge"');(source/'modmain.lua').write_text('new')
            destination=root/'game/mods/dst_mc_first_person'
            plan=deploy_dst_mod.plan(source,destination)
            self.assertFalse(destination.parent.exists())
            destination.mkdir(parents=True);(destination/'modmain.lua').write_text('old')
            receipt=deploy_dst_mod.apply(plan)
            self.assertEqual('new',(destination/'modmain.lua').read_text())
            self.assertEqual('old',(Path(receipt['backup'])/'modmain.lua').read_text())

    def test_failed_swap_restores_previous_mod(self):
        with tempfile.TemporaryDirectory()as td:
            root=Path(td);source=root/'dst-mod';source.mkdir()
            (source/'modinfo.lua').write_text('bridge');(source/'modmain.lua').write_text('new')
            destination=root/'mods/dst_mc_first_person';destination.mkdir(parents=True)
            (destination/'modmain.lua').write_text('old')
            original=Path.replace
            def replace(path,target):
                if path.name.startswith('.dstmc-stage-'):raise PermissionError('blocked swap')
                return original(path,target)
            with patch.object(Path,'replace',replace):
                with self.assertRaises(PermissionError):deploy_dst_mod.apply(deploy_dst_mod.plan(source,destination))
            self.assertEqual('old',(destination/'modmain.lua').read_text())
