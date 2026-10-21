#import <Cocoa/Cocoa.h>
#include <OpenGL/gl.h>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
int main(){@autoreleasepool {
 const char* dir=getenv("DSTMC_PROBE_DIR");assert(dir);std::ifstream loaded(std::string(dir)+"/loaded.json");assert(loaded.good()&&"native extension constructor must record loading");
 NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAAccelerated,NSOpenGLPFADepthSize,24,0};NSOpenGLPixelFormat* pf=[[NSOpenGLPixelFormat alloc]initWithAttributes:attrs];NSOpenGLContext* c=[[NSOpenGLContext alloc]initWithFormat:pf shareContext:nil];assert(c);[c makeCurrentContext];glViewport(0,0,16,16);std::ofstream(std::string(dir)+"/capture.request")<<"default\n";[c flushBuffer];GLfloat v[]={0,0,0,1,0,0,0,1,0};glEnableClientState(GL_VERTEX_ARRAY);glVertexPointer(3,GL_FLOAT,0,v);glDrawArrays(GL_TRIANGLES,0,3);[c flushBuffer];std::ifstream draws(std::string(dir)+"/draws.jsonl");std::string line;std::getline(draws,line);assert(line.find("glDrawArrays")!=std::string::npos&&"imported draw hook must record actual draw");[NSOpenGLContext clearCurrentContext];[c release];[pf release];std::cout<<"PASS isolated_loader actual_NSOpenGL_present imported_draw_hook\n";
}}
