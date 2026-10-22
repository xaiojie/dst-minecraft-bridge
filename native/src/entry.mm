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
  // The scene is still being drawn here: this pass — and every pass after it —
  // paints over whatever a composite written now would leave behind, so only
  // the HUD survived into the presented image. Compositing is deferred to
  // present(), which runs last, right before the back buffer is swapped.
  (void)p;
}
void after_draw(const dstmc::RenderProbe &p,
                const std::function<void()> &replay) {
  if (!enabled())
    return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  context().depth.after_draw(p, replay);
  // Do NOT resize the camera service with the drawable viewport: the stream
  // size is the Minecraft framebuffer size advertised through /v2/status, and
  // resize() discards any pinned frame whose size differs. The compositor
  // samples with normalized texture coordinates, so drawable and stream sizes
  // are independent. Stream-size invalidation already happens in
  // discover_frame(), which has the authoritative status dimensions.
}
void present() {
  if (!enabled())
    return;
  std::lock_guard<std::recursive_mutex> lock(contexts_mutex);
  auto &c = context();
  bool composited = false;
  std::shared_ptr<const dstmc::FrameView> displayed;
  if (c.depth.texture()) {
    auto camera = c.depth.camera();
    if (camera.viewport[2] > 0 && camera.viewport[3] > 0) {
      GLint fbo = 0, viewport[4]{};
      glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fbo);
      glGetIntegerv(GL_VIEWPORT, viewport);
      // Composite into the drawable the window will present, after the whole
      // host scene (ground, sprites, lighting, post passes) has been drawn.
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
      glViewport(0, 0, camera.viewport[2], camera.viewport[3]);
      auto frame_key = key();
      auto result = c.compositor.compose(frame_key, camera, c.depth.texture());
      composited = result.status == dstmc::ComposeStatus::COMPOSITED;
      if (composited)
        displayed = camera_service().pinned(frame_key);
      report_compose(camera, frame_key, result);
      glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
      glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    }
  }
  bool presented = composited && displayed;
  // Window activation proof additionally requires the acknowledgement, but the
  // HUD and the composited image do not.
  bool proven = presented && camera_service().ready(displayed->key);
  if (presented) {
    c.compositor.hud(*displayed);
    // Do not release the pin here: the pose is still applied to the host
    // camera, so the same frame may be composited on following draws until the
    // client leases a new pose or the lease expires. Releasing made every other
    // draw fall back to the host-only image.
  }
  present_window(c.depth.camera().viewport[2], c.depth.camera().viewport[3],
                 proven ? std::optional<dstmc::FrameKey>(displayed->key)
                        : std::nullopt);
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
