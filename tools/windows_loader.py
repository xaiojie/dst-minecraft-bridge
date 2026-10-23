"""Load our x64 DLL only into the freshly created Steam child supplied by caller.

No debug privilege or arbitrary process search/attachment is used. Kernel export
addresses are resolved as module-relative offsets in the actual target process.
"""
import ctypes
from pathlib import Path
import os
import time


def inject_library(pid,library,timeout=10):
    if os.name!='nt' or ctypes.sizeof(ctypes.c_void_p)!=8:
        raise OSError('Windows x64 Python is required')
    from ctypes import wintypes as w
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    class Module(ctypes.Structure):
        _fields_=[('dwSize',w.DWORD),('th32ModuleID',w.DWORD),('th32ProcessID',w.DWORD),
                  ('GlblcntUsage',w.DWORD),('ProccntUsage',w.DWORD),('modBaseAddr',ctypes.c_void_p),
                  ('modBaseSize',w.DWORD),('hModule',w.HMODULE),('szModule',w.WCHAR*256),('szExePath',w.WCHAR*260)]
    signatures={
        'OpenProcess':([w.DWORD,w.BOOL,w.DWORD],w.HANDLE),
        'CloseHandle':([w.HANDLE],w.BOOL),
        'CreateToolhelp32Snapshot':([w.DWORD,w.DWORD],w.HANDLE),
        'Module32FirstW':([w.HANDLE,ctypes.POINTER(Module)],w.BOOL),
        'Module32NextW':([w.HANDLE,ctypes.POINTER(Module)],w.BOOL),
        'GetModuleHandleW':([w.LPCWSTR],w.HMODULE),
        'GetModuleHandleExW':([w.DWORD,ctypes.c_void_p,ctypes.POINTER(w.HMODULE)],w.BOOL),
        'GetModuleFileNameW':([w.HMODULE,w.LPWSTR,w.DWORD],w.DWORD),
        'GetProcAddress':([w.HMODULE,ctypes.c_char_p],ctypes.c_void_p),
        'VirtualAllocEx':([w.HANDLE,ctypes.c_void_p,ctypes.c_size_t,w.DWORD,w.DWORD],ctypes.c_void_p),
        'VirtualFreeEx':([w.HANDLE,ctypes.c_void_p,ctypes.c_size_t,w.DWORD],w.BOOL),
        'WriteProcessMemory':([w.HANDLE,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t)],w.BOOL),
        'CreateRemoteThread':([w.HANDLE,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_void_p,w.DWORD,ctypes.POINTER(w.DWORD)],w.HANDLE),
        'WaitForSingleObject':([w.HANDLE,w.DWORD],w.DWORD),
    }
    for name,(arguments,result)in signatures.items():
        function=getattr(kernel,name);function.argtypes=arguments;function.restype=result
    def error(stage):return OSError(ctypes.get_last_error(),stage)
    def modules():
        snapshot=kernel.CreateToolhelp32Snapshot(0x8|0x10,pid)
        if snapshot==ctypes.c_void_p(-1).value:
            if ctypes.get_last_error()==24:return [] # loader changed during snapshot
            raise error('module snapshot')
        try:
            entry=Module();entry.dwSize=ctypes.sizeof(entry);result=[]
            success=kernel.Module32FirstW(snapshot,ctypes.byref(entry))
            while success:
                result.append((entry.szModule.casefold(),entry.szExePath,entry.modBaseAddr))
                success=kernel.Module32NextW(snapshot,ctypes.byref(entry))
            return result
        finally:kernel.CloseHandle(snapshot)
    library=Path(library).resolve()
    from_module=kernel.GetModuleHandleW('kernel32.dll')
    address=kernel.GetProcAddress(from_module,b'LoadLibraryW')
    owner=w.HMODULE()
    if not address or not kernel.GetModuleHandleExW(0x6,address,ctypes.byref(owner)):
        raise error('resolve LoadLibraryW owner')
    owner_path=ctypes.create_unicode_buffer(32768)
    if not kernel.GetModuleFileNameW(owner,owner_path,len(owner_path)):raise error('resolve loader module path')
    owner_name=Path(owner_path.value).name.casefold();offset=address-owner.value
    deadline=time.monotonic()+timeout;remote_base=None
    while time.monotonic()<deadline:
        remote_base=next((base for name,_,base in modules()if name==owner_name),None)
        if remote_base is not None:break
        time.sleep(.02)
    if remote_base is None:raise TimeoutError('target loader module did not initialize')
    process=kernel.OpenProcess(0x2|0x8|0x10|0x20|0x400,False,pid)
    if not process:raise error('open owned game child')
    allocation=None;thread=None;thread_finished=False
    try:
        data=ctypes.create_unicode_buffer(str(library));size=ctypes.sizeof(data)
        allocation=kernel.VirtualAllocEx(process,None,size,0x1000|0x2000,0x04)
        if not allocation:raise error('allocate loader path')
        written=ctypes.c_size_t()
        if not kernel.WriteProcessMemory(process,allocation,data,size,ctypes.byref(written))or written.value!=size:
            raise error('write loader path')
        thread=kernel.CreateRemoteThread(process,None,0,remote_base+offset,allocation,0,None)
        if not thread:raise error('start DLL loader')
        result=kernel.WaitForSingleObject(thread,max(1,int((deadline-time.monotonic())*1000)))
        if result==258:raise TimeoutError('DLL loader timed out; terminate the owned child')
        if result!=0:raise error('wait DLL loader')
        thread_finished=True
        # HMODULE is 64 bits, a thread exit code is only DWORD. Verify the full
        # mapped module path instead of truncating the LoadLibrary return value.
        expected=str(library).casefold()
        if not any(str(Path(path).resolve()).casefold()==expected for _,path,_ in modules()):
            raise OSError('LoadLibraryW completed without mapping the bridge DLL')
    finally:
        if thread:kernel.CloseHandle(thread)
        # Never free a path that a timed-out remote thread might still read.
        # The caller terminates its own failed child, reclaiming that allocation.
        if allocation and (not thread or thread_finished):kernel.VirtualFreeEx(process,allocation,0,0x8000)
        kernel.CloseHandle(process)
