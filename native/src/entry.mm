#include "camera_http.h"
#include "gl_observer.h"
#import <Cocoa/Cocoa.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <cstdlib>
#include <fstream>
#include <map>
#import <objc/runtime.h>
#include <unistd.h>
namespace bridge {
struct Context {
  dstmc::SceneDepth depth;
  dstmc::Compositor compositor{camera_service()};
  std::shared_ptr<const dstmc::FrameView> displayed;
  dstmc::RenderProbe scene_camera;
  bool sprite_state = false;
  GLint depth_func{};
  GLboolean depth_test{}, depth_mask{};
};
std::map<CGLContextObj, std::unique_ptr<Context>> contexts;
std::recursive_mutex contexts_mutex;
Context &context() {
  auto &c = contexts[CGLGetCurrentContext()];
  if (!c)
    c = std::make_unique<Context>();
  return *c;
}
void before_draw(const dstmc::RenderProbe &p) {
  if (!enabled()) return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c = context();
  bool sprite=p.program_fingerprint=="4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063" && p.target_id==c.depth.target();
  bool boundary=c.depth.terrain_texture() && p.target_id!=c.depth.target();
  if(!sprite && !boundary)return;
  // A target transition is also a scene boundary: empty landscapes may have no
  // sprite draw. Insert into the terrain target before the following resolve.
  auto camera=sprite?p:c.depth.camera();
  if (!c.displayed) {
    auto k=key();auto candidate=camera_service().pinned(k);
    if(!candidate || !dstmc::matching_camera(*candidate,camera)){
      auto ack=camera_service().acknowledged_key();if(ack){k=*ack;candidate=camera_service().ready(k);}
    }
    GLint original_fbo,viewport[4];glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT,&original_fbo);glGetIntegerv(GL_VIEWPORT,viewport);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,c.depth.target());glViewport(camera.viewport[0],camera.viewport[1],camera.viewport[2],camera.viewport[3]);
    auto result=c.compositor.compose(k,camera,c.depth.terrain_texture(),true);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,original_fbo);glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);
    report_compose(camera,k,result);
    if(result.status==dstmc::ComposeStatus::COMPOSITED){c.displayed=candidate;c.scene_camera=camera;}
  }
  if (sprite && c.displayed) {
    c.depth_test=glIsEnabled(GL_DEPTH_TEST);glGetBooleanv(GL_DEPTH_WRITEMASK,&c.depth_mask);
    glGetIntegerv(GL_DEPTH_FUNC,&c.depth_func);c.sprite_state=true;
    glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LEQUAL);glDepthMask(GL_FALSE);
  }
}
void after_draw(const dstmc::RenderProbe &p,
                const std::function<void()> &replay) {
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c=context();
  if(c.sprite_state) {
    if(c.depth_test)glEnable(GL_DEPTH_TEST);else glDisable(GL_DEPTH_TEST);
    glDepthMask(c.depth_mask);glDepthFunc(c.depth_func);c.sprite_state=false;
  }
  if(!enabled()){c.displayed.reset();c.depth.reset();return;}
  if(p.program_fingerprint=="833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4")c.displayed.reset();
  c.depth.after_draw(p, replay);
  // Do NOT resize the camera service with the drawable viewport: the stream
  // size is the Minecraft framebuffer size advertised through /v2/status, and
  // resize() discards any pinned frame whose size differs. The compositor
  // samples with normalized texture coordinates, so drawable and stream sizes
  // are independent. Stream-size invalidation already happens in
  // discover_frame(), which has the authoritative status dimensions.
}
void present() {
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c = context();
  if(!enabled()){c.displayed.reset();c.depth.reset();return;}
  auto displayed=c.displayed;
  bool proven=displayed && camera_service().ready(displayed->key);
  if(displayed) {
    GLint fbo,viewport[4];glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT,&fbo);glGetIntegerv(GL_VIEWPORT,viewport);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,0);
    glViewport(0,0,c.scene_camera.viewport[2],c.scene_camera.viewport[3]);
    // Captured after hand rendering and GUI: these stay in the foreground,
    // like native MC first person, independently of world occlusion.
    c.compositor.hud(*displayed);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,fbo);glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);
  }
  GLint viewport[4];glGetIntegerv(GL_VIEWPORT,viewport);
  present_window(viewport[2],viewport[3],
      proven ? std::optional<dstmc::FrameKey>(displayed->key) : std::nullopt);
  c.displayed.reset();
  c.depth.reset();
}
void forget(CGLContextObj c) {
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  contexts.erase(c);
  camera_service().release();
}
} // namespace bridge

