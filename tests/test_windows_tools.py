import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

from tools import platform_support as host


def pe(path, machine=0x8664, dll=False):
    data=bytearray(256);data[:2]=b'MZ';struct.pack_into('<I',data,60,128)
    data[128:132]=b'PE\0\0';struct.pack_into('<H',data,132,machine)
    struct.pack_into('<H',data,148,112);struct.pack_into('<H',data,150,0x2000 if dll else 2)
    struct.pack_into('<H',data,152,0x20b if machine==0x8664 else 0x10b)
    path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)


class WindowsTools(unittest.TestCase):
    def test_windows_bundle_contains_dll_native_sources_and_scripts(self):
        from tools.package_release import package
        import zipfile
        with tempfile.TemporaryDirectory()as td:
            root=Path(td);pe(root/'native/build-windows/dstmc_bridge.dll',dll=True)
            (root/'mc/build/libs').mkdir(parents=True);(root/'mc/build/libs/bridge.jar').write_bytes(b'jar')
            for name in ('native/CMakeLists.txt','native/windows/backend.cpp','native/windows/third_party/GLES2/gl2.h','tools/launch_bridge.cmd'):
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('source')
            package(root,root/'bundle.zip',platform='windows')
            with zipfile.ZipFile(root/'bundle.zip')as archive:
                names=archive.namelist()
                self.assertIn('native/build-windows/dstmc_bridge.dll',names)
                self.assertIn('native/windows/third_party/GLES2/gl2.h',names)
                self.assertIn('native/CMakeLists.txt',names)
                self.assertIn('tools/launch_bridge.cmd',names)
                self.assertNotIn('native/build/libdstmc_probe.dylib',names)
    def test_pe_must_be_x64_and_have_expected_kind(self):
        with tempfile.TemporaryDirectory()as td:
            path=Path(td)/'bridge.dll';pe(path,dll=True)
            self.assertEqual('x86_64',host.pe_info(path)['architecture'])
            self.assertTrue(host.pe_info(path)['is_dll'])
            pe(path,0x14c)
            self.assertEqual('x86',host.pe_info(path)['architecture'])
            path.write_bytes(b'MZ'+bytes(80))
            with self.assertRaises(ValueError):host.pe_info(path)

    def test_windows_defaults_and_gradle_use_argument_array_without_shell(self):
        with tempfile.TemporaryDirectory(prefix='项目 with spaces ')as td:
            root=Path(td)
            self.assertEqual(root/'.minecraft/assets',host.default_assets('windows',{'APPDATA':td}))
            command=host.gradle_command(root,root/'JDK/bin/java.exe',['check','build'])
            self.assertEqual(str(root/'JDK/bin/java.exe'),command[0])
            self.assertIn('org.gradle.wrapper.GradleWrapperMain',command)
            self.assertIn('check',command)
            self.assertFalse(any('cmd.exe' in part or part=='/c' for part in command))

    def test_windows_catalog_uses_registered_bin64_and_rejects_32bit(self):
        from tools import preflight
        with tempfile.TemporaryDirectory()as td:
            root=Path(td);steam=root/'Steam';library=root/'Games 饥荒'
            (steam/'steamapps').mkdir(parents=True);(library/'steamapps').mkdir(parents=True)
            vdf={'libraryfolders':{'0':{'path':str(library),'apps':{'322330':'1'}}}}
            def write_vdf(value):
                return '\n'.join(json.dumps(k,ensure_ascii=False)+' '+('{\n'+write_vdf(v)+'\n}' if isinstance(v,dict)else json.dumps(v,ensure_ascii=False))for k,v in value.items())
            (steam/'steamapps/libraryfolders.vdf').write_text(write_vdf(vdf))
            (library/'steamapps/appmanifest_322330.acf').write_text(write_vdf({'AppState':{'appid':'322330','installdir':"Don't Starve Together"}}))
            exe=library/"steamapps/common/Don't Starve Together/bin64/dontstarve_steam_x64.exe";pe(exe)
            self.assertEqual(exe.resolve(),preflight.resolve_dst_executable(steam,platform='windows'))
            exe.unlink();pe(exe.parents[1]/'bin/dontstarve_steam.exe',machine=0x14c)
            with self.assertRaisesRegex(ValueError,'not_found'):preflight.resolve_dst_executable(steam,platform='windows')

    def test_steam_marker_must_not_be_absent_or_contradictory(self):
        for env in ({},{'SteamAppId':'1'},{'SteamAppId':'322330','SteamGameId':'1'}):
            self.assertFalse(host.steam_authorized(env))
        self.assertTrue(host.steam_authorized({'SteamAppId':'322330'}))
