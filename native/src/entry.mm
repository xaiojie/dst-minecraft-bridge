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
  bool composited = false;
  std::shared_ptr<const dstmc::FrameView> displayed;
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
  if (!enabled())
    return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c = context();
  if (p.program_fingerprint !=
          "1cedce6eb12563dcd2ef433dd70128f43272600fbc06755f8c0364af85f612c8" ||
      !c.depth.texture())
    return;
  auto frame_key = key();
  struct TargetState {
    GLint fbo, viewport[4];
    TargetState() {
      glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fbo);
      glGetIntegerv(GL_VIEWPORT, viewport);
    }
    ~TargetState() {
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
      glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    }
  } target_state;
  glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, c.depth.target());
  auto camera = c.depth.camera();
  glViewport(0, 0, camera.viewport[2], camera.viewport[3]);
  auto result = c.compositor.compose(frame_key, camera, c.depth.texture());
  c.composited = result.status == dstmc::ComposeStatus::COMPOSITED;
  if (c.composited)
    c.displayed = camera_service().ready(frame_key);
  report_compose(camera, frame_key, result);
}
void after_draw(const dstmc::RenderProbe &p,
                const std::function<void()> &replay) {
  if (!enabled())
    return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  context().depth.after_draw(p, replay);
  if (context().depth.texture() && p.target_id == context().depth.target())
    camera_service().resize(p.viewport[2], p.viewport[3]);
}
void present() {
  if (!enabled())
    return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c = context();
  bool presented =
      c.composited && c.displayed && camera_service().ready(c.displayed->key);
  if (presented) {
    c.compositor.hud(*c.displayed);
    camera_service().release();
  }
  present_window(c.depth.camera().viewport[2], c.depth.camera().viewport[3],
                 presented ? std::optional<dstmc::FrameKey>(c.displayed->key)
                           : std::nullopt);
  c.composited = false;
  c.displayed.reset();
  c.depth.reset();
}
void forget(CGLContextObj c) {
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  contexts.erase(c);
  camera_service().release();
}
} // namespace bridge

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
