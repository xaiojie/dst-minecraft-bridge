// clang-format off
#include <winsock2.h>
#include <windows.h>
#include <shellapi.h>
// clang-format on
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <stdexcept>

// Runs only on real Windows. No fake GLES/EGL modules and no rendered-success
// receipt are created. This checks DLL loading, loopback framing and
// fail-closed startup independently of any game installation.
static void require(bool condition, const char *why) {
  if (!condition)
    throw std::runtime_error(why);
}
static SOCKET connect_bridge() {
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET)
    return s;
  DWORD timeout = 1000;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char *>(&timeout),
             sizeof(timeout));
  setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char *>(&timeout),
             sizeof(timeout));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(39380);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof(addr))) {
    closesocket(s);
    return INVALID_SOCKET;
  }
  return s;
}
static std::string request(const std::string &bytes) {
  SOCKET s = connect_bridge();
  require(s != INVALID_SOCKET, "loopback connection failed");
  struct Close {
    SOCKET s;
    ~Close() { closesocket(s); }
  } close{s};
  size_t at = 0;
  while (at < bytes.size()) {
    int n = send(s, bytes.data() + at, int(bytes.size() - at), 0);
    require(n > 0, "request send failed");
    at += n;
  }
  std::string result;
  char data[4096];
  for (;;) {
    int n = recv(s, data, sizeof(data), 0);
    if (n == 0)
      break;
    require(n > 0, "response timeout/read failure");
    result.append(data, n);
    require(result.size() < 65536, "response too large");
  }
  return result;
}
int main() {
  std::filesystem::path directory;
  using Stop = void(WINAPI *)();
  Stop stop = nullptr;
  WSADATA data{};
  bool sockets = false;
  try {
    require(WSAStartup(MAKEWORD(2, 2), &data) == 0, "Winsock startup failed");
    sockets = true;
    // Refuse to interrogate another running bridge on the fixed protocol port.
    auto existing = connect_bridge();
    if (existing != INVALID_SOCKET) {
      closesocket(existing);
      throw std::runtime_error(
          "39380 already occupied; smoke requires an isolated process");
    }
    int argc = 0;
    auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    require(argv && argc == 2, "expected DLL path argument");
    std::filesystem::path dll = argv[1];
    LocalFree(argv);
    wchar_t temp[32768];
    auto n = GetTempPathW(32768, temp);
    require(n > 0 && n < 32768, "temporary path unavailable");
    directory =
        std::filesystem::path(temp) /
        (L"DSTMC smoke \u4e2d\u6587 " + std::to_wstring(GetCurrentProcessId()));
    require(std::filesystem::create_directory(directory),
            "temporary directory already exists");
    require(SetEnvironmentVariableW(L"DSTMC_PROBE_DIR", directory.c_str()),
            "environment failed");
    auto module = LoadLibraryW(dll.c_str());
    require(module != nullptr, "LoadLibraryW failed");
    stop = reinterpret_cast<Stop>(GetProcAddress(module, "DSTMC_Stop"));
    require(stop, "DSTMC_Stop export missing");
    bool ready = false;
    for (int i = 0; i < 100; i++) {
      std::ifstream log(directory / L"camera-gate.jsonl");
      std::string contents((std::istreambuf_iterator<char>(log)), {});
      if (contents.find("Windows ANGLE backend awaiting GLES/EGL exports") !=
          std::string::npos) {
        ready = true;
        break;
      }
      Sleep(50);
    }
    require(ready, "own DLL loopback startup was not observed");
    auto denied = request("GET /v2/window HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    require(denied.find("HTTP/1.1 409") != std::string::npos &&
                denied.find("no active session") != std::string::npos,
            "window activated without a session");
    auto chunks = request("POST /v2/camera/lease HTTP/1.1\r\nHost: "
                          "127.0.0.1\r\nTransfer-Encoding: chunked\r\nExpect: "
                          "100-continue\r\n\r\n2\r\n{}\r\n0\r\n\r\n");
    require(chunks.find("100 Continue") != std::string::npos &&
                chunks.find("409 Response") != std::string::npos &&
                chunks.find("unexpected fields") != std::string::npos,
            "chunked/continue framing failed");
    auto ambiguous =
        request("POST /v2/camera/lease HTTP/1.1\r\nContent-Length: "
                "2\r\nTransfer-Encoding: chunked\r\n\r\n{}");
    require(ambiguous.find("ambiguous framing") != std::string::npos,
            "ambiguous framing accepted");
    require(!std::filesystem::exists(directory / L"loaded.json"),
            "loaded receipt fabricated without ANGLE hooks");
    std::ifstream log(directory / L"camera-gate.jsonl");
    std::string contents((std::istreambuf_iterator<char>(log)), {});
    require(contents.find("\"event\":\"compose\"") == std::string::npos,
            "composition evidence fabricated");
    log.close();
    stop();
    stop = nullptr;
    bool closed = false;
    for (int i = 0; i < 100; i++) {
      auto s = connect_bridge();
      if (s == INVALID_SOCKET) {
        closed = true;
        break;
      }
      closesocket(s);
      Sleep(50);
    }
    require(closed, "stop did not close loopback listener");
    WSACleanup();
    sockets = false;
    std::filesystem::remove_all(directory);
    std::cout << "PASS Windows LoadLibrary UTF16 paths, loopback framing, no "
                 "false readiness/proof, stop\n";
    return 0;
  } catch (const std::exception &e) {
    if (stop)
      stop();
    if (sockets)
      WSACleanup();
    std::cerr << "FAIL " << e.what()
              << "; evidence directory: " << directory.u8string() << '\n';
    return 1;
  }
}
