#include "camera_service.h"
#include <cassert>
#include <iostream>
using namespace dstmc;
static std::shared_ptr<FrameView> frame(uint64_t id = 1) {
  auto f = std::make_shared<FrameView>();
  f->key.id = id;
  f->key.epoch[0] = 1;
  f->width = 960;
  f->height = 540;
  f->pose.position = {1, 2, 3};
  f->dst_origin = {10, 0, 20};
  f->mc_origin = {0, 0, 0};
  f->pose.view = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, -2, -3, 1};
  f->axes = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  return f;
}
int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--http-fixture") {
    std::string stop;
    std::getline(std::cin, stop);
    return 0;
  }
  uint64_t now = 1000;
  CameraService s([&] { return now; });
  auto f = frame();
  s.offer(f, {});
  auto l = s.lease_latest(f->key.pair_hash, f->key.epoch);
  assert(l && l->pose.position.x == 11 && l->pose.position.z == 23);
  auto next = frame(2);
  s.offer(next, {});
  assert(s.lease_latest(f->key.pair_hash, f->key.epoch)->key.id == 1 &&
         "lease_pins_matching_pose");
  assert(s.camera_applied(f->key));
  assert(s.ready(f->key));
  now += 250;
  assert(!s.ready(f->key) && "stale_frame_releases_camera");
  assert(!s.camera_applied(f->key) && "late_camera_ack_rejected");
  s.offer(f, {});
  assert(!s.lease_latest(f->key.pair_hash, f->key.epoch) &&
         "expired_frame_must_not_be_released_again");
  s.offer(next, {});
  assert(s.lease_latest(next->key.pair_hash, next->key.epoch));
  s.resize(1920, 1080);
  assert(!s.camera_applied(next->key) && "retina_resize_cancels_lease");
  auto newer = frame(3);
  s.offer(newer, {});
  s.release();
  assert(!s.camera_applied(newer->key));
  s.offer(newer, {});
  assert(!s.lease_latest(newer->key.pair_hash, newer->key.epoch) &&
         "release_invalidates_old_callbacks");
  auto other = frame(1);
  other->key.epoch[0] = 2;
  s.offer(other, {});
  assert(s.lease_latest(other->key.pair_hash, other->key.epoch));
  assert(!s.camera_applied(f->key));
  std::cout << "PASS lease_pins_matching_pose late_camera_ack_rejected "
               "stale_frame_releases_camera retina_resize_cancels_lease "
               "release_invalidates_old_callbacks\n";
}
