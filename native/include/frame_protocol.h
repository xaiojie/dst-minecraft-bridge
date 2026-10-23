#pragma once
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <utility>

#if defined(_MSC_VER)
#include <intrin.h>
#endif
namespace dstmc {
#if !defined(_MSC_VER)
static_assert(__atomic_always_lock_free(8,nullptr),"v2 requires lock-free aligned 64-bit atomics");
#endif
#if !defined(_WIN32) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error v2 native reader currently supports little-endian hosts only
#endif
// The ABI uses aligned shared 64-bit words, not process-local std::atomic objects.
// MSVC interlocked operations provide a full fence; GNU uses acquire/release.
inline bool compare_exchange64(uint64_t* p,uint64_t& expected,uint64_t desired) {
#if defined(_MSC_VER)
    auto prior=uint64_t(_InterlockedCompareExchange64(reinterpret_cast<volatile long long*>(p),static_cast<long long>(desired),static_cast<long long>(expected)));
    if(prior==expected)return true;expected=prior;return false;
#else
    return __atomic_compare_exchange_n(p,&expected,desired,false,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE);
#endif
}
inline uint64_t load64(const uint64_t* p) {
#if defined(_MSC_VER)
    return uint64_t(_InterlockedCompareExchange64(reinterpret_cast<volatile long long*>(const_cast<uint64_t*>(p)),0,0));
#else
    return __atomic_load_n(p,__ATOMIC_ACQUIRE);
#endif
}
struct FrameKey { std::array<uint8_t,32> pair_hash; std::array<uint8_t,16> epoch; uint64_t id; };
struct Vec3 { double x,y,z; };
struct FramePose {
    Vec3 position{},forward{},up{};
    std::array<float,16> view{},projection{}; // MC space, column-major.
};
struct WorldTransform {
    Vec3 dst_origin{}, mc_origin{};
    std::array<double,9> axes{};
};
inline bool supported_axes(const std::array<double,9>& a) {
    return (a[0]==1 || a[0]==-1) && a[1]==0 && a[2]==0 && a[3]==0 &&
           a[4]==1 && a[5]==0 && a[6]==0 && a[7]==0 && a[8]==1;
}
inline bool valid_transform(const WorldTransform& t) {
    return supported_axes(t.axes) && std::isfinite(t.dst_origin.x) && std::isfinite(t.dst_origin.y) &&
           std::isfinite(t.dst_origin.z) && std::isfinite(t.mc_origin.x) &&
           std::isfinite(t.mc_origin.y) && std::isfinite(t.mc_origin.z);
}
inline bool same_transform(const WorldTransform& a, const WorldTransform& b) {
    return valid_transform(a) && valid_transform(b) && a.axes==b.axes &&
           a.dst_origin.x==b.dst_origin.x && a.dst_origin.y==b.dst_origin.y && a.dst_origin.z==b.dst_origin.z &&
           a.mc_origin.x==b.mc_origin.x && a.mc_origin.y==b.mc_origin.y && a.mc_origin.z==b.mc_origin.z;
}
inline Vec3 direction_to_dst(const WorldTransform& t, Vec3 v) { return {t.axes[0]*v.x,v.y,v.z}; }
inline Vec3 position_to_dst(const WorldTransform& t, Vec3 p) {
    auto d=direction_to_dst(t,{p.x-t.mc_origin.x,p.y-t.mc_origin.y,p.z-t.mc_origin.z});
    return {d.x+t.dst_origin.x,d.y+t.dst_origin.y,d.z+t.dst_origin.z};
}
// V_dst = V_mc * [S, mcOrigin - S*dstOrigin]. This also preserves inverse-projected camera-space depth.
inline FramePose pose_to_dst(const WorldTransform& t, const FramePose& source) {
    auto p=source; p.position=position_to_dst(t,source.position);
    p.forward=direction_to_dst(t,source.forward); p.up=direction_to_dst(t,source.up);
    double offset[3]={t.mc_origin.x-t.axes[0]*t.dst_origin.x,t.mc_origin.y-t.dst_origin.y,t.mc_origin.z-t.dst_origin.z};
    for(int r=0;r<4;r++) {
        p.view[r]=float(source.view[r]*t.axes[0]);
        p.view[12+r]=float(source.view[12+r]+source.view[r]*offset[0]+source.view[4+r]*offset[1]+source.view[8+r]*offset[2]);
    }
    return p;
}
/** Read-only data view; owns a shared slot lease. Mapping must outlive this object. */
struct FrameView : WorldTransform {
    FrameKey key{};
    uint32_t width{},height{};
    const uint8_t *color{},*depth{},*hud{};
    uint64_t layer_bytes{},sequence{};
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
        if(lease_) { uint64_t expected=token_;compare_exchange64(lease_,expected,0);lease_=nullptr; }
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
        if(!compare_exchange64(lease,free,token)) continue;
        FrameView view;view.lease_=lease;view.token_=token;
        auto seq=reinterpret_cast<const uint64_t*>(slot);
        view.sequence=load64(seq);
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
        valid &= valid_transform(view);
        view.pose.position=detail::vec(slot,248);view.pose.forward=detail::vec(slot,272);view.pose.up=detail::vec(slot,296);
        valid &= detail::finite(view.pose.position)&&detail::finite(view.pose.forward)&&detail::finite(view.pose.up);
        for(unsigned j=0;j<16;j++) {
            view.pose.view[j]=load<float>(slot,320+j*4);view.pose.projection[j]=load<float>(slot,384+j*4);
            valid &= std::isfinite(view.pose.view[j])&&std::isfinite(view.pose.projection[j]);
        }
        if(!valid || load64(seq)!=view.sequence) continue;
        view.key=expected;view.color=slot+512;view.depth=view.color+view.layer_bytes;view.hud=view.depth+view.layer_bytes;
        return view;
    }
    return std::nullopt;
}
}
