#include "compositor.h"
#include <OpenGL/glext.h>
namespace dstmc {
namespace {
constexpr const char *ground =
    "833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4";
constexpr const char *sprite =
    "4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063";
struct State {
  GLint fbo, active, texture, unpack;
  State() {
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fbo);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
    glPushAttrib(GL_ALL_ATTRIB_BITS);
  }
  ~State() {
    glPopAttrib();
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glActiveTexture(active);
    glBindTexture(GL_TEXTURE_2D, texture);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
  }
};
} // namespace
void SceneDepth::reset() {
  valid_ = false;
  target_ = -1;
  camera_ = {};
}
bool SceneDepth::allocate(int w, int h) {
  if (w == width_ && h == height_ && fbo_)
    return true;
  glDeleteTextures(1, &depth_);
  glDeleteTextures(1, &color_);
  glDeleteFramebuffersEXT(1, &fbo_);
  depth_ = color_ = fbo_ = 0;
  if (w <= 0 || h <= 0 || w > 1920 || h > 1080)
    return false;
  glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
  glGenTextures(1, &depth_);
  glBindTexture(GL_TEXTURE_2D, depth_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24, w, h, 0,
               GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nullptr);
  for (GLenum param : {GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER})
    glTexParameteri(GL_TEXTURE_2D, param, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glGenTextures(1, &color_);
  glBindTexture(GL_TEXTURE_2D, color_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glGenFramebuffersEXT(1, &fbo_);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo_);
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT,
                            GL_TEXTURE_2D, depth_, 0);
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                            GL_TEXTURE_2D, color_, 0);
  bool ok = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) ==
            GL_FRAMEBUFFER_COMPLETE_EXT;
  width_ = w;
  height_ = h;
  return ok;
}
void SceneDepth::after_draw(const RenderProbe &p,
                            const std::function<void()> &replay) {
  if (frame_ != p.frame_no) {
    reset();
    frame_ = p.frame_no;
  }
  if (p.viewport[0] || p.viewport[1] ||
      p.depth_range != std::array<double, 2>{0, 1})
    return;
  if (p.program_fingerprint == ground && p.depth_enabled && p.depth_mask &&
      p.depth_bits >= 24) {
    State state;
    if (!allocate(p.viewport[2], p.viewport[3]))
      return;
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, p.target_id);
    glBindTexture(GL_TEXTURE_2D, depth_);
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width_, height_);
    target_ = p.target_id;
    valid_ = true;
    camera_ = p;
    return;
  }
  if (p.program_fingerprint != sprite || !valid_ || p.target_id != target_ ||
      p.viewport[2] != width_ || p.viewport[3] != height_)
    return;
  bool alpha = false;
  for (auto &s : p.shader_sources)
    if (s.type == GL_FRAGMENT_SHADER && s.source_available &&
        s.contains_discard && !s.writes_frag_depth)
      alpha = true;
  if (!alpha) {
    reset();
    return;
  }
  bool perspective = false;
  for (auto &m : p.shader_matrices)
    if (m.name == "MatrixP" && m.value[11] == -1 && m.value[15] == 0)
      perspective = true;
  if (!perspective) {
    reset();
    return;
  }
  // Original shader, sampler bindings, vertex streams and discard branch are
  // retained.
  State state;
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo_);
  glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
  glEnable(GL_DEPTH_TEST);
  glDepthMask(GL_TRUE);
  glDepthFunc(GL_LESS);
  glDisable(GL_BLEND);
  // Reject zero final alpha too, including the render-only hidden local avatar.
  glEnable(GL_ALPHA_TEST);
  glAlphaFunc(GL_GREATER, 0);
  replay();
  camera_ = p;
}
SceneDepth::~SceneDepth() {
  if (CGLGetCurrentContext() != owner_)
    return;
  glDeleteTextures(1, &depth_);
  glDeleteTextures(1, &color_);
  glDeleteFramebuffersEXT(1, &fbo_);
}
} // namespace dstmc
