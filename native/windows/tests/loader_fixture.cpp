#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static DWORD WINAPI marker(void*){
    wchar_t path[32768];auto n=GetEnvironmentVariableW(L"DSTMC_LOADER_MARKER",path,32768);
    if(!n||n>=32768)return 1;
    auto file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE)return 2;
    const char value[]="loaded";DWORD written=0;
    auto ok=WriteFile(file,value,6,&written,nullptr);CloseHandle(file);
    return ok&&written==6?0:3;
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID){
    if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(instance);auto thread=CreateThread(nullptr,0,marker,nullptr,0,nullptr);if(thread)CloseHandle(thread);else return FALSE;}
    return TRUE;
}
