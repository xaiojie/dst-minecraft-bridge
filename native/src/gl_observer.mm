#include "gl_observer.h"
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <charconv>
#include <fstream>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace dstmc {
namespace {
struct Context {
    uint64_t id, frame = 0, draw = 0;
    bool sample = false;
    unsigned captures = 0;
    int last_program = -1, last_target = -1, last_depth = -1;
};

struct State {
    std::mutex mutex;
    std::map<CGLContextObj, Context> contexts;
    uint64_t next = 1;
    std::string directory;
    unsigned selected = 0;
    std::vector<uint64_t> checkpoints;
    bool explicit_checkpoints = false;
};

State& state() {
    static auto* s = new State;
    return *s;
}

Context& ctx() {
    auto& s = state();
    auto current = CGLGetCurrentContext();
    auto it = s.contexts.find(current);
    if (it == s.contexts.end()) {
        it = s.contexts.emplace(current, Context{s.next++}).first;
    }
    return it->second;
}

std::string quote(const std::string& text) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') {
            out << '\\' << c;
        } else if (c < 32) {
            out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                << int(c) << std::dec;
        } else {
            out << c;
        }
    }
    out << '"';
    return out.str();
}

std::string sha256(const std::string& text) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text.data(), (CC_LONG)text.size(), digest);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (auto byte : digest) out << std::setw(2) << int(byte);
    return out.str();
}

template<class T> void number(std::ostream& out, T value) {
    if (std::isfinite(double(value))) out << value;
    else out << "null";
}

template<class T, size_t N> void array(std::ostream& out, const std::array<T, N>& values) {
    out << '[';
    for (size_t i = 0; i < N; i++) {
        if (i) out << ',';
        number(out, values[i]);
    }
    out << ']';
}

std::string json(const RenderProbe& p) {
    std::ostringstream out;
    out << std::setprecision(9)
        << "{\"frame_no\":" << p.frame_no
        << ",\"context_id\":" << p.context_id
        << ",\"draw_no\":" << p.draw_no
        << ",\"stage\":" << quote(p.stage)
        << ",\"viewport\":";
    array(out, p.viewport);
    out << ",\"projection\":";
    array(out, p.projection);
    out << ",\"modelview\":";
    array(out, p.modelview);
    out << ",\"matrix_source\":\"fixed_function_plus_active_shader_uniforms\""
        << ",\"depth_enabled\":" << p.depth_enabled
        << ",\"depth_mask\":" << p.depth_mask
        << ",\"depth_func\":" << p.depth_func
        << ",\"depth_bits\":" << p.depth_bits
        << ",\"depth_range\":";
    array(out, p.depth_range);
    out << ",\"blend_enabled\":" << p.blend_enabled << ",\"blend_state\":";
    array(out, p.blend_state);
    out << ",\"alpha_test\":" << p.alpha_test
        << ",\"alpha_func\":" << p.alpha_func
        << ",\"alpha_ref\":";
    number(out, p.alpha_ref);
    out << ",\"target_id\":" << p.target_id
        << ",\"program\":" << p.program
        << ",\"shader_matrices\":[";
    for (size_t i = 0; i < p.shader_matrices.size(); i++) {
        if (i) out << ',';
        const auto& matrix = p.shader_matrices[i];
        out << "{\"name\":" << quote(matrix.name)
            << ",\"location\":" << matrix.location << ",\"value\":";
        array(out, matrix.value);
        out << '}';
    }
    out << "],\"program_fingerprint\":" << quote(p.program_fingerprint)
        << ",\"shader_sources\":[";
    for (size_t i = 0; i < p.shader_sources.size(); i++) {
        if (i) out << ',';
        const auto& shader = p.shader_sources[i];
        out << "{\"type\":" << shader.type
            << ",\"sha256\":" << quote(shader.sha256)
            << ",\"source_available\":" << shader.source_available
            << ",\"source_contains_discard_token\":" << shader.contains_discard
            << ",\"source_contains_gl_FragDepth\":" << shader.writes_frag_depth << '}';
    }
    out << "]}";
    return out.str();
}

