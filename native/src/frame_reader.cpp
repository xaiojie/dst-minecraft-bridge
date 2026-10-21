#include "gl_observer.h"
namespace dstmc {
bool consume_frame(const void* mapping,size_t length,FrameKey expected,const std::function<void(const FrameView&)>& consumer){
 auto frame=read_frame(mapping,length,expected);if(!frame)return false;consumer(*frame);return true;
}
}
