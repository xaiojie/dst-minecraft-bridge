#include "gl_observer.h"
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <cassert>
#include <iostream>
#include <vector>
#include <fstream>
#include <filesystem>
#include <unistd.h>
using namespace dstmc;
static CGLContextObj context() {
 CGLPixelFormatAttribute attrs[]={kCGLPFAAccelerated,kCGLPFAColorSize,(CGLPixelFormatAttribute)24,kCGLPFADepthSize,(CGLPixelFormatAttribute)24,(CGLPixelFormatAttribute)0};
 CGLPixelFormatObj pf=nullptr;GLint count=0;assert(CGLChoosePixelFormat(attrs,&pf,&count)==kCGLNoError);
 CGLContextObj ctx=nullptr;assert(CGLCreateContext(pf,nullptr,&ctx)==kCGLNoError);CGLDestroyPixelFormat(pf);assert(CGLSetCurrentContext(ctx)==kCGLNoError);return ctx;
}
static GLuint program() {
 const char* vs="#version 120\nuniform mat4 MatrixP; void main(){gl_Position=MatrixP*gl_Vertex;}";
 const char* fs="#version 120\nvoid main(){if(gl_FragCoord.x<0.0)discard;gl_FragColor=vec4(1.0);}\n";
 GLuint v=glCreateShader(GL_VERTEX_SHADER),f=glCreateShader(GL_FRAGMENT_SHADER);glShaderSource(v,1,&vs,nullptr);glCompileShader(v);glShaderSource(f,1,&fs,nullptr);glCompileShader(f);
 GLuint p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);GLint linked=0;glGetProgramiv(p,GL_LINK_STATUS,&linked);assert(linked);glDeleteShader(v);glDeleteShader(f);return p;
}
static std::vector<GLint> state() {
 std::vector<GLint> v;GLint a[4];glGetIntegerv(GL_VIEWPORT,a);v.insert(v.end(),a,a+4);
 for(GLenum e:{GL_ACTIVE_TEXTURE,GL_TEXTURE_BINDING_2D,GL_CURRENT_PROGRAM,GL_FRAMEBUFFER_BINDING_EXT,GL_PIXEL_PACK_BUFFER_BINDING,GL_PACK_ALIGNMENT,GL_PACK_ROW_LENGTH,GL_PACK_SKIP_ROWS,GL_PACK_SKIP_PIXELS,GL_PACK_SWAP_BYTES,GL_READ_BUFFER,GL_DEPTH_FUNC,GL_BLEND_SRC_RGB,GL_BLEND_DST_RGB,GL_BLEND_SRC_ALPHA,GL_BLEND_DST_ALPHA,GL_BLEND_EQUATION_RGB,GL_BLEND_EQUATION_ALPHA}) {glGetIntegerv(e,a);v.push_back(a[0]);}
 for(GLenum e:{GL_BLEND,GL_DEPTH_TEST,GL_DEPTH_WRITEMASK}) {GLboolean b;glGetBooleanv(e,&b);v.push_back(b);}
 GLdouble r[2];glGetDoublev(GL_DEPTH_RANGE,r);v.push_back(r[0]*1000);v.push_back(r[1]*1000);return v;
}
int main() {
 auto c=context();GLuint tex,fbo,depth,pack;glGenTextures(1,&tex);glActiveTexture(GL_TEXTURE3);glBindTexture(GL_TEXTURE_2D,tex);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,32,32,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
 glGenFramebuffersEXT(1,&fbo);glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,fbo);glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT,GL_COLOR_ATTACHMENT0_EXT,GL_TEXTURE_2D,tex,0);
 glGenRenderbuffersEXT(1,&depth);glBindRenderbufferEXT(GL_RENDERBUFFER_EXT,depth);glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT,GL_DEPTH_COMPONENT24,32,32);glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT,GL_DEPTH_ATTACHMENT_EXT,GL_RENDERBUFFER_EXT,depth);assert(glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT)==GL_FRAMEBUFFER_COMPLETE_EXT);
 glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);glViewport(3,4,16,12);glEnable(GL_BLEND);glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ZERO);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LEQUAL);glDepthRange(.2,.8);
 glClearColor(.25,.5,.75,1);glClearDepth(.375);glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);glDepthMask(GL_FALSE);
 auto p=program();glUseProgram(p);float matrix[16]={2,0,0,0,0,3,0,0,0,0,4,0,5,6,7,1};glUniformMatrix4fv(glGetUniformLocation(p,"MatrixP"),1,GL_FALSE,matrix);
 glGenBuffers(1,&pack);glBindBuffer(GL_PIXEL_PACK_BUFFER,pack);glBufferData(GL_PIXEL_PACK_BUFFER,8192,nullptr,GL_STREAM_READ);glPixelStorei(GL_PACK_ALIGNMENT,8);glPixelStorei(GL_PACK_ROW_LENGTH,33);glPixelStorei(GL_PACK_SKIP_ROWS,2);glPixelStorei(GL_PACK_SKIP_PIXELS,1);glPixelStorei(GL_PACK_SWAP_BYTES,GL_TRUE);
 auto before=state();auto capture=capture_probe_frame();assert(capture.color.size()==16*12*4 && "capture must read actual current FBO viewport");assert(capture.depth.size()==16*12);assert(capture.color[0]>=63&&capture.color[0]<=64);assert(std::abs(capture.depth[0]-.375)<.001);assert(before==state()&&"gl_state_restored");
 auto probe=inspect_draw("test");assert(probe.context_id!=0);assert(probe.shader_matrices.size()==1);assert(probe.shader_matrices[0].name=="MatrixP");assert(probe.shader_matrices[0].value[0]==2 && probe.shader_matrices[0].value[13]==6);assert(probe.shader_sources.size()==2&&"linked_shader_sources_must_be_fingerprinted");bool fragment=false;for(const auto& shader:probe.shader_sources){if(shader.type==GL_FRAGMENT_SHADER){fragment=true;assert(shader.source_available&&shader.contains_discard);assert(shader.sha256=="cefbc84fea6d2fb8cf35e56cf72316a5a782933e9c2a3fba2d801ec04a82126b");}}assert(fragment&&!probe.program_fingerprint.empty());assert(probe.target_id==(int)fbo);std::cerr<<"observed depth bits="<<probe.depth_bits<<"\n";assert(probe.depth_bits>=24);assert(glGetError()==GL_NO_ERROR);
 char directory[]="/tmp/dstmc-gl-checkpoints-XXXXXX";assert(mkdtemp(directory));configure_probe(directory);std::ofstream(std::string(directory)+"/capture.request")<<"checkpoints 3 5\n";begin_present();for(int i=0;i<6;i++)after_draw("test-checkpoint");begin_present();std::string capture_prefix=std::string(directory)+"/ctx"+std::to_string(probe.context_id)+"-f1-d";assert(std::filesystem::exists(capture_prefix+"3.json")&&"requested_draw_checkpoint_must_be_captured");assert(std::filesystem::exists(capture_prefix+"5.json"));assert(!std::filesystem::exists(capture_prefix+"1.json")&&"explicit_selection_must_not_spend_budget_on_early_targets");
 std::ofstream(std::string(directory)+"/capture.request")<<"checkpoints 1 2 3 4 5 6 7 8\n";begin_present();assert(std::filesystem::exists(std::string(directory)+"/request-error.json")&&"unbounded_checkpoint_request_must_be_rejected");std::ofstream(std::string(directory)+"/capture.request")<<"metadata\n";begin_present();after_draw("metadata-1");after_draw("metadata-2");begin_present();std::string metadata_prefix=std::string(directory)+"/ctx"+std::to_string(probe.context_id)+"-f4-d";assert(!std::filesystem::exists(metadata_prefix+"1.json")&&"metadata_request_must_not_capture_early_draws");assert(std::filesystem::exists(metadata_prefix+"2.json"));configure_probe("");std::filesystem::remove_all(directory);
 glReadBuffer(GL_NONE);auto unreadable=capture_probe_frame();assert(unreadable.color.empty()&&"disabled_read_buffer_must_not_issue_readback");assert(unreadable.error=="disabled_read_buffer");assert(glGetError()==GL_NO_ERROR);glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);
 GLuint multisample,color_ms,depth_ms;glGenFramebuffersEXT(1,&multisample);glBindFramebufferEXT(GL_FRAMEBUFFER_EXT,multisample);glGenRenderbuffersEXT(1,&color_ms);glBindRenderbufferEXT(GL_RENDERBUFFER_EXT,color_ms);glRenderbufferStorageMultisampleEXT(GL_RENDERBUFFER_EXT,4,GL_RGBA8,32,32);glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT,GL_COLOR_ATTACHMENT0_EXT,GL_RENDERBUFFER_EXT,color_ms);glGenRenderbuffersEXT(1,&depth_ms);glBindRenderbufferEXT(GL_RENDERBUFFER_EXT,depth_ms);glRenderbufferStorageMultisampleEXT(GL_RENDERBUFFER_EXT,4,GL_DEPTH_COMPONENT24,32,32);glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT,GL_DEPTH_ATTACHMENT_EXT,GL_RENDERBUFFER_EXT,depth_ms);assert(glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT)==GL_FRAMEBUFFER_COMPLETE_EXT);auto multi=capture_probe_frame();assert(multi.color.empty()&&"multisample_FBO_must_not_issue_readback");assert(multi.error=="multisample_framebuffer_requires_resolve");assert(glGetError()==GL_NO_ERROR);
 auto old=probe.context_id;forget_context(c);CGLSetCurrentContext(nullptr);CGLDestroyContext(c);c=context();auto fresh=inspect_draw("new-context");assert(fresh.context_id!=old&&"context_recreated");assert(fresh.program==0);assert(fresh.target_id==0);forget_context(c);CGLSetCurrentContext(nullptr);CGLDestroyContext(c);
 std::cout<<"PASS gl_state_restored shader_matrices actual_color_depth context_recreated\n";
}
