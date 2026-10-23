#pragma once
#include "camera_service.h"
#include <algorithm>
#include <string>
namespace winbridge {
inline bool valid_mapping_size(uint64_t n) {
  return n >= 4096 && n <= 80ull * 1024 * 1024;
}
struct Proof {
  std::optional<dstmc::FrameKey> key;
  uint64_t time{};
  void clear() { key.reset(); }
  void record(dstmc::FrameKey k, uint64_t t) {
    key = k;
    time = t;
  }
  bool accepts(const dstmc::FrameKey &k, uint64_t now) const {
    return key && key->pair_hash == k.pair_hash && key->epoch == k.epoch &&
           now >= time && now - time < 250;
  }
};
inline bool inverse(const std::array<float, 16> &a,
                    std::array<float, 16> &out) {
  double m[4][8]{};
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      m[r][c] = a[c * 4 + r];
      m[r][c + 4] = r == c;
    }
  for (int c = 0; c < 4; c++) {
    int p = c;
    for (int r = c + 1; r < 4; r++)
      if (std::abs(m[r][c]) > std::abs(m[p][c]))
        p = r;
    if (!std::isfinite(m[p][c]) || std::abs(m[p][c]) < 1e-12)
      return false;
    for (int j = 0; j < 8; j++)
      std::swap(m[p][j], m[c][j]);
    double s = m[c][c];
    for (auto &v : m[c])
      v /= s;
    for (int r = 0; r < 4; r++)
      if (r != c) {
        s = m[r][c];
        for (int j = 0; j < 8; j++)
          m[r][j] -= s * m[c][j];
      }
  }
  for (int r = 0; r < 4; r++)
    for (int c = 0; c < 4; c++) {
      out[c * 4 + r] = float(m[r][c + 4]);
      if (!std::isfinite(out[c * 4 + r]))
        return false;
    }
  return true;
}
inline bool compose_before_target_draw(bool captured, bool composed,
                                       bool failed, int world_target,
                                       int draw_target) {
  return captured && !composed && !failed && world_target != draw_target;
}
inline bool compose_before_blit(bool captured, bool composed, bool failed,
                                int world_target, int read_target,
                                int draw_target, unsigned mask) {
  return captured && !composed && !failed && world_target == read_target &&
         read_target != draw_target && (mask & 0x4000u);
}
inline bool camera_matches(const dstmc::FrameView &frame,
                           const std::array<float, 16> &view,
                           const std::array<float, 16> &projection, int width,
                           int height) {
  if (width != int(frame.width) || height != int(frame.height) ||
      !dstmc::valid_transform(frame))
    return false;
  auto expected = dstmc::pose_to_dst(frame, frame.pose).view;
  for (int i = 0; i < 16; i++) {
    if (!std::isfinite(view[i]) || !std::isfinite(expected[i]) ||
        std::abs(view[i] - expected[i]) > .001)
      return false;
    if (!std::isfinite(projection[i]) ||
        !std::isfinite(frame.pose.projection[i]) ||
        (i != 10 && i != 14 &&
         std::abs(projection[i] - frame.pose.projection[i]) > .0002))
      return false;
  }
  return true;
}
inline std::string hex(const uint8_t *p, size_t n) {
  const char *h = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; i++) {
    s += h[p[i] >> 4];
    s += h[p[i] & 15];
  }
  return s;
}
inline std::string epoch(const dstmc::FrameKey &k) {
  auto s = hex(k.epoch.data(), 16);
  return s.substr(0, 8) + "-" + s.substr(8, 4) + "-" + s.substr(12, 4) + "-" +
         s.substr(16, 4) + "-" + s.substr(20);
}
inline std::string query(const dstmc::FrameKey &k) {
  return "?pair_hash=" + hex(k.pair_hash.data(), 32) + "&epoch=" + epoch(k);
}
} // namespace winbridge