void inspect_matrices(RenderProbe& p) {
    GLint count = 0, max_length = 0;
    glGetProgramiv(p.program, GL_ACTIVE_UNIFORMS, &count);
    glGetProgramiv(p.program, GL_ACTIVE_UNIFORM_MAX_LENGTH, &max_length);
    std::vector<char> name(std::max(1, max_length));
    for (GLint i = 0; i < count; i++) {
        GLsizei length;
        GLint size;
        GLenum type;
        glGetActiveUniform(p.program, i, name.size(), &length, &size, &type, name.data());
        if (type != GL_FLOAT_MAT4) continue;
        std::string base(name.data(), length);
        for (int j = 0; j < std::min(size, 128); j++) {
            std::string key = base;
            if (size > 1) {
                auto pos = key.find("[0]");
                if (pos != std::string::npos) {
                    key.replace(pos, 3, "[" + std::to_string(j) + "]");
                }
            }
            GLint location = glGetUniformLocation(p.program, key.c_str());
            if (location >= 0) {
                ShaderMatrix matrix;
                matrix.name = key;
                matrix.location = location;
                glGetUniformfv(p.program, location, matrix.value.data());
                p.shader_matrices.push_back(std::move(matrix));
            }
        }
    }
}

void inspect_sources(RenderProbe& p) {
    GLint count = 0;
    glGetProgramiv(p.program, GL_ATTACHED_SHADERS, &count);
    if (count <= 0 || count > 64) return;

    std::vector<GLuint> shaders(count);
    GLsizei actual = 0;
    glGetAttachedShaders(p.program, count, &actual, shaders.data());
    std::vector<std::string> fingerprints;
    bool complete = true;
    for (int i = 0; i < actual; i++) {
        ShaderSource info;
        GLint length = 0;
        glGetShaderiv(shaders[i], GL_SHADER_TYPE, &info.type);
        glGetShaderiv(shaders[i], GL_SHADER_SOURCE_LENGTH, &length);
        if (length > 1 && length <= 1024 * 1024) {
            std::string source(length, '\0');
            GLsizei written = 0;
            glGetShaderSource(shaders[i], length, &written, source.data());
            source.resize(written);
            info.source_available = !source.empty();
            if (info.source_available) {
                info.sha256 = sha256(source);
                info.contains_discard = source.find("discard") != std::string::npos;
                info.writes_frag_depth = source.find("gl_FragDepth") != std::string::npos;
                fingerprints.push_back(std::to_string(info.type) + ":" + info.sha256 + "\n");
            }
        }
        complete = complete && info.source_available;
        p.shader_sources.push_back(std::move(info));
    }
    if (complete && !fingerprints.empty()) {
        std::sort(fingerprints.begin(), fingerprints.end());
        std::string canonical;
        for (const auto& item : fingerprints) canonical += item;
        p.program_fingerprint = sha256(canonical);
    }
}

RenderProbe inspect(const char* stage) {
    RenderProbe p;
    if (!CGLGetCurrentContext()) {
        p.stage = "no-context";
        return p;
    }
    const auto& c = ctx();
    p.context_id = c.id;
    p.frame_no = c.frame;
    p.draw_no = c.draw;
    p.stage = stage;
    glGetIntegerv(GL_VIEWPORT, p.viewport.data());
    glGetFloatv(GL_PROJECTION_MATRIX, p.projection.data());
    glGetFloatv(GL_MODELVIEW_MATRIX, p.modelview.data());
    p.depth_enabled = glIsEnabled(GL_DEPTH_TEST);
    GLboolean mask;
    glGetBooleanv(GL_DEPTH_WRITEMASK, &mask);
    p.depth_mask = mask;
    glGetDoublev(GL_DEPTH_RANGE, p.depth_range.data());
    glGetIntegerv(GL_DEPTH_FUNC, &p.depth_func);
    glGetIntegerv(GL_DEPTH_BITS, &p.depth_bits);
    p.blend_enabled = glIsEnabled(GL_BLEND);
    GLenum blend_enums[] = {
        GL_BLEND_SRC_RGB, GL_BLEND_DST_RGB, GL_BLEND_SRC_ALPHA,
        GL_BLEND_DST_ALPHA, GL_BLEND_EQUATION_RGB, GL_BLEND_EQUATION_ALPHA
    };
    for (int i = 0; i < 6; i++) glGetIntegerv(blend_enums[i], &p.blend_state[i]);
    p.alpha_test = glIsEnabled(GL_ALPHA_TEST);
    glGetIntegerv(GL_ALPHA_TEST_FUNC, &p.alpha_func);
    glGetFloatv(GL_ALPHA_TEST_REF, &p.alpha_ref);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &p.target_id);
    glGetIntegerv(GL_CURRENT_PROGRAM, &p.program);
    if (p.program) {
        inspect_matrices(p);
        inspect_sources(p);
    }
    return p;
}

