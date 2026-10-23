#include "backend.h"
#include "depth_replay.h"
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <MinHook.h>
#include <cstring>
#include <functional>
#include <memory>
#include <unordered_map>
#include <vector>
namespace winbridge {
namespace {
HMODULE gles{}, egl{};
// clang-format off
#define GL_FUNCTIONS(X) \
 X(glGetString) \
 X(glGetIntegerv) \
 X(glGetBooleanv) \
 X(glGetFloatv) \
 X(glIsEnabled) \
 X(glEnable) \
 X(glDisable) \
 X(glGetError) \
 X(glActiveTexture) \
 X(glBindTexture) \
 X(glGenTextures) \
 X(glDeleteTextures) \
 X(glTexImage2D) \
 X(glTexParameteri) \
 X(glPixelStorei) \
 X(glBindFramebuffer) \
 X(glGenFramebuffers) \
 X(glDeleteFramebuffers) \
 X(glFramebufferTexture2D) \
 X(glCheckFramebufferStatus) \
 X(glUseProgram) \
 X(glGetUniformLocation) \
 X(glGetUniformfv) \
 X(glGetUniformiv) \
 X(glGetActiveUniform) \
 X(glGetFramebufferAttachmentParameteriv) \
 X(glUniform1i) \
 X(glUniformMatrix4fv) \
 X(glCreateShader) \
 X(glShaderSource) \
 X(glCompileShader) \
 X(glGetShaderiv) \
 X(glGetShaderInfoLog) \
 X(glDeleteShader) \
 X(glCreateProgram) \
 X(glAttachShader) \
 X(glLinkProgram) \
 X(glGetProgramiv) \
 X(glGetProgramInfoLog) \
 X(glDeleteProgram) \
 X(glBindAttribLocation) \
 X(glGetAttachedShaders) \
 X(glGetShaderSource) \
 X(glBindBuffer) \
 X(glGenBuffers) \
 X(glDeleteBuffers) \
 X(glBufferData) \
 X(glGetVertexAttribiv) \
 X(glGetVertexAttribPointerv) \
 X(glVertexAttribPointer) \
 X(glEnableVertexAttribArray) \
 X(glDisableVertexAttribArray) \
 X(glViewport) \
 X(glColorMask) \
 X(glDepthMask) \
 X(glDepthFunc) \
 X(glDepthRangef) \
 X(glClearDepthf) \
 X(glClear) \
 X(glBlendFuncSeparate) \
 X(glBlendEquationSeparate)
// clang-format on
#define DECLARE(name) decltype(&::name) name{};
GL_FUNCTIONS(DECLARE)
#undef DECLARE
using DrawElements = void(GL_APIENTRY *)(GLenum, GLsizei, GLenum, const void *);
using DrawArrays = void(GL_APIENTRY *)(GLenum, GLint, GLsizei);
using Blit = void(GL_APIENTRY *)(GLint, GLint, GLint, GLint, GLint, GLint,
                                 GLint, GLint, GLbitfield, GLenum);
Blit original_blit_angle{}, original_blit_core{};
constexpr GLenum READ_FRAMEBUFFER = 0x8CA8, DRAW_FRAMEBUFFER = 0x8CA9,
                 READ_FRAMEBUFFER_BINDING = 0x8CAA;
decltype(&::eglGetProcAddress) get_proc{};
DrawElements original_elements{};
DrawArrays original_arrays{};
decltype(&::eglSwapBuffers) original_swap{};
decltype(&::eglMakeCurrent) original_current{};
decltype(&::eglDestroyContext) original_destroy{};
decltype(&::eglCreateWindowSurface) original_create_surface{};
decltype(&::eglDestroySurface) original_destroy_surface{};
std::mutex surfaces_mutex;
std::unordered_map<EGLSurface, HWND> surfaces;
decltype(&::eglGetCurrentContext) current_context{};
decltype(&::eglQuerySurface) query_surface{};
decltype(&::eglGetError) egl_error{};
thread_local bool inside = false;
struct Guard {
  Guard() { inside = true; }
  ~Guard() { inside = false; }
};
void diagnostic(const std::string &why) {
  static thread_local std::string last;
  static thread_local uint64_t time = 0;
  if (why != last || now() - time > 2000) {
    last = why;
    time = now();
    log("render_gate", why);
  }
}
bool extension(const char *all, const char *name) {
  if (!all)
    return false;
  std::string s = " " + std::string(all) + " ";
  return s.find(" " + std::string(name) + " ") != std::string::npos;
}
bool separate_framebuffers() {
  const char *e = reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
  return extension(e, "GL_ANGLE_framebuffer_blit") ||
         extension(e, "GL_NV_framebuffer_blit");
}
struct State {
  bool separate = separate_framebuffers();
  GLint read_fbo = 0;
  GLint program, fbo, active, textures[3], array, unpack, viewport[4],
      depth_func, src_rgb, dst_rgb, src_alpha, dst_alpha, eq_rgb, eq_alpha;
  GLint attr_enabled, attr_size, attr_type, attr_normalized, attr_stride,
      attr_buffer;
  void *attr_pointer{};
  GLboolean mask[4], depth_mask;
  GLfloat range[2], clear_depth;
  const GLenum flags[8] = {GL_DEPTH_TEST,
                           GL_BLEND,
                           GL_SCISSOR_TEST,
                           GL_STENCIL_TEST,
                           GL_CULL_FACE,
                           GL_POLYGON_OFFSET_FILL,
                           GL_SAMPLE_ALPHA_TO_COVERAGE,
                           GL_SAMPLE_COVERAGE};
  bool enabled[8];
  State() {
    glGetIntegerv(GL_CURRENT_PROGRAM, &program);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    if (separate)
      glGetIntegerv(READ_FRAMEBUFFER_BINDING, &read_fbo);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    for (int i = 0; i < 3; i++) {
      glActiveTexture(GL_TEXTURE0 + i);
      glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]);
    }
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &array);
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack);
    glGetIntegerv(GL_VIEWPORT, viewport);
    glGetIntegerv(GL_DEPTH_FUNC, &depth_func);
    glGetIntegerv(GL_BLEND_SRC_RGB, &src_rgb);
    glGetIntegerv(GL_BLEND_DST_RGB, &dst_rgb);
    glGetIntegerv(GL_BLEND_SRC_ALPHA, &src_alpha);
    glGetIntegerv(GL_BLEND_DST_ALPHA, &dst_alpha);
    glGetIntegerv(GL_BLEND_EQUATION_RGB, &eq_rgb);
    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &eq_alpha);
    glGetBooleanv(GL_COLOR_WRITEMASK, mask);
    glGetBooleanv(GL_DEPTH_WRITEMASK, &depth_mask);
    glGetFloatv(GL_DEPTH_RANGE, range);
    glGetFloatv(GL_DEPTH_CLEAR_VALUE, &clear_depth);
    for (int i = 0; i < 8; i++)
      enabled[i] = glIsEnabled(flags[i]);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &attr_enabled);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &attr_size);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &attr_type);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &attr_normalized);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &attr_stride);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &attr_buffer);
    glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &attr_pointer);
    glActiveTexture(active);
  }
  void restore_samplers() {
    for (int i = 0; i < 3; i++) {
      glActiveTexture(GL_TEXTURE0 + i);
      glBindTexture(GL_TEXTURE_2D, textures[i]);
    }
    glActiveTexture(active);
  }
  ~State() {
    if (separate) {
      glBindFramebuffer(DRAW_FRAMEBUFFER, fbo);
      glBindFramebuffer(READ_FRAMEBUFFER, read_fbo);
    } else
      glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glUseProgram(program);
    restore_samplers();
    glBindBuffer(GL_ARRAY_BUFFER, attr_buffer);
    glVertexAttribPointer(0, attr_size, attr_type, attr_normalized, attr_stride,
                          attr_pointer);
    if (attr_enabled)
      glEnableVertexAttribArray(0);
    else
      glDisableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, array);
    glPixelStorei(GL_UNPACK_ALIGNMENT, unpack);
    glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    glDepthFunc(depth_func);
    glDepthMask(depth_mask);
    glDepthRangef(range[0], range[1]);
    glClearDepthf(clear_depth);
    glColorMask(mask[0], mask[1], mask[2], mask[3]);
    glBlendFuncSeparate(src_rgb, dst_rgb, src_alpha, dst_alpha);
    glBlendEquationSeparate(eq_rgb, eq_alpha);
    for (int i = 0; i < 8; i++) {
      if (enabled[i])
        glEnable(flags[i]);
      else
        glDisable(flags[i]);
    }
  }
};
GLuint shader(GLenum type, const char *source) {
  auto s = glCreateShader(type);
  glShaderSource(s, 1, &source, nullptr);
  glCompileShader(s);
  GLint ok;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char error[2048]{};
    glGetShaderInfoLog(s, sizeof(error), nullptr, error);
    glDeleteShader(s);
    throw std::runtime_error(std::string("shader compile: ") + error);
  }
  return s;
}
GLuint program(const char *source) {
  GLuint v = shader(
             GL_VERTEX_SHADER,
             "attribute vec2 position;varying vec2 uv;void "
             "main(){uv=position*.5+.5;gl_Position=vec4(position,0.,1.);}"),
         f = 0, p = 0;
  try {
    f = shader(GL_FRAGMENT_SHADER, source);
    p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glBindAttribLocation(p, 0, "position");
    glLinkProgram(p);
    GLint ok;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
      char error[2048]{};
      glGetProgramInfoLog(p, sizeof(error), nullptr, error);
      throw std::runtime_error(std::string("program link: ") + error);
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return p;
  } catch (...) {
    glDeleteShader(v);
    if (f)
      glDeleteShader(f);
    if (p)
      glDeleteProgram(p);
    throw;
  }
}
const char *fragment = R"GLSL(#extension GL_EXT_frag_depth : require
precision highp float;
varying vec2 uv;uniform sampler2D mcColor,mcDepth,hostDepth;uniform mat4 inverseMC,inverseHost,hostProjection;
void main(){vec4 color=texture2D(mcColor,uv);if(color.a<=0.)discard;
float md=texture2D(mcDepth,uv).r,hd=texture2D(hostDepth,uv).r;if(md>=1.||md<0.)discard;
vec4 m=inverseMC*vec4(uv*2.-1.,md*2.-1.,1.);vec4 h=inverseHost*vec4(uv*2.-1.,hd*2.-1.,1.);
if(abs(m.w)<.000001||abs(h.w)<.000001)discard;float mz=-m.z/m.w,hz=-h.z/h.w;if(mz<=0.||(hd<1.&&mz>=hz))discard;
vec4 clip=hostProjection*vec4(m.xyz/m.w,1.);gl_FragDepthEXT=clamp(clip.z/clip.w*.5+.5,0.,1.);gl_FragColor=color;})GLSL";
struct Context {
  bool checked = false, supported = false, world = false, failed = false,
       world_done = false;
  GLint target = 0;
  int width = 0, height = 0;
  GLuint fbo = 0, depth = 0, color = 0, compose = 0, hud = 0, vbo = 0,
         upload[3]{};
  dstmc::FrameKey frame{};
  std::array<float, 16> projection{};
  void reset() {
    world = false;
    failed = false;
    world_done = false;
    target = 0;
  }
  bool capabilities() {
    if (checked)
      return supported;
    checked = true;
    auto version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
    auto extensions =
        reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
    log("capabilities", std::string(version ? version : "no current GL") +
                            "; " + (extensions ? extensions : ""));
    // ES3 has additional indexed/VAO/PBO state. Do not mutate an unprofiled
    // API.
    if (!version ||
        std::string(version).find("OpenGL ES 2.") == std::string::npos) {
      diagnostic(
          "requires verified GLES2 context; GLES3 state path unsupported");
      return false;
    }
    if (!extension(extensions, "GL_OES_depth_texture") &&
        !extension(extensions, "GL_ANGLE_depth_texture")) {
      diagnostic("missing capability OES/ANGLE_depth_texture");
      return false;
    }
    for (auto name : {"GL_OES_texture_float", "GL_EXT_frag_depth"})
      if (!extension(extensions, name)) {
        diagnostic(std::string("missing capability ") + name);
        return false;
      }
    supported = true;
    return true;
  }
  void dispose() {
    glDeleteTextures(1, &depth);
    glDeleteTextures(1, &color);
    glDeleteTextures(3, upload);
    glDeleteFramebuffers(1, &fbo);
    glDeleteBuffers(1, &vbo);
    if (compose)
      glDeleteProgram(compose);
    if (hud)
      glDeleteProgram(hud);
    depth = color = fbo = vbo = compose = hud = 0;
    for (auto &t : upload)
      t = 0;
  }
  bool allocate(int w, int h) {
    if (width == w && height == h && fbo)
      return true;
    if (w <= 0 || h <= 0 || w > 1920 || h > 1080)
      return false;
    glDeleteTextures(1, &depth);
    glDeleteTextures(1, &color);
    glDeleteFramebuffers(1, &fbo);
    glGenTextures(1, &depth);
    glGenTextures(1, &color);
    glActiveTexture(GL_TEXTURE0);
    for (auto t : {depth, color}) {
      glBindTexture(GL_TEXTURE_2D, t);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      if (t == depth)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, w, h, 0,
                     GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nullptr);
      else
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, nullptr);
    }
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
                           depth, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           color, 0);
    width = w;
    height = h;
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  }
};
std::mutex contexts_mutex;
std::unordered_map<EGLContext, std::unique_ptr<Context>> contexts;
Context &context() {
  auto id = current_context();
  std::lock_guard<std::mutex> lock(contexts_mutex);
  auto &p = contexts[id];
  if (!p)
    p = std::make_unique<Context>();
  return *p;
}
bool matrices(GLuint p, const dstmc::FrameView &f,
              std::array<float, 16> &projection) {
  auto vloc = glGetUniformLocation(p, "MatrixV"),
       ploc = glGetUniformLocation(p, "MatrixP");
  if (vloc < 0 || ploc < 0)
    return false;
  std::array<float, 16> view{};
  glGetUniformfv(p, vloc, view.data());
  glGetUniformfv(p, ploc, projection.data());
  return camera_matches(f, view, projection, int(f.width), int(f.height));
}
bool safe_fragment(GLuint p) {
  GLint n = 0;
  glGetProgramiv(p, GL_ATTACHED_SHADERS, &n);
  if (n < 1 || n > 16)
    return false;
  std::vector<GLuint> ids(n);
  glGetAttachedShaders(p, n, &n, ids.data());
  for (auto id : ids) {
    GLint type = 0, len = 0;
    glGetShaderiv(id, GL_SHADER_TYPE, &type);
    if (type != GL_FRAGMENT_SHADER)
      continue;
    glGetShaderiv(id, GL_SHADER_SOURCE_LENGTH, &len);
    if (len < 1 || len > 262144)
      return false;
    std::string source(size_t(len), '\0');
    glGetShaderSource(id, len, nullptr, source.data());
    if (source.find("gl_FragDepth") != std::string::npos)
      return false;
    if (glIsEnabled(GL_BLEND) && source.find("discard") == std::string::npos)
      return false;
    return true;
  }
  return false;
}
void observe(const std::function<void()> &replay) {
  if (shared().stop || !shared().input_mc ||
      current_context() == EGL_NO_CONTEXT)
    return;
  auto &s = shared();
  dstmc::FrameKey key;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.session)
      return;
    key = s.key;
  }
  auto f = s.service.pinned(key);
  if (!f)
    return;
  auto &c = context();
  if (!c.capabilities())
    return;
  GLint p = 0, target = 0, viewport[4];
  glGetIntegerv(GL_CURRENT_PROGRAM, &p);
  if (!p)
    return;
  std::array<float, 16> projection{};
  if (!matrices(p, *f, projection))
    return;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &target);
  glGetIntegerv(GL_VIEWPORT, viewport);
  GLfloat range[2];
  glGetFloatv(GL_DEPTH_RANGE, range);
  if (viewport[0] || viewport[1] || viewport[2] != int(f->width) ||
      viewport[3] != int(f->height) || range[0] != 0 || range[1] != 1) {
    c.failed = true;
    diagnostic("world target/viewport/depth range unsupported");
    return;
  }
  if (c.world_done) {
    c.failed = true;
    diagnostic("world draw appeared after resolve composition");
    return;
  }
  if (!safe_fragment(p)) {
    c.failed = true;
    diagnostic(
        "world shader missing verified alpha discard or writes custom depth");
    return;
  }
  if (c.world && (!dstmc::same_key(c.frame,key) || c.projection!=projection || c.target!=target)) {
    c.failed=true;return;
  }
  State state;
  struct ReplayApi {
    State &state;Context &context;int width,height;
    bool stencil_enabled(){return glIsEnabled(GL_STENCIL_TEST);}
    bool scissor_enabled(){return glIsEnabled(GL_SCISSOR_TEST);}
    void scissor(bool enabled){if(enabled)glEnable(GL_SCISSOR_TEST);else glDisable(GL_SCISSOR_TEST);}
    bool allocate(){return context.allocate(width,height);}
    void restore_samplers(){state.restore_samplers();}
    void bind_depth_target(){glBindFramebuffer(GL_FRAMEBUFFER,context.fbo);}
    void configure_depth(){
      glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);glEnable(GL_DEPTH_TEST);
      glDepthMask(GL_TRUE);glDepthFunc(GL_LESS);glDisable(GL_BLEND);
    }
    void clear_depth(){glClearDepthf(1);glClear(GL_DEPTH_BUFFER_BIT);}
  } api{state,c,viewport[2],viewport[3]};
  const auto result=capture_depth(api,!c.world,replay);
  if(result!=ReplayResult::CAPTURED){
    c.failed=true;
    diagnostic(result==ReplayResult::STENCIL_UNSUPPORTED
      ? "world stencil mask cannot be reproduced in supplemental depth"
      : "supplemental depth framebuffer incomplete");
    return;
  }
  if(!c.world){c.target=target;c.frame=key;c.projection=projection;}
  if (glGetError() != GL_NO_ERROR) {
    c.failed = true;
    diagnostic("world depth replay GL error");
  } else
    c.world = true;
}
std::optional<dstmc::FrameKey> compose_world(Context &, int, int);
bool samples_world_target(Context &c) {
  if (c.target == 0)
    return false;
  State restore;
  GLint p = 0, kind = 0, texture = 0;
  glGetIntegerv(GL_CURRENT_PROGRAM, &p);
  if (!p)
    return false;
  glBindFramebuffer(GL_FRAMEBUFFER, c.target);
  glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE,
                                        &kind);
  if (kind != GL_TEXTURE)
    return false;
  glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                        GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
                                        &texture);
  GLint count = 0, max_units = 0;
  glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &count);
  glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &max_units);
  if (count < 0 || count > 1024)
    return false;
  for (GLint i = 0; i < count; i++) {
    char name[256]{};
    GLint size = 0;
    GLenum type = 0;
    GLsizei length = 0;
    glGetActiveUniform(p, GLuint(i), sizeof(name), &length, &size, &type, name);
    if (type != GL_SAMPLER_2D || size != 1 || length <= 0 || length >= 255)
      continue;
    GLint unit = -1;
    glGetUniformiv(p, glGetUniformLocation(p, name), &unit);
    if (unit < 0 || unit >= max_units)
      continue;
    glActiveTexture(GL_TEXTURE0 + unit);
    GLint bound = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
    if (bound == texture)
      return true;
  }
  return false;
}
void before_draw() {
  if (shared().stop || current_context() == EGL_NO_CONTEXT)
    return;
  auto &c = context();
  GLint target = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &target);
  if (compose_before_target_draw(c.world, c.world_done, c.failed, c.target,
                                 target)) {
    // A changed target alone is not evidence of a resolve. Verify that this
    // draw actually samples the captured world's color texture.
    if (!samples_world_target(c))
      return;
    if (!compose_world(c, c.width, c.height)) {
      c.failed = true;
      diagnostic("world composition before resolve failed");
    }
  }
}
void before_blit(GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0,
                 GLint dy0, GLint dx1, GLint dy1, GLbitfield mask) {
  if (shared().stop || current_context() == EGL_NO_CONTEXT)
    return;
  auto &c = context();
  if (!separate_framebuffers())
    return;
  GLint read = 0, draw = 0;
  glGetIntegerv(READ_FRAMEBUFFER_BINDING, &read);
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &draw);
  if (!compose_before_blit(c.world, c.world_done, c.failed, c.target, read,
                           draw, mask))
    return;
  // A partial/flipped resolve cannot establish the same rays/pixel geometry.
  if (sx0 || sy0 || dx0 || dy0 || sx1 != c.width || sy1 != c.height ||
      dx1 != c.width || dy1 != c.height) {
    c.failed = true;
    diagnostic("partial or scaled world blit unsupported");
    return;
  }
  if (!compose_world(c, c.width, c.height)) {
    c.failed = true;
    diagnostic("world composition before framebuffer blit failed");
  }
}
void dispatch_blit(Blit original, GLint sx0, GLint sy0, GLint sx1, GLint sy1,
                   GLint dx0, GLint dy0, GLint dx1, GLint dy1, GLbitfield mask,
                   GLenum filter) {
  if (inside) {
    original(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
    return;
  }
  Guard guard;
  try {
    before_blit(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask);
  } catch (const std::exception &e) {
    diagnostic(e.what());
    context().failed = true;
  }
  original(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}
void GL_APIENTRY blit_angle(GLint a, GLint b, GLint c, GLint d, GLint e,
                            GLint f, GLint g, GLint h, GLbitfield mask,
                            GLenum filter) {
  dispatch_blit(original_blit_angle, a, b, c, d, e, f, g, h, mask, filter);
}
void GL_APIENTRY blit_core(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f,
                           GLint g, GLint h, GLbitfield mask, GLenum filter) {
  dispatch_blit(original_blit_core, a, b, c, d, e, f, g, h, mask, filter);
}
void GL_APIENTRY draw_elements(GLenum mode, GLsizei count, GLenum type,
                               const void *indices) {
  if (inside) {
    original_elements(mode, count, type, indices);
    return;
  }
  Guard guard;
  try {
    before_draw();
  } catch (const std::exception &e) {
    diagnostic(e.what());
    context().failed = true;
  }
  original_elements(mode, count, type, indices);
  try {
    observe([&] { original_elements(mode, count, type, indices); });
  } catch (const std::exception &e) {
    diagnostic(e.what());
    context().failed = true;
  }
}
void GL_APIENTRY draw_arrays(GLenum mode, GLint first, GLsizei count) {
  if (inside) {
    original_arrays(mode, first, count);
    return;
  }
  Guard guard;
  try {
    before_draw();
  } catch (const std::exception &e) {
    diagnostic(e.what());
    context().failed = true;
  }
  original_arrays(mode, first, count);
  try {
    observe([&] { original_arrays(mode, first, count); });
  } catch (const std::exception &e) {
    diagnostic(e.what());
    context().failed = true;
  }
}
void upload(GLuint t, int unit, int w, int h, GLenum format, GLenum type,
            const void *data) {
  glActiveTexture(GL_TEXTURE0 + unit);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, format, w, h, 0, format, type, data);
}
void quad(Context &c) {
  if (!c.vbo) {
    float v[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    glGenBuffers(1, &c.vbo);
    glBindBuffer(GL_ARRAY_BUFFER, c.vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STATIC_DRAW);
  } else
    glBindBuffer(GL_ARRAY_BUFFER, c.vbo);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
  original_arrays(GL_TRIANGLE_STRIP, 0, 4);
}
std::optional<dstmc::FrameKey> compose_world(Context &c, int w, int h) {
  auto &s = shared();
  if (s.stop || !s.input_mc || !c.world || c.failed || w != c.width ||
      h != c.height)
    return {};
  auto frame = s.service.pinned(c.frame);
  if (!frame) {
    diagnostic("composition lease expired");
    return {};
  }
  std::array<float, 16> mc{}, host{};
  if (!inverse(frame->pose.projection, mc) || !inverse(c.projection, host))
    return {};
  State state;
  glBindFramebuffer(GL_FRAMEBUFFER, c.target);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
    return {};
  glViewport(0, 0, w, h);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  if (!c.compose)
    c.compose = program(fragment);
  if (!c.hud)
    c.hud = program("precision mediump float;varying vec2 uv;uniform sampler2D "
                    "color;void main(){gl_FragColor=texture2D(color,uv);}");
  if (!c.upload[0])
    glGenTextures(3, c.upload);
  glUseProgram(c.compose);
  upload(c.upload[0], 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, frame->color);
  upload(c.upload[1], 1, w, h, GL_LUMINANCE, GL_FLOAT, frame->depth);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, c.depth);
  glUniform1i(glGetUniformLocation(c.compose, "mcColor"), 0);
  glUniform1i(glGetUniformLocation(c.compose, "mcDepth"), 1);
  glUniform1i(glGetUniformLocation(c.compose, "hostDepth"), 2);
  glUniformMatrix4fv(glGetUniformLocation(c.compose, "inverseMC"), 1, GL_FALSE,
                     mc.data());
  glUniformMatrix4fv(glGetUniformLocation(c.compose, "inverseHost"), 1,
                     GL_FALSE, host.data());
  glUniformMatrix4fv(glGetUniformLocation(c.compose, "hostProjection"), 1,
                     GL_FALSE, c.projection.data());
  for (auto cap : {GL_DEPTH_TEST, GL_SCISSOR_TEST, GL_STENCIL_TEST,
                   GL_CULL_FACE, GL_POLYGON_OFFSET_FILL,
                   GL_SAMPLE_ALPHA_TO_COVERAGE, GL_SAMPLE_COVERAGE})
    glDisable(cap);
  glDepthMask(GL_FALSE);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glEnable(GL_BLEND);
  glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
  glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE,
                      GL_ONE_MINUS_SRC_ALPHA);
  quad(c);
  if (glGetError() != GL_NO_ERROR) {
    diagnostic("world composition GL error; proof withheld");
    return {};
  }
  c.world_done = true;
  return c.frame;
}
std::optional<dstmc::FrameKey> compose_hud(Context &c, int w, int h) {
  if (shared().stop || !shared().input_mc || c.failed || !c.world ||
      w != c.width || h != c.height)
    return {};
  if (!c.world_done && c.target != 0) {
    diagnostic("offscreen world has no observed resolve draw; proof withheld");
    return {};
  }
  if (!c.world_done && !compose_world(c, w, h))
    return {};
  auto frame = shared().service.pinned(c.frame);
  if (!frame)
    return {};
  State state;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, w, h);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  for (auto cap : {GL_DEPTH_TEST, GL_SCISSOR_TEST, GL_STENCIL_TEST,
                   GL_CULL_FACE, GL_POLYGON_OFFSET_FILL,
                   GL_SAMPLE_ALPHA_TO_COVERAGE, GL_SAMPLE_COVERAGE})
    glDisable(cap);
  glDepthMask(GL_FALSE);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glEnable(GL_BLEND);
  glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
  glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE,
                      GL_ONE_MINUS_SRC_ALPHA);
  glUseProgram(c.hud);
  upload(c.upload[2], 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, frame->hud);
  glUniform1i(glGetUniformLocation(c.hud, "color"), 0);
  quad(c);
  if (glGetError() != GL_NO_ERROR) {
    diagnostic("HUD composition GL error; proof withheld");
    return {};
  }
  return c.frame;
}
struct WindowSearch {
  int width, height;
  HWND window{};
  unsigned count = 0;
};
BOOL CALLBACK find_window(HWND w, LPARAM p) {
  auto &search = *reinterpret_cast<WindowSearch *>(p);
  DWORD process = 0;
  RECT rect{};
  GetWindowThreadProcessId(w, &process);
  if (process == GetCurrentProcessId() && IsWindowVisible(w) &&
      GetWindow(w, GW_OWNER) == nullptr && GetClientRect(w, &rect) &&
      rect.right == search.width && rect.bottom == search.height) {
    search.window = w;
    search.count++;
  }
  return TRUE;
}
std::atomic<WNDPROC> old_proc{};
std::atomic<HWND> hooked_window{};
LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  auto &s = shared();
  if (message == WM_KEYDOWN && wp == VK_F8 && !(lp & (1ll << 30))) {
    std::lock_guard<std::mutex> lock(s.mutex);
    s.input_mc = !s.input_mc.load();
    s.input_version++;
    s.proof.clear();
    return 0;
  }
  if (message == WM_KEYUP || message == WM_SYSKEYUP ||
      message == WM_LBUTTONUP || message == WM_RBUTTONUP ||
      message == WM_MBUTTONUP || message == WM_XBUTTONUP)
    return CallWindowProcW(old_proc, window, message, wp, lp);
  bool suppress = false;
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    suppress = !s.stop && s.input_mc && s.proof.accepts(s.key, now());
  }
  if (suppress && ((message >= WM_KEYFIRST && message <= WM_KEYLAST) ||
                   (message >= WM_MOUSEFIRST && message <= WM_MOUSELAST) ||
                   message == WM_INPUT))
    return message == WM_INPUT ? DefWindowProcW(window, message, wp, lp) : 0;
  return CallWindowProcW(old_proc, window, message, wp, lp);
}
EGLBoolean EGLAPIENTRY swap(EGLDisplay display, EGLSurface surface) {
  if (inside)
    return original_swap(display, surface);
  Guard guard;
  std::optional<dstmc::FrameKey> proof;
  int w = 0, h = 0;
  HWND window{};
  {
    std::lock_guard<std::mutex> lock(surfaces_mutex);
    auto it = surfaces.find(surface);
    if (it != surfaces.end())
      window = it->second;
  }
  query_surface(display, surface, EGL_WIDTH, &w);
  query_surface(display, surface, EGL_HEIGHT, &h);
  if (!window) {
    WindowSearch search{w, h};
    EnumWindows(find_window, reinterpret_cast<LPARAM>(&search));
    if (search.count == 1)
      window = search.window;
    else
      diagnostic("native surface window identity unavailable or ambiguous");
  }
  try {
    if (current_context() != EGL_NO_CONTEXT) {
      auto &c = context();
      if (shared().stop)
        c.dispose();
      else {
        proof = compose_hud(c, w, h);
        if (!c.world && shared().service.lease_state().pinned)
          diagnostic("no verified world draw matching leased MatrixV/MatrixP "
                     "on an observed world framebuffer");
      }
      c.reset();
    }
  } catch (const std::exception &e) {
    diagnostic(e.what());
  }
  auto result = original_swap(display, surface);
  if (!result) {
    invalidate("eglSwapBuffers failed/context lost");
    proof.reset();
  }
  if (hooked_window && !IsWindow(hooked_window)) {
    hooked_window = nullptr;
    old_proc = nullptr;
  }
  if (window && !hooked_window && !shared().stop) {
    old_proc =
        reinterpret_cast<WNDPROC>(GetWindowLongPtrW(window, GWLP_WNDPROC));
    SetLastError(0);
    auto prior = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
        window, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(window_proc)));
    if (prior) {
      old_proc = prior;
      hooked_window = window;
    }
  }
  if (result)
    present(window, w, h, proof);
  return result;
}
EGLSurface EGLAPIENTRY create_surface(EGLDisplay d, EGLConfig config,
                                      EGLNativeWindowType window,
                                      const EGLint *attributes) {
  auto result = original_create_surface(d, config, window, attributes);
  if (result != EGL_NO_SURFACE) {
    std::lock_guard<std::mutex> lock(surfaces_mutex);
    surfaces[result] = reinterpret_cast<HWND>(window);
  }
  return result;
}
EGLBoolean EGLAPIENTRY destroy_surface(EGLDisplay d, EGLSurface surface) {
  auto result = original_destroy_surface(d, surface);
  if (result) {
    {
      std::lock_guard<std::mutex> lock(surfaces_mutex);
      surfaces.erase(surface);
    }
    invalidate("EGL surface destroyed");
  }
  return result;
}
EGLBoolean EGLAPIENTRY make_current(EGLDisplay d, EGLSurface draw,
                                    EGLSurface read, EGLContext context_id) {
  auto previous = current_context();
  auto result = original_current(d, draw, read, context_id);
  if (result && previous != context_id) {
    std::lock_guard<std::mutex> lock(shared().mutex);
    shared().proof.clear();
  }
  return result;
}
EGLBoolean EGLAPIENTRY destroy_context(EGLDisplay d, EGLContext ctx) {
  if (current_context() == ctx) {
    Guard guard;
    std::lock_guard<std::mutex> lock(contexts_mutex);
    auto it = contexts.find(ctx);
    if (it != contexts.end())
      it->second->dispose();
  }
  auto result = original_destroy(d, ctx);
  if (result) {
    {
      std::lock_guard<std::mutex> lock(contexts_mutex);
      contexts.erase(ctx);
    }
    invalidate("EGL context destroyed");
  }
  return result;
}
std::vector<void *> hooks;
void *resolve(HMODULE module, const char *name) {
  auto address = reinterpret_cast<void *>(GetProcAddress(module, name));
  return address
             ? address
             : (get_proc ? reinterpret_cast<void *>(get_proc(name)) : nullptr);
}
bool hook(HMODULE module, const char *name, void *detour, void **original) {
  void *address = resolve(module, name);
  if (!address || MH_CreateHook(address, detour, original) != MH_OK) {
    diagnostic(std::string("hook unavailable ") + name);
    return false;
  }
  hooks.push_back(address);
  return true;
}
} // namespace
bool install_render() {
  if (!gles)
    gles = GetModuleHandleW(L"libGLESv2.dll");
  if (!egl)
    egl = GetModuleHandleW(L"libEGL.dll");
  if (!gles || !egl)
    return false;
#define LOAD(name)                                                             \
  name = reinterpret_cast<decltype(name)>(GetProcAddress(gles, #name));        \
  if (!name) {                                                                 \
    diagnostic("missing GLES export " #name);                                  \
    return false;                                                              \
  }
  GL_FUNCTIONS(LOAD)
#undef LOAD
  get_proc = reinterpret_cast<decltype(get_proc)>(
      GetProcAddress(egl, "eglGetProcAddress"));
  current_context = reinterpret_cast<decltype(current_context)>(
      GetProcAddress(egl, "eglGetCurrentContext"));
  query_surface = reinterpret_cast<decltype(query_surface)>(
      GetProcAddress(egl, "eglQuerySurface"));
  egl_error =
      reinterpret_cast<decltype(egl_error)>(GetProcAddress(egl, "eglGetError"));
  if (!current_context || !query_surface || !egl_error)
    return false;
  if (MH_Initialize() != MH_OK)
    return false;
  bool ok =
      hook(egl, "eglCreateWindowSurface",
           reinterpret_cast<void *>(create_surface),
           reinterpret_cast<void **>(&original_create_surface)) &&
      hook(egl, "eglDestroySurface", reinterpret_cast<void *>(destroy_surface),
           reinterpret_cast<void **>(&original_destroy_surface)) &&
      hook(gles, "glDrawElements", reinterpret_cast<void *>(draw_elements),
           reinterpret_cast<void **>(&original_elements)) &&
      hook(gles, "glDrawArrays", reinterpret_cast<void *>(draw_arrays),
           reinterpret_cast<void **>(&original_arrays)) &&
      hook(egl, "eglSwapBuffers", reinterpret_cast<void *>(swap),
           reinterpret_cast<void **>(&original_swap)) &&
      hook(egl, "eglMakeCurrent", reinterpret_cast<void *>(make_current),
           reinterpret_cast<void **>(&original_current)) &&
      hook(egl, "eglDestroyContext", reinterpret_cast<void *>(destroy_context),
           reinterpret_cast<void **>(&original_destroy));
  if (ok) {
    void *angle = resolve(gles, "glBlitFramebufferANGLE"),
         *core = resolve(gles, "glBlitFramebuffer");
    if (angle)
      ok = hook(gles, "glBlitFramebufferANGLE",
                reinterpret_cast<void *>(blit_angle),
                reinterpret_cast<void **>(&original_blit_angle));
    if (ok && core && core != angle)
      ok = hook(gles, "glBlitFramebuffer", reinterpret_cast<void *>(blit_core),
                reinterpret_cast<void **>(&original_blit_core));
  }
  if (ok)
    for (auto address : hooks)
      if (MH_EnableHook(address) != MH_OK) {
        ok = false;
        break;
      }
  if (!ok) {
    for (auto address : hooks) {
      MH_DisableHook(address);
      MH_RemoveHook(address);
    }
    hooks.clear();
    MH_Uninitialize();
    return false;
  }
  log("hooks_installed", "ANGLE GLES2 draw / EGL swap, current and destroy");
  return true;
}
void stop_render() { // DLL remains pinned. Hooks are passthrough after stop,
                     // avoiding an unsafe
  // trampoline free while another render thread is executing it.
  if (hooked_window && IsWindow(hooked_window) &&
      reinterpret_cast<WNDPROC>(
          GetWindowLongPtrW(hooked_window, GWLP_WNDPROC)) == window_proc)
    SetWindowLongPtrW(hooked_window, GWLP_WNDPROC,
                      reinterpret_cast<LONG_PTR>(old_proc.load()));
  std::lock_guard<std::mutex> lock(shared().mutex);
  shared().proof.clear();
}
} // namespace winbridge
