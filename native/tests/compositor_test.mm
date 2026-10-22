#include "compositor.h"
#include <OpenGL/glext.h>
#include <cassert>
#include <iostream>
using namespace dstmc;
static std::array<float, 16> projection(float n, float f) {
  return {1,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          -(f + n) / (f - n),
          -1,
          0,
          0,
          -2 * f * n / (f - n),
          0};
}
static float depth(float distance, float n, float f) {
  return (f / (f - n)) - (f * n / (f - n)) / distance;
}
static void sprite_replay_test(GLuint target) {
  GLuint depth_buffer;
  glGenRenderbuffersEXT(1, &depth_buffer);
  glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, depth_buffer);
  glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_DEPTH_COMPONENT24, 2, 1);
  glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT,
                               GL_RENDERBUFFER_EXT, depth_buffer);
  glDisable(GL_SCISSOR_TEST);
  glDepthMask(GL_TRUE);
  glClearDepth(.9);
  glClear(GL_DEPTH_BUFFER_BIT);
  const char *vs = "#version 120\nvoid main(){gl_Position=gl_Vertex;}";
  const char *fs = "#version 120\nuniform float opacity; void "
                   "main(){if(gl_FragCoord.x>1.)discard;gl_FragColor=vec4(1.,0."
                   ",0.,opacity);}";
  GLuint vertex = glCreateShader(GL_VERTEX_SHADER),
         fragment = glCreateShader(GL_FRAGMENT_SHADER),
         program = glCreateProgram();
  glShaderSource(vertex, 1, &vs, nullptr);
  glCompileShader(vertex);
  glShaderSource(fragment, 1, &fs, nullptr);
  glCompileShader(fragment);
  glAttachShader(program, vertex);
  glAttachShader(program, fragment);
  glLinkProgram(program);
  GLint linked;
  glGetProgramiv(program, GL_LINK_STATUS, &linked);
  assert(linked);
  glUseProgram(program);
  glUniform1f(glGetUniformLocation(program, "opacity"), 1);
  RenderProbe p;
  p.frame_no = 4;
  p.target_id = target;
  p.viewport = {0, 0, 2, 1};
  p.depth_range = {0, 1};
  p.depth_bits = 24;
  p.depth_enabled = p.depth_mask = true;
  p.program_fingerprint =
      "833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4";
  {
    SceneDepth scene;
    scene.after_draw(p, [] {});
    assert(!scene.texture() && "ground_only_has_no_verified_camera");
    p.program_fingerprint =
        "4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063";
    p.depth_enabled = p.depth_mask = false;
    p.shader_sources = {
        {GL_FRAGMENT_SHADER, "test-silhouette", true, true, false}};
    p.shader_matrices = {{"MatrixP", 0, projection(1, 200)}};
    glDisable(GL_DEPTH_TEST);
    glDepthMask(GL_FALSE);
    glEnable(GL_BLEND);
    uint8_t before[8], after[8];
    glReadPixels(0, 0, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, before);
    scene.after_draw(p, [] {
      glBegin(GL_QUADS);
      glVertex3f(-1, -1, 0);
      glVertex3f(1, -1, 0);
      glVertex3f(1, 1, 0);
      glVertex3f(-1, 1, 0);
      glEnd();
    });
    assert(scene.texture());
    assert(!glIsEnabled(GL_DEPTH_TEST) && glIsEnabled(GL_BLEND));
    GLboolean mask;
    glGetBooleanv(GL_DEPTH_WRITEMASK, &mask);
    assert(!mask);
    GLint current;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &current);
    assert(current == int(target));
    glGetIntegerv(GL_CURRENT_PROGRAM, &current);
    assert(current == int(program));
    glReadPixels(0, 0, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, after);
    assert(std::equal(before, before + 8, after) &&
           "replay_preserves_host_color");
    glBindTexture(GL_TEXTURE_2D, scene.texture());
    float depth[2];
    glGetTexImage(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, GL_FLOAT, depth);
    assert(std::abs(depth[0] - .5) < .00001 &&
           std::abs(depth[1] - .9) < .00001 &&
           "sprite_discard_preserves_hole_depth");
    scene.reset();
    assert(!scene.texture() && scene.camera().shader_matrices.empty());
    p.frame_no++;
    p.program_fingerprint =
        "833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4";
    p.depth_enabled = p.depth_mask = true;
    scene.after_draw(p, [] {});
    p.program_fingerprint =
        "4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063";
    p.depth_enabled = p.depth_mask = false;
    glUniform1f(glGetUniformLocation(program, "opacity"), 0);
    scene.after_draw(p, [] {
      glBegin(GL_QUADS);
      glVertex3f(-1, -1, 0);
      glVertex3f(1, -1, 0);
      glVertex3f(1, 1, 0);
      glVertex3f(-1, 1, 0);
      glEnd();
    });
    glBindTexture(GL_TEXTURE_2D, scene.texture());
    glGetTexImage(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, GL_FLOAT, depth);
    assert(std::abs(depth[0] - .9) < .00001 &&
           std::abs(depth[1] - .9) < .00001 &&
           "hidden_avatar_final_zero_alpha_writes_no_depth");
    assert(!glIsEnabled(GL_ALPHA_TEST) && "replay_alpha_test_state_restored");
  }
  glUseProgram(0);
  glDeleteProgram(program);
  glDeleteShader(vertex);
  glDeleteShader(fragment);
  glDeleteRenderbuffersEXT(1, &depth_buffer);
  assert(glGetError() == GL_NO_ERROR);
}
int main() {
  {
    // Literal actual MatrixV from frames 8947/8948: forward -Z, reflected native X.
    FrameView f;f.axes={-1,0,0,0,1,0,0,0,1};f.width=960;f.height=540;
    f.dst_origin={-179.50582885742,0,440.20126342773};f.mc_origin={0,64,0};
    f.pose.position={0,66,0};f.pose.forward={0,0,-1};f.pose.up={0,1,0};
    f.pose.view={1,0,0,0,0,1,0,0,0,0,1,0,0,-66,0,1};
    f.pose.projection={.5625,0,0,0,0,1,0,0,0,0,-1.0100503,-1,0,0,-2.0100503,0};
    RenderProbe p;p.viewport={0,0,960,540};p.depth_range={0,1};
    p.shader_matrices={{"MatrixV",0,{-1,0,0,0,0,1,0,0,0,0,1,0,-179.505829,-2,-440.201263,1}},{"MatrixP",1,f.pose.projection}};
    assert(matching_camera(f,p) && "actual_native_reflection_matches_saved_basis");
    f.axes[0]=1;assert(!matching_camera(f,p));f.axes[0]=-1;
    p.shader_matrices[0].value[12]+=.01;assert(!matching_camera(f,p));
    p.shader_matrices[0].value[12]-=.01;
    // Same 16:9 geometry at another drawable size still matches; a different
    // aspect changes the rays and must be rejected.
    p.viewport={0,0,1280,720};assert(matching_camera(f,p) && "same_aspect_any_size_matches");
    p.viewport={0,0,882,635};assert(!matching_camera(f,p) && "other_aspect_rejected");
    p.viewport={0,0,960,540};
    std::cout<<"PASS measured_native_reflection_and_origins_match\n";
  }

  CGLPixelFormatAttribute attrs[] = {
      kCGLPFAAccelerated,          kCGLPFAColorSize,
      (CGLPixelFormatAttribute)24, kCGLPFADepthSize,
      (CGLPixelFormatAttribute)24, (CGLPixelFormatAttribute)0};
  CGLPixelFormatObj pf;
  GLint count;
  assert(CGLChoosePixelFormat(attrs, &pf, &count) == kCGLNoError);
  CGLContextObj ctx;
  assert(CGLCreateContext(pf, nullptr, &ctx) == kCGLNoError);
  CGLDestroyPixelFormat(pf);
  CGLSetCurrentContext(ctx);
  GLuint fbo, tex, host;
  glGenFramebuffersEXT(1, &fbo);
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               nullptr);
  glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                            GL_TEXTURE_2D, tex, 0);
  assert(glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) ==
         GL_FRAMEBUFFER_COMPLETE_EXT);
  glViewport(0, 0, 2, 1);
  glClearColor(0, 0, 1, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glGenTextures(1, &host);
  glBindTexture(GL_TEXTURE_2D, host);
  float hd[] = {depth(6, 1, 200), depth(6, 1, 200)};
  glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE32F_ARB, 2, 1, 0, GL_LUMINANCE,
               GL_FLOAT, hd);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  uint8_t colors[] = {255, 0, 0, 255, 0, 0, 0, 0}, hud[8] = {};
  float md[] = {depth(2, .05, 100), depth(2, .05, 100)};
  auto f = std::make_shared<FrameView>();
  f->axes = {1,0,0,0,1,0,0,0,1};
  f->width = 2;
  f->height = 1;
  f->key.id = 1;
  f->color = colors;
  f->depth = (uint8_t *)md;
  f->hud = hud;
  f->pose.view = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  f->pose.projection = projection(.05, 100);
  RenderProbe p;
  p.viewport = {0, 0, 2, 1};
  p.depth_range = {0, 1};
  p.shader_matrices = {{"MatrixV", 0, f->pose.view},
                       {"MatrixP", 1, projection(1, 200)}};
  uint64_t now = 0;
  CameraService service([&] { return now; });
  service.offer(f, {});
  service.lease_latest(f->key.pair_hash, f->key.epoch);
  assert(service.camera_applied(f->key));
  {
    Compositor c(service);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, 0, 1, 1);
    glEnable(GL_DEPTH_TEST);
    glDepthMask(GL_TRUE);
    glActiveTexture(GL_TEXTURE3);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE);
    GLint before[4];
    glGetIntegerv(GL_VIEWPORT, before);
    assert(c.compose(f->key, p, host).status == ComposeStatus::COMPOSITED);
    assert(glIsEnabled(GL_SCISSOR_TEST) && glIsEnabled(GL_DEPTH_TEST));
    GLboolean mask;
    glGetBooleanv(GL_DEPTH_WRITEMASK, &mask);
    assert(mask);
    GLint active;
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    assert(active == GL_TEXTURE3);
    GLint after[4];
    glGetIntegerv(GL_VIEWPORT, after);
    assert(std::equal(before, before + 4, after));
    uint8_t pixels[8];
    glReadPixels(0, 0, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    assert(pixels[0] >= 254 && pixels[2] <= 1 && "closer_surface_wins");
    assert(pixels[4] <= 1 && pixels[6] >= 254 &&
           "transparent_pixel_preserves_host");
    p.shader_matrices[0].value[0] = -1;
    assert(c.compose(f->key, p, host).status ==
               ComposeStatus::SKIPPED_MISMATCH &&
           "reflected_view_rejected");
    f->axes[0] = -1;
    assert(c.compose(f->key, p, host).status == ComposeStatus::COMPOSITED && "matching_reflected_view_accepted");
    p.shader_matrices[0].value[0] = 1;
    assert(c.compose(f->key, p, host).status == ComposeStatus::SKIPPED_MISMATCH && "identity_view_rejected_for_reflected_binding");
    f->axes[0] = 1;
    assert(c.compose(f->key, p, 0).status == ComposeStatus::DEPTH_UNAVAILABLE);
    now = 1000;
    assert(c.compose(f->key, p, host).status == ComposeStatus::SKIPPED_STALE);
    assert(glGetError() == GL_NO_ERROR);
  }
  sprite_replay_test(fbo);
  glDeleteTextures(1, &host);
  glDeleteTextures(1, &tex);
  glDeleteFramebuffersEXT(1, &fbo);
  CGLSetCurrentContext(nullptr);
  CGLDestroyContext(ctx);
  std::cout << "PASS transparent_pixel_preserves_host closer_surface_wins "
               "ui_state_restored reflected_view_rejected "
               "expired_compose_skipped sprite_discard_preserves_hole_depth\n";
}
