"""Resolve the game Steam actually registers, not a leftover installation."""
from pathlib import Path
import tempfile
import unittest

from tools import preflight


class SteamInstallTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import patch
        self.addCleanup(patch.stopall)
        patch.object(preflight.host,'platform_name',return_value='macos').start()
        self.temp = tempfile.TemporaryDirectory(prefix="Steam 库's ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.steam = self.root / 'Steam'
        (self.steam / 'steamapps').mkdir(parents=True)

    def library(self, name, *, appid='322330', install="Don't Starve Together"):
        path = self.root / name
        apps = path / 'steamapps'
        apps.mkdir(parents=True, exist_ok=True)
        (apps / 'appmanifest_322330.acf').write_text(
            '"AppState" { "appid" "' + appid + '" "installdir" "' + install + '" }')
        exe = apps / 'common' / install / 'dontstarve_steam.app/Contents/MacOS/dontstarve_steam'
        exe.parent.mkdir(parents=True, exist_ok=True)
        exe.write_bytes(b'game fixture')
        return path, exe

    def catalog(self, entries):
        rows = []
        for i, (path, active) in enumerate(entries):
            ids = '"322330" "1"' if active else '"3167020" "1"'
            rows.append(f'"{i}" {{ "path" "{path}" "apps" {{ {ids} }} }}')
        (self.steam / 'steamapps/libraryfolders.vdf').write_text(
            '"libraryfolders" {\n' + '\n'.join(rows) + '\n}')

    def test_external_active_library_wins_over_existing_old_copy(self):
        old, _ = self.library('Old Library')
        active, expected = self.library('新安装 SteamLibrary')
        self.catalog([(old, False), (active, True)])
        self.assertEqual(expected.resolve(), preflight.resolve_dst_executable(self.steam))

    def test_missing_or_ambiguous_active_install_is_rejected(self):
        a, _ = self.library('A')
        b, _ = self.library('B')
        for entries in ([(a, False)], [(a, True), (b, True)]):
            with self.subTest(entries=entries):
                self.catalog(entries)
                with self.assertRaises(ValueError):
                    preflight.resolve_dst_executable(self.steam)

    def test_mismatched_manifest_and_missing_binary_are_rejected(self):
        path, exe = self.library('A', appid='1')
        self.catalog([(path, True)])
        with self.assertRaises(ValueError):
            preflight.resolve_dst_executable(self.steam)
        path, exe = self.library('A')
        exe.unlink()
        with self.assertRaises(ValueError):
            preflight.resolve_dst_executable(self.steam)

    def test_manifest_cannot_escape_the_registered_library(self):
        path, _ = self.library('A', install='../../outside')
        self.catalog([(path, True)])
        with self.assertRaises(ValueError):
            preflight.resolve_dst_executable(self.steam)

    def test_unreadable_and_malformed_catalog_fail_without_side_effects(self):
        catalog = self.steam / 'steamapps/libraryfolders.vdf'
        for content in (None, '"libraryfolders" { "0" {', '"libraryfolders" {} garbage'):
            if content is not None:
                catalog.write_text(content)
            with self.subTest(content=content), self.assertRaises(ValueError):
                preflight.resolve_dst_executable(self.steam)
        self.assertEqual(['steamapps'], [p.name for p in self.steam.iterdir()])

    def test_wrong_metadata_types_are_rejected_as_install_errors(self):
        path, _ = self.library('A')
        catalog = self.steam / 'steamapps/libraryfolders.vdf'
        catalog.write_text(f'"libraryfolders" {{ "0" {{ "path" "{path}" "apps" "322330" }} }}')
        with self.assertRaises(ValueError):
            preflight.resolve_dst_executable(self.steam)
        self.catalog([(path, True)])
        (path / 'steamapps/appmanifest_322330.acf').write_text('"AppState" "invalid"')
        with self.assertRaises(ValueError):
            preflight.resolve_dst_executable(self.steam)
