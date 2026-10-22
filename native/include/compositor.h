#pragma once
#include "camera_service.h"
#include "gl_observer.h"
#include <OpenGL/gl.h>
namespace dstmc {
enum class ComposeStatus {
  COMPOSITED,
  SKIPPED_MISMATCH,
  SKIPPED_STALE,
  DEPTH_UNAVAILABLE
};
struct ComposeResult {
  ComposeStatus status;
  std::string reason;
};
/** All methods except CameraService calls require the owning current GL
 * context. */
class Compositor {
public:
  explicit Compositor(CameraService &service) : service_(service) {}
  ComposeResult compose(FrameKey, const RenderProbe &, GLuint scene_depth);
  void hud(const FrameView &);
  ~Compositor();

private:
  CGLContextObj owner_ = CGLGetCurrentContext();
  CameraService &service_;
  GLuint program_{}, hud_program_{}, textures_[3]{};
};
bool matching_camera(const FrameView &, const RenderProbe &);
bool inverse_matrix(const std::array<float, 16> &, std::array<float, 16> &);
/** Owns supplemental depth in one context; replays only profiled world sprite
 * draws. */
class SceneDepth {
public:
  void after_draw(const RenderProbe &, const std::function<void()> &replay);
  GLuint texture() const {
    return valid_ && camera_.frame_no == frame_ &&
                   !camera_.shader_matrices.empty()
               ? depth_
               : 0;
  }
  const RenderProbe &camera() const { return camera_; }
  int target() const { return target_; }
  void reset();
  ~SceneDepth();

private:
  CGLContextObj owner_ = CGLGetCurrentContext();
  bool allocate(int, int);
  GLuint fbo_{}, depth_{}, color_{};
  int width_{}, height_{}, target_ = -1;
  uint64_t frame_{};
  bool valid_{};
  RenderProbe camera_{};
};
} // namespace dstmc
