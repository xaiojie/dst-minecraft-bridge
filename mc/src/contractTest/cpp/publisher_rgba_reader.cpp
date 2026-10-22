#include "frame_protocol.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <iostream>
#include <string>
#if !defined(__x86_64__)
#error This contract must read the ARM64 Java publication from x86_64.
#endif

int main(int argc,char** argv) {
    if(argc!=5)return 2;
    int fd=open(argv[1],O_RDWR);struct stat st{};
    if(fd<0 || fstat(fd,&st))return 3;
    void* memory=mmap(nullptr,st.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(memory==MAP_FAILED){close(fd);return 4;}
    dstmc::FrameKey key{};
    for(size_t i=0;i<32;i++)key.pair_hash[i]=std::stoul(std::string(argv[2]+i*2,2),nullptr,16);
    for(size_t i=0;i<16;i++)key.epoch[i]=std::stoul(std::string(argv[3]+i*2,2),nullptr,16);
    key.id=std::stoull(argv[4]);
    int result=0;
    {
        // Real exact-key reader and RAII lease, not a second test-only ABI parser.
        auto frame=dstmc::read_frame(memory,st.st_size,key);
        if(!frame)result=5;
        else {
            const uint8_t world[]={128,0,0,128},hud[]={0,0,64,64};
            float depth;std::memcpy(&depth,frame->depth,sizeof(depth));
            if(frame->width!=1 || frame->height!=1 || frame->layer_bytes!=4)result=6;
            else if(std::memcmp(frame->color,world,4) || depth!=0.25f || std::memcmp(frame->hud,hud,4))result=7;
        }
    } // Release lease before unmapping.
    munmap(memory,st.st_size);close(fd);
    if(result)std::cerr<<"x86_64 published RGBA/depth/HUD contract rejected: "<<result<<'\n';
    else std::cout<<"x86_64 published RGBA/depth/HUD channels verified\n";
    return result;
}
