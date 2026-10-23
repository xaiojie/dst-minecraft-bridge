#pragma once
#include "contracts.h"
#include <atomic>
#include <filesystem>
#include <nlohmann/json.hpp>
#include <windows.h>
#include <winsock2.h>
namespace winbridge {
using Json = nlohmann::ordered_json;
struct Shared {
  dstmc::CameraService service;
  std::mutex mutex, log_mutex;
  dstmc::FrameKey key{};
  Proof proof;
  std::optional<dstmc::FrameKey> last_reported;
  Json geometry;
  bool session = false;
  std::atomic<bool> stop{false}, input_mc{true};
  uint64_t input_version = 0, geometry_at = 0;
  std::filesystem::path directory, mailbox;
  HWND window{};
};
Shared &shared();
uint64_t now();
void log(const std::string &event, const std::string &reason);
void invalidate(const std::string &why);
void present(HWND window, int width, int height,
             std::optional<dstmc::FrameKey> frame);
bool install_render();
void stop_render();
} // namespace winbridge
