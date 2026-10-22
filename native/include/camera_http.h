#pragma once
#include "compositor.h"
namespace bridge {
dstmc::CameraService &camera_service();
bool enabled();
dstmc::FrameKey key();
void start(const char *directory);
void report_compose(const dstmc::RenderProbe &, dstmc::FrameKey,
                    const dstmc::ComposeResult &);
void present_window(int render_width, int render_height, bool composited);
} // namespace bridge
