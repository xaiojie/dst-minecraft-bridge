from pathlib import Path
import unittest
try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime=None
ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(LuaRuntime,'requires lupa')
class WindowsMailbox(unittest.TestCase):
    def test_windows_absolute_path_and_repeated_requests_replace_closed_file(self):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
        clock=0;files={};counter=0
        function GetTimeRealSeconds()return clock end
        package.preload['json']=function()return {encode=function(v)return v.id end,decode=function(v)return {id=v,value={ok=true}}end}end
        package.preload['components/dstmcidentity']=function()return {NewUUID=function()counter=counter+1;return tostring(counter)end}end
        io={open=function(path,mode)
          if mode=='w'then return {write=function(self,value)files[path]=value end,close=function()end}end
          if files[path]then return {read=function()return files[path]end,close=function()end}end
        end}
        os={remove=function(path)files[path]=nil;return true end,rename=function(a,b)
          if files[b]then return nil,'Windows destination exists'end
          files[b]=files[a];files[a]=nil;return true
        end}
        ''')
        lua.globals().mailbox=lua.execute((ROOT/'dst-mod/scripts/dstmc/mailbox.lua').read_text())
        lua.execute('''
          assert(not mailbox.Bind('C:relative'))
          assert(mailbox.Bind('C:/bridge/camera-mailbox'),'Windows absolute path refused')
          assert(mailbox.Request('/v2/camera/lease',{},function(v)received=v.ok end))
          files['C:/bridge/camera-mailbox/response.json']='1';mailbox.Poll();assert(received)
          assert(mailbox.Request('/v2/camera/cycle',{},function()end),'second Windows request failed')
          assert(mailbox.Active());assert(files['C:/bridge/camera-mailbox/request.json']=='2')
        ''')
