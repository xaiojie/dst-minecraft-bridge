#include "camera_service.h"
#include <chrono>
#include <cstdlib>
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
  latest_.reset();
  latest_mapping_.reset();
  acked_ = leased_ = false;
}
void CameraService::expire() {
  if (frame_ && clock_() >= deadline_) {
    // The applied pose is no longer guaranteed; stop compositing but keep the
    // newest frame so the next lease can pin it without another file read.
    frame_.reset();
    mapping_.reset();
    acked_ = leased_ = false;
  }
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
  last_ = f->key;
  last_transform_ = *f;
  have_last_ = true;
  // The newest frame is what the next lease hands to the client. It is not
  // pinned here: pinning happens in lease_latest() so an acked frame can be
  // composited on every draw instead of exactly once.
  latest_ = std::move(f);
  latest_mapping_ = std::move(mapping);
}
std::optional<FrameLease> CameraService::lease_latest(PairKey pair,
                                                      Epoch epoch) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!latest_ || latest_->key.pair_hash != pair ||
      latest_->key.epoch != epoch)
    return {};
  // Pin the newest frame at the authoritative pose the client must apply.
  frame_ = latest_;
  mapping_ = latest_mapping_;
  leased_ = true;
  acked_ = false;
  // The client completes lease->apply->ack across several loopback round trips
  // (measured p50 ~640 ms against the real game), so the pin must outlive that
  // or every compose sample is stale. DSTMC_LEASE_MS allows measuring a
  // different window without a rebuild; the acceptance default is one second.
  const char *lease_ms = getenv("DSTMC_LEASE_MS");
  deadline_ = clock_() + (lease_ms ? strtoull(lease_ms, nullptr, 10) : 1000);
  auto &f = *frame_;
  auto p = pose_to_dst(f,f.pose);
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
std::shared_ptr<const FrameView> CameraService::pinned(FrameKey k) {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  if (!frame_ || !leased_ || !same_key(frame_->key, k))
    return {};
  struct Held {
    std::shared_ptr<void> mapping;
    std::shared_ptr<FrameView> frame;
  };
  auto h = std::make_shared<Held>(Held{mapping_, frame_});
  return std::shared_ptr<const FrameView>(h, frame_.get());
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
CameraService::LeaseState CameraService::lease_state() {
  std::lock_guard<std::mutex> lock(mutex_);
  expire();
  LeaseState s;
  s.pinned = bool(frame_);
  s.acked = acked_;
  s.leased = leased_;
  s.key_id = frame_ ? frame_->key.id : 0;
  s.remaining_ms = (frame_ && deadline_ > clock_()) ? deadline_ - clock_() : 0;
  return s;
}
void CameraService::resize(uint32_t w, uint32_t h) {
  std::lock_guard<std::mutex> lock(mutex_);
  if ((frame_ && (frame_->width != w || frame_->height != h)) ||
      (latest_ && (latest_->width != w || latest_->height != h)))
    discard();
}
} // namespace dstmc
