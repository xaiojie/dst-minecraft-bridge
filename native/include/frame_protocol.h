#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <utility>

namespace dstmc {
static_assert(__atomic_always_lock_free(8,nullptr),"v2 requires lock-free aligned 64-bit atomics");
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error v2 native reader currently supports little-endian hosts only
#endif
struct FrameKey { std::array<uint8_t,32> pair_hash; std::array<uint8_t,16> epoch; uint64_t id; };
struct Vec3 { double x,y,z; };
struct FramePose {
    Vec3 position{},forward{},up{};
    std::array<float,16> view{},projection{}; // MC space, column-major.
};
/** Read-only data view; owns a shared slot lease. Mapping must outlive this object. */
struct FrameView {
    FrameKey key{};
    uint32_t width{},height{};
    const uint8_t *color{},*depth{},*hud{};
    uint64_t layer_bytes{},sequence{};
    Vec3 dst_origin{},mc_origin{};
    std::array<double,9> axes{};
    FramePose pose{};
    FrameView()=default;
    FrameView(const FrameView&)=delete;
    FrameView& operator=(const FrameView&)=delete;
    FrameView(FrameView&& other) noexcept { *this=std::move(other); }
    FrameView& operator=(FrameView&& other) noexcept {
        if(this!=&other) {
            release();key=other.key;width=other.width;height=other.height;color=other.color;depth=other.depth;hud=other.hud;
            layer_bytes=other.layer_bytes;sequence=other.sequence;dst_origin=other.dst_origin;mc_origin=other.mc_origin;axes=other.axes;pose=other.pose;
            lease_=std::exchange(other.lease_,nullptr);token_=std::exchange(other.token_,0);
        }
        return *this;
    }
    ~FrameView() { release(); }
private:
    uint64_t* lease_{};uint64_t token_{};
    void release() noexcept {
        if(lease_) { uint64_t expected=token_;__atomic_compare_exchange_n(lease_,&expected,0,false,__ATOMIC_RELEASE,__ATOMIC_RELAXED);lease_=nullptr; }
    }
    friend std::optional<FrameView> read_frame(const void*,size_t,FrameKey);
};
namespace detail {
template<typename T> inline T load(const uint8_t* p,size_t at) { T value;std::memcpy(&value,p+at,sizeof(value));return value; }
inline Vec3 vec(const uint8_t* p,size_t at) { return {load<double>(p,at),load<double>(p,at+8),load<double>(p,at+16)}; }
inline bool finite(Vec3 v) { return std::isfinite(v.x)&&std::isfinite(v.y)&&std::isfinite(v.z); }
}
/** Base must be 8-byte aligned, writable MAP_SHARED; only lease words are mutated. */
inline std::optional<FrameView> read_frame(const void* memory,size_t length,FrameKey expected) {
    using detail::load;
    if(!memory || reinterpret_cast<uintptr_t>(memory)%8 || length<4096) return std::nullopt;
    auto p=static_cast<const uint8_t*>(memory);
    if(std::memcmp(p,"DSTMCF2\0",8) || load<uint32_t>(p,8)!=2 || load<uint32_t>(p,12)!=4096 || load<uint32_t>(p,16)!=3 || load<uint32_t>(p,20)!=512) return std::nullopt;
    uint32_t capacity_w=load<uint32_t>(p,24),capacity_h=load<uint32_t>(p,28);
    if(!capacity_w || !capacity_h || capacity_w>1920 || capacity_h>1080) return std::nullopt;
    uint64_t stride=load<uint64_t>(p,32),total=load<uint64_t>(p,40);
    uint64_t expected_stride=(512+uint64_t(capacity_w)*capacity_h*12+63)&~uint64_t(63);
    if(stride!=expected_stride || total!=4096+stride*3 || total!=length) return std::nullopt;
    static std::atomic<uint64_t> tokens{1};
    for(unsigned i=0;i<3;i++) {
        auto slot=p+4096+i*stride;
        auto lease=reinterpret_cast<uint64_t*>(const_cast<uint8_t*>(slot)+8);
        uint64_t token=tokens.fetch_add(1,std::memory_order_relaxed);
        if(token==0 || token==UINT64_MAX) token=tokens.fetch_add(2,std::memory_order_relaxed)+1;
        uint64_t free=0;
        if(!__atomic_compare_exchange_n(lease,&free,token,false,__ATOMIC_ACQUIRE,__ATOMIC_RELAXED)) continue;
        FrameView view;view.lease_=lease;view.token_=token;
        auto seq=reinterpret_cast<const uint64_t*>(slot);
        view.sequence=__atomic_load_n(seq,__ATOMIC_ACQUIRE);
        if(!view.sequence || view.sequence%2) continue;
        if(std::memcmp(slot+16,expected.pair_hash.data(),32) || std::memcmp(slot+48,expected.epoch.data(),16) || load<uint64_t>(slot,64)!=expected.id) continue;
        view.width=load<uint32_t>(slot,72);view.height=load<uint32_t>(slot,76);
        if(!view.width || !view.height || view.width>capacity_w || view.height>capacity_h) continue;
        if(load<uint32_t>(slot,80)!=1 || load<uint32_t>(slot,84)!=2 || load<uint32_t>(slot,88)!=1 || load<uint32_t>(slot,92)!=0) continue;
        view.layer_bytes=uint64_t(view.width)*view.height*4;
        if(load<uint64_t>(slot,96)!=512 || load<uint64_t>(slot,104)!=512+view.layer_bytes || load<uint64_t>(slot,112)!=512+2*view.layer_bytes || load<uint64_t>(slot,120)!=view.layer_bytes || 512+3*view.layer_bytes>stride) continue;
        view.dst_origin=detail::vec(slot,128);view.mc_origin=detail::vec(slot,152);
        bool valid=detail::finite(view.dst_origin)&&detail::finite(view.mc_origin);
        for(unsigned j=0;j<9;j++) { view.axes[j]=load<double>(slot,176+j*8);valid &= std::isfinite(view.axes[j]); }
        // v2 first calibration has identity axes; do not silently accept an unsupported transform.
        for(unsigned j=0;j<9;j++) valid &= view.axes[j]==((j==0||j==4||j==8)?1.0:0.0);
        view.pose.position=detail::vec(slot,248);view.pose.forward=detail::vec(slot,272);view.pose.up=detail::vec(slot,296);
        valid &= detail::finite(view.pose.position)&&detail::finite(view.pose.forward)&&detail::finite(view.pose.up);
        for(unsigned j=0;j<16;j++) {
            view.pose.view[j]=load<float>(slot,320+j*4);view.pose.projection[j]=load<float>(slot,384+j*4);
            valid &= std::isfinite(view.pose.view[j])&&std::isfinite(view.pose.projection[j]);
        }
        if(!valid || __atomic_load_n(seq,__ATOMIC_ACQUIRE)!=view.sequence) continue;
        view.key=expected;view.color=slot+512;view.depth=view.color+view.layer_bytes;view.hud=view.depth+view.layer_bytes;
        return view;
    }
    return std::nullopt;
}
}
