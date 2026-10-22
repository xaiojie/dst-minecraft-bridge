#include "frame_protocol.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <chrono>
#include <thread>
#include <filesystem>
#include <fstream>
#include <unistd.h>
#include <cstring>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <vector>
using namespace dstmc;
static int failures=0;
static void check(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
static void test(const char* name,const std::function<void()>& body) {
    try { body();std::cout<<"PASS "<<name<<'\n'; }
    catch(const std::exception& error) { failures++;std::cerr<<"FAIL "<<name<<": "<<error.what()<<'\n'; }
}
static FrameKey key(uint64_t id=42) {
    FrameKey k{};
    const char* hex="cac1697358c4cd71f8a26276dc1f808ec0237df088f18dae53d272e25978650e";
    for(size_t i=0;i<32;i++)k.pair_hash[i]=static_cast<uint8_t>(std::stoul(std::string(hex+i*2,2),nullptr,16));
    k.epoch.fill(0x33);k.id=id;return k;
}
struct Mapping {
    int fd;size_t size;void* data;
    explicit Mapping(const char* path) {
        fd=open(path,O_RDWR);if(fd<0)throw std::runtime_error("open mapped fixture failed");
        struct stat st{};fstat(fd,&st);size=st.st_size;
        data=mmap(nullptr,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(data==MAP_FAILED)throw std::runtime_error("mmap failed");
    }
    ~Mapping() { munmap(data,size);close(fd); }
};
static void put32(void* data,size_t offset,uint32_t value) { std::memcpy(static_cast<uint8_t*>(data)+offset,&value,4); }
static void put64(void* data,size_t offset,uint64_t value) { std::memcpy(static_cast<uint8_t*>(data)+offset,&value,8); }
static void await_file(const std::filesystem::path& path) {
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(12);
    while(!std::filesystem::exists(path)) {
        check(std::chrono::steady_clock::now()<deadline,"shared writer timed out");std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
static void signal_file(const std::filesystem::path& p) { std::ofstream file(p);file<<"go"; }
static void solid(const FrameView& view,uint64_t id) {
    for(size_t i=0;i<view.layer_bytes;i++)check(view.color[i]==uint8_t(id) && view.hud[i]==uint8_t(id),"torn color/HUD publication");
    for(size_t i=0;i<view.layer_bytes;i+=4) { float depth;std::memcpy(&depth,view.depth+i,4);check(depth==float(id)/1024.0f,"torn depth publication"); }
    check(view.pose.position.x==6.5 && view.pose.position.y==66 && view.pose.position.z==3,"pose offset mismatch");
    check(view.pose.view[0]==1 && view.pose.projection[15]==1,"matrix layout mismatch");
}
static void shared_process_contract() {
    char directory[]="/tmp/dstmc-axis-shared-XXXXXX";check(mkdtemp(directory)!=nullptr,"mkdtemp failed");
    auto dir=std::filesystem::absolute(directory);
    pid_t child=fork();check(child>=0,"fork failed");
    if(child==0) {
        const char* java=std::getenv("DSTMC_JAVA");
        execl("/usr/bin/arch","arch","-arm64",java,"-cp","../mc/build/classes/java/main:../mc/build/classes/java/contractTest","dev.jay.dstmc.ContractTests","--shared-writer",dir.c_str(),nullptr);
        _exit(127);
    }
    try {
        await_file(dir/"ready");
        {
            Mapping mapping((dir/"shared.bin").c_str());
            auto first=read_frame(mapping.data,mapping.size,key(100));auto second=read_frame(mapping.data,mapping.size,key(101));auto third=read_frame(mapping.data,mapping.size,key(102));
            check(first && second && third,"cannot lease initial three published slots");solid(*first,100);solid(*second,101);solid(*third,102);
            signal_file(dir/"all-leased");await_file(dir/"blocked");solid(*first,100);solid(*second,101);solid(*third,102);
            third.reset();signal_file(dir/"released");await_file(dir/"reused");
            solid(*first,100);solid(*second,101);auto reused=read_frame(mapping.data,mapping.size,key(103));check(reused.has_value(),"released slot was not republished");solid(*reused,103);
            first.reset();second.reset();reused.reset();signal_file(dir/"stress-go");
            for(uint64_t id=104;id<304;id++) {
                auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
                std::optional<FrameView> view;
                while(!(view=read_frame(mapping.data,mapping.size,key(id)))) { check(std::chrono::steady_clock::now()<deadline,"missing concurrent frame");std::this_thread::yield(); }
                solid(*view,id);view.reset();signal_file(dir/("ack-"+std::to_string(id)));
            }
        }
        int status;check(waitpid(child,&status,0)==child,"waitpid failed");child=-1;
        check(WIFEXITED(status) && WEXITSTATUS(status)==0,"ARM64 Java writer failed");
        std::filesystem::remove_all(dir);
    } catch(...) { if(child>0) {kill(child,SIGKILL);waitpid(child,nullptr,0);}std::filesystem::remove_all(dir);throw; }
}
int main(int argc,char** argv) {
    if(argc!=2) return 2;
    Mapping mapping(argv[1]);
    // Break caught: cross-language offset, identity, layer and matrix mismatches.
    test("java_fixture_is_readable",[&] {
        auto frame=read_frame(mapping.data,mapping.size,key());check(frame.has_value(),"Java mapped fixture was rejected");
        check(frame->width==2 && frame->height==2,"wrong physical size");
        check(frame->layer_bytes==16 && frame->color[0]==10 && frame->color[15]==255,"RGBA layer offset mismatch");
        float depth;std::memcpy(&depth,frame->depth,4);check(depth==0.25f,"float32 depth mismatch");
    });
    // Break caught: trusting length, sequence, dimensions, non-finite matrices or stale keys.
    auto reject=[&](const char* name,const std::function<void(void*)>& mutate) {
        test(name,[&] {std::vector<uint64_t> copy((mapping.size+7)/8);std::memcpy(copy.data(),mapping.data,mapping.size);mutate(copy.data());check(!read_frame(copy.data(),mapping.size,key()),"malformed frame accepted");});
    };
    test("reflected_frame_is_readable",[&] {
        std::vector<uint64_t> copy((mapping.size+7)/8);std::memcpy(copy.data(),mapping.data,mapping.size);
        double minus=-1;std::memcpy(reinterpret_cast<uint8_t*>(copy.data())+4096+176,&minus,8);
        auto f=read_frame(copy.data(),mapping.size,key());check(f.has_value() && f->axes[0]==-1,"supported reflected frame rejected");
    });
    reject("unsupported_reflection_rejected",[](void* p){double n=-1;std::memcpy(static_cast<uint8_t*>(p)+4096+176+4*8,&n,8);});
    reject("scaled_axes_rejected",[](void* p){double n=2;std::memcpy(static_cast<uint8_t*>(p)+4096+176,&n,8);});
    reject("nan_axes_rejected",[](void* p){double n=NAN;std::memcpy(static_cast<uint8_t*>(p)+4096+176,&n,8);});
    reject("sheared_axes_rejected",[](void* p){double n=.01;std::memcpy(static_cast<uint8_t*>(p)+4096+176+8,&n,8);});
    test("truncated_file_rejected",[&]{check(!read_frame(mapping.data,mapping.size-1,key()),"truncated file accepted");});
    reject("odd_sequence_rejected",[](void* p){put64(p,4096,3);});
    reject("oversize_rejected",[](void* p){put32(p,4096+72,0xffffffff);});
    reject("nan_matrix_rejected",[](void* p){put32(p,4096+320,0x7fc00000);});
    reject("layer_offset_rejected",[](void* p){put64(p,4096+104,UINT64_MAX);});
    reject("foreign_epoch_rejected",[](void* p){static_cast<uint8_t*>(p)[4096+48]=0x99;});
    reject("foreign_pair_rejected",[](void* p){static_cast<uint8_t*>(p)[4096+16]^=0xff;});
    reject("writer_lease_rejected",[](void* p){put64(p,4096+8,UINT64_MAX);});
    reject("oversize_stride_rejected",[](void* p){put64(p,32,UINT64_MAX);});
    test("mapped_atomic_publication_and_leases",shared_process_contract);
    std::cout<<"C++ x86_64 mapped Java fixture: "<<(failures?"FAIL":"PASS")<<'\n';
    return failures?1:0;
}
