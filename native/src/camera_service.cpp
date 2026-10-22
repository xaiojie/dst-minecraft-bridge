#include "camera_service.h"
#include <chrono>
namespace dstmc {
bool same_key(const FrameKey &a, const FrameKey &b) {
  return a.pair_hash == b.pair_hash && a.epoch == b.epoch && a.id == b.id;
}
CameraService::CameraService(Clock clock)
    : clock_(clock ? std::move(clock) : [] {
        return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count());
      }) {}
void CameraService::discard() {
  frame_.reset();
  mapping_.reset();
  acked_ = leased_ = false;
}
void CameraService::expire() {
  if (frame_ && clock_() >= deadline_)
    discard();
}
void CameraService::offer(std::shared_ptr<FrameView> f,
                          std::shared_ptr<void> mapping) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!f)
    return;
  if (!valid_transform(*f)) { discard(); return; }
  bool session = have_last_ && f->key.pair_hash == last_.pair_hash &&
                 f->key.epoch == last_.epoch;
  if (session && !same_transform(*f,last_transform_)) { discard(); return; }
  if (!session)
    discard();
  if (session && f->key.id <= last_.id)
    return;
  // A leased pose cannot be replaced by a newer image until presentation or
  // expiry.
  if (frame_)
    return;
  last_ = f->key;
  last_transform_ = *f;
  have_last_ = true;
  mapping_ = std::move(mapping);
  frame_ = std::move(f);
  deadline_ = clock_() + 250;
}
std::optional<FrameLease> CameraService::lease_latest(PairKey pair,
                                                      Epoch epoch) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!frame_ || frame_->key.pair_hash != pair || frame_->key.epoch != epoch)
    return {};
  auto &f = *frame_;
  auto p = pose_to_dst(f,f.pose);
  leased_ = true;
  return FrameLease{f.key, p, f.width, f.height};
}
bool CameraService::camera_applied(FrameKey k) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!frame_ || !leased_ || !same_key(frame_->key, k))
    return false;
  acked_ = true;
  return true;
}
std::shared_ptr<const FrameView> CameraService::ready(FrameKey k) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!frame_ || !acked_ || !same_key(frame_->key, k))
    return {};
  // Returned alias retains both mmap and slot until the render operation
  // finishes.
  struct Held {
    std::shared_ptr<void> mapping;
    std::shared_ptr<FrameView> frame;
  };
  auto h = std::make_shared<Held>(Held{mapping_, frame_});
  return std::shared_ptr<const FrameView>(h, frame_.get());
}
bool CameraService::validate_transform(const WorldTransform &t) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!valid_transform(t) || (frame_ && !same_transform(*frame_,t))) {
    discard(); return false;
  }
  return true;
}
void CameraService::release() {
  std::lock_guard<std::mutex> lock(mutex_);
  discard();
}
void CameraService::resize(uint32_t w, uint32_t h) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (frame_ && (frame_->width != w || frame_->height != h))
    discard();
}
} // namespace dstmc
