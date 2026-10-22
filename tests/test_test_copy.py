import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from tools.prepare_test_copy import prepare

JAVA = '/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home/bin/java'

class TestCopy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'level.dat').write_bytes(b'test level')
        (self.source / 'session.lock').write_bytes(b'original lock bytes')
        self.dest = self.root / 'dest'
    def tearDown(self):
        self.tmp.cleanup()
    # Break: ignoring Minecraft's POSIX FileChannel lock allows an incoherent save copy.
    def test_active_save_copy_refused(self):
        java = self.root / 'LockHolder.java'
        java.write_text('''import java.nio.channels.*;import java.nio.file.*;
class LockHolder {public static void main(String[] a)throws Exception{
try(var c=FileChannel.open(Path.of(a[0]),StandardOpenOption.WRITE);var l=c.lock()){
System.out.println("LOCKED");System.out.flush();System.in.read();}}}''')
        with subprocess.Popen([JAVA,str(java),str(self.source/'session.lock')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True) as holder:
            self.assertEqual('LOCKED',holder.stdout.readline().strip())
            try:
                with self.assertRaisesRegex(RuntimeError,'active|locked'):
                    prepare(self.source,self.dest)
                self.assertFalse(self.dest.exists())
            finally:
                holder.stdin.write('\n');holder.stdin.flush();holder.wait(timeout=5)
    # Break: treating a stale lock file as an active session, or mutating source metadata.
    def test_unlocked_copy_provenance_and_source_unchanged(self):
        before={p.name:p.read_bytes() for p in self.source.iterdir()}
        prepare(self.source,self.dest)
        self.assertEqual(before,{p.name:p.read_bytes() for p in self.source.iterdir()})
        self.assertEqual(b'test level',(self.dest/'level.dat').read_bytes())
        self.assertTrue((self.dest/'dst-mc-copy-source.json').exists(), 'missing copy provenance')
        provenance=json.loads((self.dest/'dst-mc-copy-source.json').read_text())
        self.assertEqual(str(self.source.resolve()),provenance['source'])
        self.assertFalse((self.dest/'session.lock').exists())
    def test_existing_destination_refused(self):
        self.dest.mkdir();(self.dest/'keep').write_text('mine')
        with self.assertRaises(FileExistsError):prepare(self.source,self.dest)
        self.assertEqual('mine',(self.dest/'keep').read_text())
