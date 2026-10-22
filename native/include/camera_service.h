#pragma once
#include "frame_protocol.h"
#include <functional>
#include <memory>
#include <mutex>
namespace dstmc {
using PairKey = std::array<uint8_t, 32>;
using Epoch = std::array<uint8_t, 16>;
struct FrameLease {
  FrameKey key{};
  FramePose pose{};
  uint32_t width{}, height{};
};
bool same_key(const FrameKey &, const FrameKey &);
/** Thread-safe rendezvous. HTTP owns no game API; render owns GL. */
class CameraService {
public:
  using Clock = std::function<uint64_t()>;
  explicit CameraService(Clock clock = {});
  void offer(std::shared_ptr<FrameView>, std::shared_ptr<void> mapping);
  std::optional<FrameLease> lease_latest(PairKey, Epoch);
  bool camera_applied(FrameKey);
  std::shared_ptr<const FrameView> ready(FrameKey);
  bool validate_transform(const WorldTransform &);
  void release();
  void resize(uint32_t, uint32_t);

private:
  void expire();
  void discard();
  Clock clock_;
  std::mutex mutex_;
  // Declaration order ensures the slot lease is released before mapping unmaps.
  std::shared_ptr<void> mapping_;
  std::shared_ptr<FrameView> frame_;
  FrameKey last_{};
  WorldTransform last_transform_{};
  bool have_last_ = false, acked_ = false, leased_ = false;
  uint64_t deadline_{};
};
} // namespace dstmc
