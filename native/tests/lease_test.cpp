#include "camera_http.h"
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
  {
    bridge::WindowProof proof;
    FrameKey a{}, b{};
    a.pair_hash[0] = 1;
    a.epoch[0] = 1;
    b = a;
    b.epoch[0] = 2;
    assert(!proof.accepts(bridge::WindowProof::request(a), 1000));
    proof.recorded(a, 1000);
    assert(proof.accepts(bridge::WindowProof::request(a), 1010));
    assert(!proof.accepts(bridge::WindowProof::request(b), 1010) &&
           "fresh_B_request_must_reject_A_composite");
    b = a;
    b.pair_hash[0] = 2;
    assert(!proof.accepts(bridge::WindowProof::request(b), 1010));
    assert(!proof.accepts("/v2/window", 1010));
    assert(!proof.accepts(bridge::WindowProof::request(a) + "&extra=1", 1010));
    assert(!proof.accepts(bridge::WindowProof::request(a), 1250));
    proof.recorded(b, 1260);
    assert(proof.accepts(bridge::WindowProof::request(b), 1261));
    assert(!proof.accepts(bridge::WindowProof::request(a), 1261));
    std::cout << "PASS window_proof_current_identity_only "
                 "missing_and_expired_proof_rejected\n";
  }
  {
    CameraService reflected([] { return 1000; });
    auto f = frame(); f->axes[0] = -1; f->mc_origin = {5, 7, 9};
    f->pose.forward = {1, 0, 0}; f->pose.up = {0, 1, 0};
    reflected.offer(f, {});
    auto l = reflected.lease_latest(f->key.pair_hash, f->key.epoch);
    assert(l && l->pose.position.x == 14 && l->pose.position.y == -5 && l->pose.position.z == 14 && "reflected_position_about_nonzero_origins");
    assert(l->pose.forward.x == -1 && l->pose.up.y == 1 && "directions_use_axes_without_translation");
    assert(l->pose.view[0] == -1 && l->pose.view[12] == 14 && l->pose.view[13] == 5 && l->pose.view[14] == -14 && "converted_view_preserves_rays");
    auto rotated = pose_to_dst(*f,FramePose{{1,2,3},{1,0,0},{0,1,0},{0,0,1,0,0,1,0,0,-1,0,0,0,3,-2,-1,1},{}});
    assert(rotated.view[2]==-1 && rotated.view[12]==14 && rotated.view[13]==5 && rotated.view[14]==14 && "rotated_view_uses_column_major_transform");
    auto changed = frame(2); reflected.offer(changed, {});
    assert(!reflected.lease_latest(f->key.pair_hash, f->key.epoch) && "changed_transform_invalidates_cached_frame");
    std::cout << "PASS reflected_lease_and_transform_mismatch\n";
  }
  uint64_t now = 1000;
  CameraService s([&] { return now; });
  auto f = frame();
  s.offer(f, {});
  auto l = s.lease_latest(f->key.pair_hash, f->key.epoch);
  assert(l && l->pose.position.x == 11 && l->pose.position.z == 23);
  assert(s.camera_applied(f->key));
  assert(s.ready(f->key));
  // A newer frame is available for the next lease but must not disturb the
  // pose the client has already applied and confirmed.
  auto next = frame(2);
  s.offer(next, {});
  assert(s.ready(f->key) && "newer_offer_keeps_pinned_frame");
  assert(!s.ready(next->key));
  auto pinned = s.lease_latest(next->key.pair_hash, next->key.epoch);
  assert(pinned && pinned->key.id == 2 && "lease_pins_newest_frame");
  assert(!s.ready(next->key) && "new_lease_requires_new_ack");
  assert(s.camera_applied(next->key));
  assert(s.ready(next->key) && "acked_frame_composites_on_every_draw");
  assert(s.ready(next->key) && "pin_survives_presentation");
  now += 1000;
  assert(!s.ready(next->key) && "stale_frame_releases_camera");
  assert(!s.camera_applied(next->key) && "late_camera_ack_rejected");
  // Offering a frame is not the same as leasing it.
  auto later = frame(4);
  s.offer(later, {});
  assert(!s.ready(later->key) && "offer_alone_does_not_pin");
  s.lease_latest(later->key.pair_hash, later->key.epoch);
  assert(s.camera_applied(later->key) && s.ready(later->key));
  s.resize(1920, 1080);
  assert(!s.ready(later->key) && "retina_resize_cancels_lease");
  assert(!s.lease_latest(later->key.pair_hash, later->key.epoch) &&
         "resize_discards_frames");
  auto newer = frame(5);
  s.offer(newer, {});
  assert(s.lease_latest(newer->key.pair_hash, newer->key.epoch));
  s.release();
  assert(!s.camera_applied(newer->key));
  assert(!s.lease_latest(newer->key.pair_hash, newer->key.epoch) &&
         "release_invalidates_old_callbacks");
  auto other = frame(6);
  other->key.epoch[0] = 2;
  s.offer(other, {});
  assert(s.lease_latest(other->key.pair_hash, other->key.epoch));
  assert(!s.camera_applied(f->key));
  std::cout << "PASS lease_pins_newest_frame late_camera_ack_rejected "
               "stale_frame_releases_camera retina_resize_cancels_lease "
               "release_invalidates_old_callbacks\n";
}
