#include "camera_http.h"
#import <Cocoa/Cocoa.h>
#include <cassert>
#include <iostream>
namespace bridge { dstmc::WorldTransform parse_transform(NSDictionary *); }
int main() {
 @autoreleasepool {
  NSDictionary *good=@{@"dst_origin":@{@"x":@100,@"y":@2,@"z":@(-50)},@"mc_origin":@{@"x":@5,@"y":@64,@"z":@9},@"axes":@[@(-1),@0,@0,@0,@1,@0,@0,@0,@1]};
  auto t=bridge::parse_transform(good);
  assert(t.axes[0]==-1 && t.dst_origin.x==100 && t.mc_origin.y==64);
  dstmc::CameraService service([]{return 0;});
  auto f=std::make_shared<dstmc::FrameView>();
  f->dst_origin=t.dst_origin;f->mc_origin=t.mc_origin;f->axes=t.axes;f->key.id=1;
  service.offer(f,{});assert(service.lease_latest(f->key.pair_hash,f->key.epoch));
  assert(service.validate_transform(t));
  auto other=t;other.axes[0]=1;
  assert(!service.validate_transform(other));
  assert(!service.camera_applied(f->key) && !service.ready(f->key));
  assert(!service.lease_latest(f->key.pair_hash,f->key.epoch));
  for(id bad in @[[NSNull null],@[],@[@1,@0,@0,@0,@(-1),@0,@0,@0,@1],@[@2,@0,@0,@0,@1,@0,@0,@0,@1],@[@(-1),@YES,@0,@0,@1,@0,@0,@0,@1],@[@(-1),@"0",@0,@0,@1,@0,@0,@0,@1],@[@(-1),@0.1,@0,@0,@1,@0,@0,@0,@1],@[@(NAN),@0,@0,@0,@1,@0,@0,@0,@1]]) {
   NSMutableDictionary *status=[[good mutableCopy] autorelease];status[@"axes"]=bad;
   bool rejected=false;try{bridge::parse_transform(status);}catch(const std::exception&){rejected=true;}
   assert(rejected && "malformed_status_axes_fail_closed");
  }
  for(id bad in @[[NSNull null],@{},@{@"x":@100,@"y":@2,@"z":@(INFINITY)},@{@"x":@YES,@"y":@2,@"z":@(-50)}]) {
   NSMutableDictionary *status=[[good mutableCopy] autorelease];status[@"dst_origin"]=bad;
   bool rejected=false;try{bridge::parse_transform(status);}catch(const std::exception&){rejected=true;}
   assert(rejected && "malformed_origin_rejected");
  }
  for(NSString *key in @[@"axes",@"dst_origin",@"mc_origin"]) {
   NSMutableDictionary *status=[[good mutableCopy] autorelease];[status removeObjectForKey:key];
   bool rejected=false;try{bridge::parse_transform(status);}catch(const std::exception&){rejected=true;}
   assert(rejected && "missing_binding_metadata_rejected");
  }
  std::cout<<"PASS strict_status_transform_and_cached_binding_invalidation\n";
 }
}