struct PackGuard {
    GLint buffer, alignment, row, rows, pixels, swap, lsb;
    PackGuard() {
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &buffer);
        glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
        glGetIntegerv(GL_PACK_ROW_LENGTH, &row);
        glGetIntegerv(GL_PACK_SKIP_ROWS, &rows);
        glGetIntegerv(GL_PACK_SKIP_PIXELS, &pixels);
        glGetIntegerv(GL_PACK_SWAP_BYTES, &swap);
        glGetIntegerv(GL_PACK_LSB_FIRST, &lsb);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glPixelStorei(GL_PACK_SKIP_ROWS, 0);
        glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
        glPixelStorei(GL_PACK_SWAP_BYTES, 0);
        glPixelStorei(GL_PACK_LSB_FIRST, 0);
    }
    ~PackGuard() {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, buffer);
        glPixelStorei(GL_PACK_ALIGNMENT, alignment);
        glPixelStorei(GL_PACK_ROW_LENGTH, row);
        glPixelStorei(GL_PACK_SKIP_ROWS, rows);
        glPixelStorei(GL_PACK_SKIP_PIXELS, pixels);
        glPixelStorei(GL_PACK_SWAP_BYTES, swap);
        glPixelStorei(GL_PACK_LSB_FIRST, lsb);
    }
};

ProbeCapture capture(const char* stage) {
    ProbeCapture result;
    result.probe = inspect(stage);
    const auto viewport = result.probe.viewport;
    if (!result.probe.context_id || viewport[2] <= 0 || viewport[3] <= 0 ||
        viewport[2] > 1920 || viewport[3] > 1080) {
        result.error = "unsupported_or_missing_physical_viewport";
        return result;
    }
    if (result.probe.target_id &&
        glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) {
        result.error = "incomplete_framebuffer";
        return result;
    }
    GLint read_buffer = 0;
    glGetIntegerv(GL_READ_BUFFER, &read_buffer);
    if (read_buffer == GL_NONE) {
        result.error = "disabled_read_buffer";
        return result;
    }
    GLint samples = 0;
    glGetIntegerv(GL_SAMPLES, &samples);
    if (result.probe.target_id && samples > 0) {
        result.error = "multisample_framebuffer_requires_resolve";
        return result;
    }
    PackGuard guard;
    size_t pixels = size_t(viewport[2]) * viewport[3];
    result.color.resize(pixels * 4);
    glReadPixels(viewport[0], viewport[1], viewport[2], viewport[3],
                 GL_RGBA, GL_UNSIGNED_BYTE, result.color.data());
    if (result.probe.depth_bits > 0) {
        result.depth.resize(pixels);
        glReadPixels(viewport[0], viewport[1], viewport[2], viewport[3],
                     GL_DEPTH_COMPONENT, GL_FLOAT, result.depth.data());
    } else {
        result.error = "no_depth_attachment";
    }
    return result;
}

void save(const char* stage) {
    auto& s = state();
    auto& c = ctx();
    if (s.directory.empty() || c.captures >= 8) return;
    c.captures++;
    auto captured = capture(stage);
    std::string base = "ctx" + std::to_string(c.id) + "-f" + std::to_string(c.frame) +
                       "-d" + std::to_string(c.draw);
    std::string path = s.directory + "/" + base;
    std::ofstream(path + ".rgba", std::ios::binary)
        .write((char*)captured.color.data(), captured.color.size());
    std::ofstream(path + ".depth.f32", std::ios::binary)
        .write((char*)captured.depth.data(), captured.depth.size() * 4);
    std::ofstream meta(path + ".json");
    meta << "{\"probe\":" << json(captured.probe)
         << ",\"color\":" << quote(base + ".rgba")
         << ",\"depth\":" << quote(base + ".depth.f32")
         << ",\"origin\":\"bottom-left\""
         << ",\"depth_encoding\":\"OpenGL_window_z_float32_little_endian\""
         << ",\"error\":" << quote(captured.error) << "}\n";
}

struct CaptureRequest {
    bool explicit_checkpoints = false;
    std::vector<uint64_t> checkpoints;
};

