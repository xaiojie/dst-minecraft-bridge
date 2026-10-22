#define DSTMC_PIPELINE_TEST
#include "../src/entry.mm"
#include <cassert>
#include <iostream>
namespace bridge {
static bool active=true;static dstmc::FrameKey pending{};
dstmc::CameraService &camera_service(){static dstmc::CameraService service;return service;}
bool enabled(){return active;}
dstmc::FrameKey key(){return pending;}
void report_compose(const dstmc::RenderProbe &,dstmc::FrameKey,const dstmc::ComposeResult &){}
void present_window(int,int,std::optional<dstmc::FrameKey>){}
}
int main(){
  CGLPixelFormatAttribute attrs[]={kCGLPFAAccelerated,kCGLPFAColorSize,(CGLPixelFormatAttribute)24,kCGLPFADepthSize,(CGLPixelFormatAttribute)24,(CGLPixelFormatAttribute)0};CGLPixelFormatObj pf;GLint n;CGLContextObj ctx;
  assert(CGLChoosePixelFormat(attrs,&pf,&n)==kCGLNoError);assert(CGLCreateContext(pf,nullptr,&ctx)==kCGLNoError);CGLDestroyPixelFormat(pf);CGLSetCurrentContext(ctx);
  GLuint fbo,tex,db;glGenFramebuffersEXT(1,&fbo);glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,fbo);glGenTextures(1,&tex);glBindTexture(GL_TEXTURE_2D,tex);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2,2,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT,GL_COLOR_ATTACHMENT0_EXT,GL_TEXTURE_2D,tex,0);
  glGenRenderbuffersEXT(1,&db);glBindRenderbufferEXT(GL_RENDERBUFFER_EXT,db);glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT,GL_DEPTH_COMPONENT24,2,2);glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT,GL_DEPTH_ATTACHMENT_EXT,GL_RENDERBUFFER_EXT,db);
  glViewport(0,0,2,2);glClearDepth(1);glClearColor(0,0,1,1);glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);
  uint8_t color[16]={255,0,0,255,255,0,0,255,255,0,0,255,255,0,0,255},hud[16]={};float depth[4]={.5,.5,.5,.5};
  auto frame=std::make_shared<dstmc::FrameView>();frame->key.id=1;frame->width=frame->height=2;frame->axes={1,0,0,0,1,0,0,0,1};frame->color=color;frame->depth=(uint8_t*)depth;frame->hud=hud;
  frame->pose.view={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};frame->pose.projection={1,0,0,0,0,1,0,0,0,0,-1.01f,-1,0,0,-2.01f,0};
  auto &service=bridge::camera_service();service.offer(frame,{});service.lease_latest(frame->key.pair_hash,frame->key.epoch);service.camera_applied(frame->key);
  auto next=std::make_shared<dstmc::FrameView>();next->key.id=2;next->width=next->height=2;next->axes=frame->axes;next->pose=frame->pose;next->pose.view[12]=1;next->color=color;next->depth=(uint8_t*)depth;next->hud=hud;service.offer(next,{});service.lease_latest(next->key.pair_hash,next->key.epoch);bridge::pending=next->key;
  dstmc::RenderProbe ground;ground.frame_no=1;ground.target_id=fbo;ground.viewport={0,0,2,2};ground.depth_range={0,1};ground.depth_bits=24;ground.depth_enabled=ground.depth_mask=true;ground.program_fingerprint="833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4";ground.shader_matrices={{"MatrixV",0,frame->pose.view},{"MatrixP",1,frame->pose.projection}};
  bridge::after_draw(ground,[]{});auto sprite=ground;sprite.program_fingerprint="4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063";
  glDisable(GL_DEPTH_TEST);glDepthMask(GL_TRUE);bridge::before_draw(sprite);
  assert(bridge::context().displayed && bridge::context().displayed->key.id==1 && service.ready(frame->key));
  bridge::active=false;bridge::after_draw(sprite,[]{});assert(!glIsEnabled(GL_DEPTH_TEST));GLboolean mask;glGetBooleanv(GL_DEPTH_WRITEMASK,&mask);assert(mask);bridge::present();assert(!bridge::context().displayed);
  bridge::active=true;ground.frame_no++;bridge::after_draw(ground,[]{});auto post=ground;post.target_id=0;post.program_fingerprint="postprocess";glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,0);bridge::before_draw(post);
  assert(bridge::context().displayed && "ground_only_target_transition_composites");GLint restored;glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT,&restored);assert(restored==0);
  bridge::active=false;bridge::present();bridge::forget(ctx);glDeleteTextures(1,&tex);glDeleteRenderbuffersEXT(1,&db);glDeleteFramebuffersEXT(1,&fbo);CGLSetCurrentContext(nullptr);CGLDestroyContext(ctx);
  std::cout<<"PASS camera_cycle_renders_acknowledged_pose input_toggle_restores_GL ground_only_scene_composites\n";
}
