#include "camera_http.h"
#include <cassert>
#include <iostream>
int main(){
  bridge::WindowGeometryProof geometry;
  bridge::WindowProof composed;
  dstmc::FrameKey key{};key.id=1;key.epoch[0]=4;key.pair_hash[0]=2;
  auto path=bridge::WindowProof::request(key);path.replace(0,10,"/v2/window/geometry");
  assert(!geometry.accepts(path,100));
  geometry.recorded(key,100);
  assert(geometry.accepts(path,100));
  assert(!composed.accepts(bridge::WindowProof::request(key),100));
  assert(!geometry.accepts(path,350));
  assert(!geometry.accepts(path,99));
  auto other=key;other.epoch[0]=5;
  auto other_path=bridge::WindowProof::request(other);other_path.replace(0,10,"/v2/window/geometry");
  assert(!geometry.accepts(other_path,101));
  assert(!geometry.accepts(bridge::WindowProof::request(key),101));
  std::cout<<"PASS geometry_bootstraps_without_composition_or_cross_session_activation\n";
}
