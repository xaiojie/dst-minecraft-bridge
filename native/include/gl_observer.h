#pragma once
#include "frame_protocol.h"
#include <OpenGL/OpenGL.h>
#include <array>
#include <functional>
#include <string>
#include <vector>
namespace dstmc {
struct ShaderMatrix { std::string name; int location{}; std::array<float,16> value{}; };
struct ShaderSource { int type{}; std::string sha256; bool source_available{},contains_discard{},writes_frag_depth{}; };
struct RenderProbe {
    uint64_t frame_no{},context_id{},draw_no{};
    std::array<int,4> viewport{};
    std::array<float,16> projection{},modelview{}; // Fixed-function only; shader_matrices carry actual program state.
    bool depth_enabled{},depth_mask{},blend_enabled{},alpha_test{};
    std::array<double,2> depth_range{};
    std::array<int,6> blend_state{};
    int depth_func{},alpha_func{},target_id{},program{},depth_bits{};
    float alpha_ref{};
    std::vector<ShaderMatrix> shader_matrices;
    std::vector<ShaderSource> shader_sources;
    std::string program_fingerprint;
    std::string stage;
};
struct ProbeCapture { RenderProbe probe; std::vector<uint8_t> color; std::vector<float> depth; std::string error; };
RenderProbe inspect_draw(const char* stage);
void observe_draw(const RenderProbe&);
ProbeCapture capture_probe_frame();
void forget_context(CGLContextObj);
void begin_present();
void after_draw(const char* kind);
void configure_probe(const std::string& directory);
bool consume_frame(const void* mapping,size_t length,FrameKey expected,const std::function<void(const FrameView&)>& consumer);
}
