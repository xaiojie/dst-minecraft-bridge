#include "gl_observer.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <vector>
using namespace dstmc;
int main(){std::ifstream f("../protocol/fixtures/frame-v2.bin",std::ios::binary);std::vector<uint8_t> data((std::istreambuf_iterator<char>(f)),{});assert(data.size()>4608);FrameKey key;std::memcpy(key.pair_hash.data(),data.data()+4112,32);std::memcpy(key.epoch.data(),data.data()+4144,16);key.id=detail::load<uint64_t>(data.data(),4160);bool called=false;bool ok=consume_frame(data.data(),data.size(),key,[&](const FrameView& view){called=true;assert(view.width==2&&view.height==2);assert(view.color);assert(!read_frame(data.data(),data.size(),key));});assert(ok&&called&&"consumer must receive leased FrameView");assert(read_frame(data.data(),data.size(),key));key.id++;assert(!consume_frame(data.data(),data.size(),key,[&](const FrameView&){assert(false);}));std::cout<<"PASS scoped_frame_consumer rejects_wrong_key releases_lease\n";}
