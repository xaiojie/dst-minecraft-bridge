#pragma once
#include "compositor.h"
#include <string>
namespace bridge {
// Render-side proof, independent of offered/acknowledged camera leases. Callers
// serialize access with the window mutex. Query spelling is canonical and
// exact.
class WindowProof {
  std::optional<dstmc::FrameKey> frame_;
  uint64_t completed_at_ = 0;

public:
  static std::string request(const dstmc::FrameKey &key) {
    static const char hex[] = "0123456789abcdef";
    std::string path = "/v2/window?pair_hash=";
    for (uint8_t b : key.pair_hash) {
      path += hex[b >> 4];
      path += hex[b & 15];
    }
    path += "&epoch=";
    for (size_t i = 0; i < key.epoch.size(); ++i) {
      if (i == 4 || i == 6 || i == 8 || i == 10)
        path += '-';
      uint8_t b = key.epoch[i];
      path += hex[b >> 4];
      path += hex[b & 15];
    }
    return path;
  }
  void recorded(const dstmc::FrameKey &frame, uint64_t now) {
    frame_ = frame;
    completed_at_ = now;
  }
  bool accepts(const std::string &path, uint64_t now) const {
    return frame_ && path == request(*frame_) && now >= completed_at_ &&
           now - completed_at_ < 250;
  }
};
// Geometry may be used to resize the producer before the first composed frame.
// Its proof is deliberately distinct from WindowProof, which gates takeover.
class WindowGeometryProof {
  std::optional<dstmc::FrameKey> session_;
  uint64_t observed_at_ = 0;
public:
  void recorded(dstmc::FrameKey key,uint64_t now){session_=key;observed_at_=now;}
  bool accepts(const std::string &path,uint64_t now)const{
    if(!session_||now<observed_at_||now-observed_at_>=250)return false;
    auto expected=WindowProof::request(*session_);expected.replace(0,10,"/v2/window/geometry");
    return path==expected;
  }
};
dstmc::CameraService &camera_service();
bool enabled();
dstmc::FrameKey key();
void start(const char *directory);
void report_compose(const dstmc::RenderProbe &, dstmc::FrameKey,
                    const dstmc::ComposeResult &);
void present_window(int render_width, int render_height,
                    std::optional<dstmc::FrameKey> composited_frame);
} // namespace bridge