#ifndef DSTMC_PIPELINE_TEST
namespace {
thread_local bool observing = false;
void (*original_flush)(id, SEL) = nullptr;
void (*original_dealloc)(id, SEL) = nullptr;
template <class F> void diagnostic(F fn) noexcept {
  if (observing)
    return;
  observing = true;
  try {
    fn();
  } catch (...) { /* Diagnostics must never escape into the game's renderer. */
  }
  observing = false;
}
void flush(id self, SEL cmd) {
  diagnostic([] {
    bridge::present();
    dstmc::begin_present();
  });
  original_flush(self, cmd);
}
void dealloc_context(id self, SEL cmd) {
  auto c = [(NSOpenGLContext *)self CGLContextObj];
  diagnostic([&] {
    bridge::forget(c);
    dstmc::forget_context(c);
  });
  original_dealloc(self, cmd);
}
void draw_arrays(GLenum mode, GLint first, GLsizei count) {
  if (observing) {
    glDrawArrays(mode, first, count);
    return;
  }
  dstmc::RenderProbe p;
  diagnostic([&] {
    if (bridge::enabled()) {
      p = dstmc::inspect_draw("glDrawArrays");
      bridge::before_draw(p);
    }
  });
  glDrawArrays(mode, first, count);
  diagnostic([&] {
    bridge::after_draw(p, [&] { glDrawArrays(mode, first, count); });
    dstmc::after_draw("glDrawArrays");
  });
}
void draw_elements(GLenum mode, GLsizei count, GLenum type,
                   const GLvoid *indices) {
  if (observing) {
    glDrawElements(mode, count, type, indices);
    return;
  }
  dstmc::RenderProbe p;
  diagnostic([&] {
    if (bridge::enabled()) {
      p = dstmc::inspect_draw("glDrawElements");
      bridge::before_draw(p);
    }
  });
  glDrawElements(mode, count, type, indices);
  diagnostic([&] {
    bridge::after_draw(p, [&] { glDrawElements(mode, count, type, indices); });
    dstmc::after_draw("glDrawElements");
  });
}
CGLError destroy_context(CGLContextObj c) {
  diagnostic([&] {
    bridge::forget(c);
    dstmc::forget_context(c);
  });
  return CGLDestroyContext(c);
}
#define INTERPOSE(replacement, original)                                       \
  __attribute__((used)) static struct {                                        \
    const void *replacement_ptr;                                               \
    const void *original_ptr;                                                  \
  } hook_##original __attribute__((section("__DATA,__interpose"))) = {         \
      (const void *)&replacement, (const void *)&original}
INTERPOSE(draw_arrays, glDrawArrays);
INTERPOSE(draw_elements, glDrawElements);
INTERPOSE(destroy_context, CGLDestroyContext);
__attribute__((constructor)) void loaded() {
  @autoreleasepool {
    const char *dir = getenv("DSTMC_PROBE_DIR");
    if (!dir || !*dir)
      return;
    diagnostic([&] {
      dstmc::configure_probe(dir);
      bridge::start(dir);
      Class cls = [NSOpenGLContext class];
      Method method = class_getInstanceMethod(cls, @selector(flushBuffer));
      if (!method)
        return;
      original_flush = (decltype(original_flush))method_setImplementation(
          method, (IMP)flush);
      // Add a class-local dealloc override so inherited NSObject dealloc is
      // never changed.
      SEL selector = sel_registerName("dealloc");
      Method d = class_getInstanceMethod(cls, selector);
      original_dealloc =
          (decltype(original_dealloc))method_getImplementation(d);
      if (!class_addMethod(cls, selector, (IMP)dealloc_context,
                           method_getTypeEncoding(d)))
        method_setImplementation(d, (IMP)dealloc_context);
      std::ofstream(std::string(dir) + "/loaded.json")
          << "{\"schema\":1,\"pid\":" << getpid()
          << ",\"architecture\":\"x86_64\",\"present_hook\":\"NSOpenGLContext."
             "flushBuffer\",\"draw_hooks\":[\"glDrawArrays\","
             "\"glDrawElements\"],\"synthetic_draws\":false}\n";
    });
  }
}
} // namespace

#endif // DSTMC_PIPELINE_TEST
