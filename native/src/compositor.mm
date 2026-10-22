#include "compositor.h"
#include <OpenGL/glext.h>
#include <algorithm>
#include <stdexcept>
namespace dstmc {
namespace {
// GL2 attrib stacks cover legacy raster state; FBO/program/PBO require explicit
// restoration.
struct State {
  GLint program, fbo, active, pack, unpack, matrix;
  GLint textures[3];
  State() {
    glGetIntegerv(GL_CURRENT_PROGRAM, &program);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fbo);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
    glGetIntegerv(GL_MATRIX_MODE, &matrix);
    glPushAttrib(GL_ALL_ATTRIB_BITS);
    glPushClientAttrib(GL_CLIENT_ALL_ATTRIB_BITS);
    for (int i = 0; i < 3; i++) {
      glActiveTexture(GL_TEXTURE0 + i);
      glGetIntegerv(GL_TEXTURE_BINDING_2D, &textures[i]);
    }
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    glPixelStorei(GL_UNPACK_SWAP_BYTES, GL_FALSE);
  }
  ~State() {
    for (int i = 0; i < 3; i++) {
      glActiveTexture(GL_TEXTURE0 + i);
      glBindTexture(GL_TEXTURE_2D, textures[i]);
    }
    glPopClientAttrib();
    glPopAttrib();
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glUseProgram(program);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, pack);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
    glActiveTexture(active);
    glMatrixMode(matrix);
  }
};
GLuint shader(GLenum type, const char *source) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &source, nullptr);
  glCompileShader(s);
  GLint ok;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(s);
    throw std::runtime_error("compositor shader compilation failed");
  }
  return s;
}
GLuint program(const char *fragment) {
  const char *vertex = "#version 120\nvarying vec2 uv;void "
                       "main(){gl_Position=gl_Vertex;uv=gl_Vertex.xy*.5+.5;}";
  auto v = shader(GL_VERTEX_SHADER, vertex),
       f = shader(GL_FRAGMENT_SHADER, fragment);
  GLuint p = glCreateProgram();
  glAttachShader(p, v);
  glAttachShader(p, f);
  glLinkProgram(p);
  glDeleteShader(v);
  glDeleteShader(f);
  GLint ok;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    glDeleteProgram(p);
    throw std::runtime_error("compositor shader link failed");
  }
  return p;
}
void quad() {
  glDisable(GL_DEPTH_TEST);
  glDepthMask(GL_FALSE);
  glDisable(GL_ALPHA_TEST);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_CULL_FACE);
  glDisable(GL_COLOR_LOGIC_OP);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
  glEnable(GL_BLEND);
  glBlendEquationSeparate(GL_FUNC_ADD, GL_FUNC_ADD);
  glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE,
                      GL_ONE_MINUS_SRC_ALPHA);
  glBegin(GL_QUADS);
  glVertex2f(-1, -1);
  glVertex2f(1, -1);
  glVertex2f(1, 1);
  glVertex2f(-1, 1);
  glEnd();
}
void upload(GLuint texture, int unit, int w, int h, GLenum internal,
            GLenum format, GLenum type, const void *pixels) {
  glActiveTexture(GL_TEXTURE0 + unit);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, format, type, pixels);
}
const char *fragment = R"GLSL(#version 120
varying vec2 uv;uniform sampler2D mcColor,mcDepth,hostDepth;uniform mat4 inverseMC,inverseHost;
void main(){vec4 color=texture2D(mcColor,uv);if(color.a<=0.)discard;
 float md=texture2D(mcDepth,uv).r,hd=texture2D(hostDepth,uv).r;
 if(md>=1.||md<0.)discard;
 vec4 m=inverseMC*vec4(uv*2.-1.,md*2.-1.,1.);vec4 h=inverseHost*vec4(uv*2.-1.,hd*2.-1.,1.);
 if(abs(m.w)<0.000001||abs(h.w)<0.000001)discard;
 float mz=-m.z/m.w,hz=-h.z/h.w;if(mz<=0.||(hd<1.&&mz>=hz))discard;gl_FragColor=color;}
)GLSL";
} // namespace
bool inverse_matrix(const std::array<float, 16> &a,
                    std::array<float, 16> &out) {
  double m[4][8]{};
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      m[r][c] = a[c * 4 + r];
      m[r][c + 4] = r == c;
    }
  for (int c = 0; c < 4; c++) {
    int pivot = c;
    for (int r = c + 1; r < 4; r++)
      if (std::abs(m[r][c]) > std::abs(m[pivot][c]))
        pivot = r;
    if (std::abs(m[pivot][c]) < 1e-12)
      return false;
    for (int j = 0; j < 8; j++)
      std::swap(m[c][j], m[pivot][j]);
    double s = m[c][c];
    for (double &v : m[c])
      v /= s;
    for (int r = 0; r < 4; r++)
      if (r != c) {
        s = m[r][c];
        for (int j = 0; j < 8; j++)
          m[r][j] -= s * m[c][j];
      }
  }
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      out[c * 4 + r] = float(m[r][c + 4]);
      if (!std::isfinite(out[c * 4 + r]))
        return false;
    }
  return true;
}
bool matching_camera(const FrameView &f, const RenderProbe &p) {
  if (p.viewport != std::array<int, 4>{0, 0, int(f.width), int(f.height)} ||
      p.depth_range != std::array<double, 2>{0, 1})
    return false;
  const std::array<float, 16> *v = nullptr, *projection = nullptr;
  for (auto &m : p.shader_matrices) {
    if (m.name == "MatrixV")
      v = &m.value;
    if (m.name == "MatrixP")
      projection = &m.value;
  }
  if (!v || !projection)
    return false;
  double delta[3] = {f.dst_origin.x - f.mc_origin.x,
                     f.dst_origin.y - f.mc_origin.y,
                     f.dst_origin.z - f.mc_origin.z};
  for (int i = 0; i < 16; i++) {
    double expected = f.pose.view[i];
    if (i >= 12)
      for (int c = 0; c < 3; c++)
        expected -= f.pose.view[c * 4 + i - 12] * delta[c];
    if (!std::isfinite((*v)[i]) || std::abs((*v)[i] - expected) > 0.001)
      return false;
  }
  // Near/far differ by engine; all ray-defining projection entries must agree.
  for (int i = 0; i < 16; i++)
    if (i != 10 && i != 14)
      if (!std::isfinite((*projection)[i]) ||
          std::abs((*projection)[i] - f.pose.projection[i]) > 0.0002)
        return false;
  return true;
}
ComposeResult Compositor::compose(FrameKey key, const RenderProbe &p,
                                  GLuint depth) {
  auto frame = service_.ready(key);
  if (!frame)
    return {ComposeStatus::SKIPPED_STALE, "missing ack or expired frame"};
  if (!matching_camera(*frame, p))
    return {ComposeStatus::SKIPPED_MISMATCH,
            "actual view/rays/pixels mismatch"};
  if (!depth)
    return {ComposeStatus::DEPTH_UNAVAILABLE,
            "verified scene depth unavailable"};
  std::array<float, 16> mc{}, host{};
  const std::array<float, 16> *projection = nullptr;
  for (auto &m : p.shader_matrices)
    if (m.name == "MatrixP")
      projection = &m.value;
  if (!projection || !inverse_matrix(frame->pose.projection, mc) ||
      !inverse_matrix(*projection, host))
    return {ComposeStatus::SKIPPED_MISMATCH, "singular projection"};
  State state;
  if (!program_) {
    program_ = program(fragment);
    glGenTextures(3, textures_);
  }
  glUseProgram(program_);
  upload(textures_[0], 0, frame->width, frame->height, GL_RGBA8, GL_RGBA,
         GL_UNSIGNED_BYTE, frame->color);
  upload(textures_[1], 1, frame->width, frame->height, GL_LUMINANCE32F_ARB,
         GL_LUMINANCE, GL_FLOAT, frame->depth);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, depth);
  glUniform1i(glGetUniformLocation(program_, "mcColor"), 0);
  glUniform1i(glGetUniformLocation(program_, "mcDepth"), 1);
  glUniform1i(glGetUniformLocation(program_, "hostDepth"), 2);
  glUniformMatrix4fv(glGetUniformLocation(program_, "inverseMC"), 1, GL_FALSE,
                     mc.data());
  glUniformMatrix4fv(glGetUniformLocation(program_, "inverseHost"), 1, GL_FALSE,
                     host.data());
  quad();
  return {ComposeStatus::COMPOSITED, "matched complete frame"};
}
void Compositor::hud(const FrameView &f) {
  State state;
  if (!hud_program_)
    hud_program_ =
        program("#version 120\nvarying vec2 uv;uniform sampler2D color;void "
                "main(){gl_FragColor=texture2D(color,uv);}");
  if (!textures_[2])
    glGenTextures(1, &textures_[2]);
  glUseProgram(hud_program_);
  upload(textures_[2], 0, f.width, f.height, GL_RGBA8, GL_RGBA,
         GL_UNSIGNED_BYTE, f.hud);
  glUniform1i(glGetUniformLocation(hud_program_, "color"), 0);
  quad();
}
Compositor::~Compositor() {
  if (CGLGetCurrentContext() != owner_)
    return;
  if (program_)
    glDeleteProgram(program_);
  if (hud_program_)
    glDeleteProgram(hud_program_);
  glDeleteTextures(3, textures_);
}
} // namespace dstmc
