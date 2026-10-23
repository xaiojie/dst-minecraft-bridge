#include "frame_protocol.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <cstring>
#include <iostream>
#include <string>
#if !defined(__x86_64__) && !defined(_M_X64)
#error This contract must read the ARM64 Java publication from x86_64.
#endif

int main(int argc,char** argv) {
    if(argc!=5)return 2;
    if(std::strlen(argv[2])!=64||std::strlen(argv[3])!=32)return 2;
#ifdef _WIN32
    int count=0;auto wide=CommandLineToArgvW(GetCommandLineW(),&count);
    if(!wide||count!=5){if(wide)LocalFree(wide);return 2;}
    HANDLE file=CreateFileW(wide[1],GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    LocalFree(wide);LARGE_INTEGER size{};
    if(file==INVALID_HANDLE_VALUE)return 3;
    if(!GetFileSizeEx(file,&size)||size.QuadPart<4096||size.QuadPart>80*1024*1024){CloseHandle(file);return 3;}
    HANDLE mapping=CreateFileMappingW(file,nullptr,PAGE_READWRITE,0,0,nullptr);
    if(!mapping){CloseHandle(file);return 4;}
    void* memory=MapViewOfFile(mapping,FILE_MAP_READ|FILE_MAP_WRITE,0,0,0);
    if(!memory){CloseHandle(mapping);CloseHandle(file);return 4;}
    const auto length=static_cast<size_t>(size.QuadPart);
#else
    int fd=open(argv[1],O_RDWR);struct stat st{};
    if(fd<0)return 3;
    if(fstat(fd,&st)){close(fd);return 3;}
    void* memory=mmap(nullptr,st.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(memory==MAP_FAILED){close(fd);return 4;}
    const auto length=static_cast<size_t>(st.st_size);
#endif
    dstmc::FrameKey key{};
    for(size_t i=0;i<32;i++)key.pair_hash[i]=std::stoul(std::string(argv[2]+i*2,2),nullptr,16);
    for(size_t i=0;i<16;i++)key.epoch[i]=std::stoul(std::string(argv[3]+i*2,2),nullptr,16);
    key.id=std::stoull(argv[4]);
    int result=0;
    {
        // Real exact-key reader and RAII lease, not a second test-only ABI parser.
        auto frame=dstmc::read_frame(memory,length,key);
        if(!frame)result=5;
        else {
            const uint8_t world[]={128,0,0,128},hud[]={0,0,64,64};
            float depth;std::memcpy(&depth,frame->depth,sizeof(depth));
            if(frame->width!=1 || frame->height!=1 || frame->layer_bytes!=4)result=6;
            else if(std::memcmp(frame->color,world,4) || depth!=0.25f || std::memcmp(frame->hud,hud,4))result=7;
        }
    } // Release lease before unmapping.
#ifdef _WIN32
    UnmapViewOfFile(memory);CloseHandle(mapping);CloseHandle(file);
#else
    munmap(memory,length);close(fd);
#endif
    if(result)std::cerr<<"x86_64 published RGBA/depth/HUD contract rejected: "<<result<<'\n';
    else std::cout<<"x86_64 published RGBA/depth/HUD channels verified\n";
    return result;
}