std::optional<CaptureRequest> parse_request(std::istream& input) {
    std::string mode;
    if (!(input >> mode)) return std::nullopt;

    CaptureRequest request;
    if (mode == "default" || mode == "metadata") {
        std::string extra;
        if (input >> extra || !input.eof()) return std::nullopt;
        request.explicit_checkpoints = mode == "metadata";
        return request;
    }
    if (mode != "checkpoints") return std::nullopt;

    request.explicit_checkpoints = true;
    std::string token;
    while (input >> token) {
        uint64_t draw = 0;
        const char* end = token.data() + token.size();
        const auto parsed = std::from_chars(token.data(), end, draw);
        if (parsed.ec != std::errc{} || parsed.ptr != end || draw == 0 ||
            draw > 20000 || request.checkpoints.size() == 7) {
            return std::nullopt;
        }
        request.checkpoints.push_back(draw);
    }
    if (!input.eof() || request.checkpoints.empty()) return std::nullopt;
    std::sort(request.checkpoints.begin(), request.checkpoints.end());
    if (std::adjacent_find(request.checkpoints.begin(), request.checkpoints.end()) !=
        request.checkpoints.end()) {
        return std::nullopt;
    }
    return request;
}
} // namespace

RenderProbe inspect_draw(const char* stage) {
    std::lock_guard<std::mutex> lock(state().mutex);
    return inspect(stage);
}

void observe_draw(const RenderProbe& p) {
    std::lock_guard<std::mutex> lock(state().mutex);
    if (!state().directory.empty()) {
        std::ofstream(state().directory + "/draws.jsonl", std::ios::app) << json(p) << '\n';
    }
}

ProbeCapture capture_probe_frame() {
    std::lock_guard<std::mutex> lock(state().mutex);
    return capture("explicit-capture");
}

void forget_context(CGLContextObj context) {
    std::lock_guard<std::mutex> lock(state().mutex);
    state().contexts.erase(context);
}

void configure_probe(const std::string& directory) {
    std::lock_guard<std::mutex> lock(state().mutex);
    state().directory = directory;
}

void after_draw(const char* kind) {
    if (!CGLGetCurrentContext()) return;
    std::lock_guard<std::mutex> lock(state().mutex);
    auto& s = state();
    auto& c = ctx();
    c.draw++;
    if (!c.sample || s.directory.empty() || c.draw > 20000) return;
    auto p = inspect(kind);
    std::ofstream(s.directory + "/draws.jsonl", std::ios::app) << json(p) << '\n';

    // Candidates are evidence checkpoints, never accepted world/UI classification.
    if (c.captures < 7) {
        if (s.explicit_checkpoints) {
            if (std::find(s.checkpoints.begin(), s.checkpoints.end(), c.draw) !=
                s.checkpoints.end()) {
                save("after-requested-draw");
            }
        } else if (p.target_id != c.last_target || int(p.depth_enabled) != c.last_depth ||
                   c.draw == 100 || c.draw == 300) {
            save("after-draw-state-transition");
        }
    }
    c.last_program = p.program;
    c.last_target = p.target_id;
    c.last_depth = p.depth_enabled;
}

void begin_present() {
    if (!CGLGetCurrentContext()) return;
    std::lock_guard<std::mutex> lock(state().mutex);
    auto& s = state();
    auto& c = ctx();
    if (c.sample) save("before-present");
    c.frame++;
    c.draw = 0;
    c.captures = 0;
    c.sample = false;
    c.last_program = c.last_target = c.last_depth = -1;
    if (s.directory.empty()) return;

    std::string path = s.directory + "/capture.request";
    if (access(path.c_str(), F_OK) == 0) {
        std::ifstream input(path);
        auto request = parse_request(input);
        unlink(path.c_str());
        s.selected = 0;
        s.checkpoints.clear();
        s.explicit_checkpoints = false;
        if (request) {
            s.explicit_checkpoints = request->explicit_checkpoints;
            s.checkpoints = std::move(request->checkpoints);
            s.selected = 2;
            unlink((s.directory + "/request-error.json").c_str());
        } else {
            std::ofstream(s.directory + "/request-error.json")
                << "{\"error\":\"invalid_capture_request\","
                   "\"modes\":[\"default\",\"metadata\",\"checkpoints\"],"
                   "\"checkpoint_constraints\":\"1_to_7_unique_draws_in_1_20000\"}\n";
        }
    }
    if (s.selected) {
        c.sample = true;
        s.selected--;
    }
    std::ofstream(s.directory + "/heartbeat.json.tmp")
        << "{\"pid\":" << getpid() << ",\"frame_no\":" << c.frame
        << ",\"context_id\":" << c.id << "}\n";
    rename((s.directory + "/heartbeat.json.tmp").c_str(),
           (s.directory + "/heartbeat.json").c_str());
}
} // namespace dstmc
