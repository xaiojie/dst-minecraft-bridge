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
  // Pinned by a lease, whether or not the client has acknowledged it yet.
  std::shared_ptr<const FrameView> pinned(FrameKey);
  bool validate_transform(const WorldTransform &);
  void release();
  void resize(uint32_t, uint32_t);
  // Read-only snapshot of the rendezvous, recorded with each gate event so the
  // acceptance log can show whether a frame was pinned/acknowledged at compose
  // time.
  struct LeaseState {
    bool pinned = false, acked = false, leased = false;
    uint64_t key_id = 0;
    uint64_t remaining_ms = 0;
  };
  LeaseState lease_state();

private:
  void expire();
  void discard();
  Clock clock_;
  mutable std::mutex mutex_;
  // Declaration order ensures the slot lease is released before mapping unmaps.
  std::shared_ptr<void> mapping_;
  std::shared_ptr<FrameView> frame_;
  // Newest offered frame; the next lease pins it at its own pose.
  std::shared_ptr<void> latest_mapping_;
  std::shared_ptr<FrameView> latest_;
  FrameKey last_{};
  WorldTransform last_transform_{};
  bool have_last_ = false, acked_ = false, leased_ = false;
  uint64_t deadline_{};
};
} // namespace dstmc
