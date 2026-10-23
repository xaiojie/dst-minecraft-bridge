#include "depth_replay.h"
#include "contracts.h"
#include <cassert>
#include <fstream>
#include <vector>
int main() {
  struct ReplayApi {
    int texture=17,saved_texture=17,allocations=0,clears=0;
    bool clipped=true,stencil=false;
    bool stencil_enabled(){return stencil;}
    bool scissor_enabled(){return clipped;}
    void scissor(bool value){clipped=value;}
    bool allocate(){allocations++;texture=99;return true;}
    void restore_samplers(){texture=saved_texture;}
    void bind_depth_target(){}
    void configure_depth(){}
    void clear_depth(){assert(!clipped);clears++;}
  } replay_api;
  int replayed=0;
  auto draw=[&]{assert(replay_api.texture==17);assert(replay_api.clipped);replayed++;};
  assert(winbridge::capture_depth(replay_api,true,draw)==winbridge::ReplayResult::CAPTURED);
  assert(replayed==1&&replay_api.clears==1&&replay_api.clipped);
  replay_api.stencil=true;
  assert(winbridge::capture_depth(replay_api,false,draw)==winbridge::ReplayResult::STENCIL_UNSUPPORTED);
  assert(replayed==1&&replay_api.allocations==1);

  using namespace winbridge;
  dstmc::FrameKey k{};
  k.id = 1;
  Proof p;
  assert(!p.accepts(k, 10));
  p.record(k, 10);
  assert(p.accepts(k, 259));
  assert(!p.accepts(k, 260));
  auto other = k;
  other.epoch[0] = 1;
  assert(!p.accepts(other, 20));
  assert(!p.accepts(k, 9));
  p.clear();
  assert(!p.accepts(k, 10));
  assert(valid_mapping_size(4096));
  assert(!valid_mapping_size(80ull * 1024 * 1024 + 1));
  assert(!valid_mapping_size(4095));
  std::array<float, 16> a{}, b{};
  a[0] = a[5] = a[10] = a[15] = 1;
  assert(inverse(a, b));
  assert(a == b);
  a[0] = 0;
  assert(!inverse(a, b));
  uint64_t time = 1000;
  dstmc::CameraService service([&] { return time; });
  auto frame = std::make_shared<dstmc::FrameView>();
  frame->key = k;
  frame->width = 2;
  frame->height = 2;
  frame->axes = {-1, 0, 0, 0, 1, 0, 0, 0, 1};
  service.offer(frame, {});
  auto lease = service.lease_latest(k.pair_hash, k.epoch);
  assert(lease);
  assert(!service.ready(k));
  assert(service.camera_applied(k));
  assert(service.ready(k));
  assert(!service.camera_applied(other));
  time += 1000;
  assert(!service.ready(k));
  assert(!service.pinned(k));
  std::ifstream input("../protocol/fixtures/frame-v2.bin", std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
  assert(bytes.size() > 4096);
  dstmc::FrameKey fixture{};
  std::memcpy(fixture.pair_hash.data(), bytes.data() + 4112, 32);
  std::memcpy(fixture.epoch.data(), bytes.data() + 4144, 16);
  fixture.id = dstmc::detail::load<uint64_t>(bytes.data(), 4160);
  {
    auto view = dstmc::read_frame(bytes.data(), bytes.size(), fixture);
    assert(view);
    assert(view->width == 2 && view->height == 2);
    assert(!dstmc::read_frame(bytes.data(), bytes.size(), fixture));
  }
  assert(dstmc::read_frame(bytes.data(), bytes.size(), fixture));
  fixture.epoch[0] ^= 1;
  assert(!dstmc::read_frame(bytes.data(), bytes.size(), fixture));
  assert(!dstmc::read_frame(bytes.data(), 4095, fixture));
  dstmc::FrameView camera;
  camera.width = 960;
  camera.height = 540;
  camera.axes = {-1, 0, 0, 0, 1, 0, 0, 0, 1};
  camera.pose.view[0] = camera.pose.view[5] = camera.pose.view[10] =
      camera.pose.view[15] = 1;
  camera.pose.projection = camera.pose.view;
  auto observed = dstmc::pose_to_dst(camera, camera.pose).view;
  auto projection = camera.pose.projection;
  assert(camera_matches(camera, observed, projection, 960, 540));
  assert(!camera_matches(camera, observed, projection, 800, 540));
  projection[10] = -.5f;
  projection[14] = -.2f;
  assert(camera_matches(camera, observed, projection, 960, 540));
  projection[0] = 2;
  assert(!camera_matches(camera, observed, projection, 960, 540));
  projection = camera.pose.projection;
  observed[12] = 1;
  assert(!camera_matches(camera, observed, projection, 960, 540));
  assert(compose_before_target_draw(true, false, false, 7, 0));
  assert(!compose_before_target_draw(true, false, false, 7, 7));
  assert(!compose_before_target_draw(true, true, false, 7, 0));
  assert(!compose_before_target_draw(true, false, true, 7, 0));
  assert(!compose_before_target_draw(false, false, false, 7, 0));
  assert(compose_before_blit(true, false, false, 7, 7, 0, 0x4000));
  assert(!compose_before_blit(true, false, false, 7, 3, 0, 0x4000));
  assert(!compose_before_blit(true, false, false, 7, 7, 7, 0x4000));
  assert(!compose_before_blit(true, false, false, 7, 7, 0, 0x0100));
  assert(!compose_before_blit(true, true, false, 7, 7, 0, 0x4000));
  assert(!compose_before_blit(true, false, true, 7, 7, 0, 0x4000));
}
