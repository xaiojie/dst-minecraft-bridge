#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include "gl_observer.h"
#include <OpenGL/gl.h>
#include <cstdlib>
#include <fstream>
#include <unistd.h>
namespace {
thread_local bool observing=false;
void (*original_flush)(id,SEL)=nullptr;
void (*original_dealloc)(id,SEL)=nullptr;
template<class F> void diagnostic(F fn) noexcept {if(observing)return;observing=true;try{fn();}catch(...){/* Diagnostics must never escape into the game's renderer. */}observing=false;}
void flush(id self,SEL cmd){diagnostic([]{dstmc::begin_present();});original_flush(self,cmd);}
void dealloc_context(id self,SEL cmd){auto c=[(NSOpenGLContext*)self CGLContextObj];diagnostic([&]{dstmc::forget_context(c);});original_dealloc(self,cmd);}
void draw_arrays(GLenum mode,GLint first,GLsizei count){glDrawArrays(mode,first,count);diagnostic([]{dstmc::after_draw("glDrawArrays");});}
void draw_elements(GLenum mode,GLsizei count,GLenum type,const GLvoid* indices){glDrawElements(mode,count,type,indices);diagnostic([]{dstmc::after_draw("glDrawElements");});}
CGLError destroy_context(CGLContextObj c){diagnostic([&]{dstmc::forget_context(c);});return CGLDestroyContext(c);}
#define INTERPOSE(replacement,original) __attribute__((used)) static struct {const void* replacement_ptr;const void* original_ptr;} hook_##original __attribute__((section("__DATA,__interpose")))={(const void*)&replacement,(const void*)&original}
INTERPOSE(draw_arrays,glDrawArrays);
INTERPOSE(draw_elements,glDrawElements);
INTERPOSE(destroy_context,CGLDestroyContext);
__attribute__((constructor)) void loaded(){@autoreleasepool {
 const char* dir=getenv("DSTMC_PROBE_DIR");if(!dir||!*dir)return;
 diagnostic([&]{dstmc::configure_probe(dir);Class cls=[NSOpenGLContext class];Method method=class_getInstanceMethod(cls,@selector(flushBuffer));if(!method)return;original_flush=(decltype(original_flush))method_setImplementation(method,(IMP)flush);
 // Add a class-local dealloc override so inherited NSObject dealloc is never changed.
 SEL selector=sel_registerName("dealloc");Method d=class_getInstanceMethod(cls,selector);original_dealloc=(decltype(original_dealloc))method_getImplementation(d);if(!class_addMethod(cls,selector,(IMP)dealloc_context,method_getTypeEncoding(d)))method_setImplementation(d,(IMP)dealloc_context);
 std::ofstream(std::string(dir)+"/loaded.json")<<"{\"schema\":1,\"pid\":"<<getpid()<<",\"architecture\":\"x86_64\",\"present_hook\":\"NSOpenGLContext.flushBuffer\",\"draw_hooks\":[\"glDrawArrays\",\"glDrawElements\"],\"synthetic_draws\":false}\n";
 });
}}
}
