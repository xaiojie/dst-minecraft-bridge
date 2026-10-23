#include "backend.h"
#include <bcrypt.h>
#include <fstream>
#include <sstream>
#include <thread>
#include <vector>
#include <winhttp.h>
namespace winbridge {
Shared &shared() {
  static auto *s = new Shared;
  return *s;
}
uint64_t now() { return GetTickCount64(); }
void log(const std::string &e, const std::string &r) {
  auto &s = shared();
  std::lock_guard<std::mutex> l(s.log_mutex);
  std::ofstream f(s.directory / L"camera-gate.jsonl", std::ios::app);
  f << Json{{"t", now()}, {"event", e}, {"reason", r}}.dump() << '\n';
}
void atomic_record(const std::filesystem::path &path, const Json &value) {
  auto temp = path;
  temp += L".tmp";
  {
    std::ofstream out(temp);
    out << value.dump();
    out.flush();
    if (!out)
      throw std::runtime_error("record write failed");
  }
  if (!MoveFileExW(temp.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("record atomic replace failed");
}
void compose_record(const dstmc::FrameKey &key, int width, int height) {
  auto &s = shared();
  std::lock_guard<std::mutex> l(s.log_mutex);
  std::ofstream out(s.directory / L"camera-gate.jsonl", std::ios::app);
  out << Json{{"event", "compose"}, {"status", 0},    {"frame", key.id},
              {"t", now()},         {"width", width}, {"height", height}}
             .dump()
      << '\n';
}
void invalidate(const std::string &why) {
  auto &s = shared();
  s.service.release();
  {
    std::lock_guard<std::mutex> l(s.mutex);
    s.proof.clear();
  }
  log("gate_closed", why);
}
std::wstring wide(const std::string &s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(),
                              int(s.size()), nullptr, 0);
  if (!n)
    throw std::runtime_error("invalid UTF-8 path");
  std::wstring w(n, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()),
                      w.data(), n);
  return w;
}
void fields(const Json &j, std::initializer_list<const char *> names) {
  if (!j.is_object() || j.size() != names.size())
    throw std::runtime_error("unexpected fields");
  for (auto n : names)
    if (!j.contains(n))
      throw std::runtime_error("missing field");
}
uint64_t integer(const Json &j, uint64_t max, bool positive = false) {
  if (!j.is_number_integer() || j.is_boolean() ||
      j.get<double>() < double(positive) || j.get<double>() > double(max))
    throw std::runtime_error("invalid integer");
  return j.get<uint64_t>();
}
std::array<uint8_t, 16> uuid(const Json &j) {
  auto s = j.get<std::string>();
  if (s.size() != 36)
    throw std::runtime_error("invalid UUID");
  std::array<uint8_t, 16> out{};
  size_t k = 0;
  auto nib = [](char c) {
    if (c >= '0' && c <= '9')
      return c - '0';
    if (c >= 'a' && c <= 'f')
      return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
      return c - 'A' + 10;
    throw std::runtime_error("invalid UUID hex");
  };
  for (size_t i = 0; i < 36;) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (s[i++] != '-')
        throw std::runtime_error("invalid UUID separator");
    } else {
      out[k++] = uint8_t(nib(s[i]) * 16 + nib(s[i + 1]));
      i += 2;
    }
  }
  return out;
}
dstmc::FrameKey parse_key(const Json &j) {
  fields(j, {"pair", "epoch", "id"});
  auto &p = j.at("pair");
  fields(p, {"dst_world", "dst_shard", "mc_world", "mc_dimension", "region"});
  Json canonical = Json::object();
  for (auto n :
       {"dst_world", "dst_shard", "mc_world", "mc_dimension", "region"}) {
    auto v = p.at(n).get<std::string>();
    if (v.empty())
      throw std::runtime_error("empty pair field");
    if (std::string(n) == "dst_world" || std::string(n) == "mc_world") {
      uuid(v);
      std::transform(v.begin(), v.end(), v.begin(),
                     [](unsigned char c) { return char(std::tolower(c)); });
    }
    canonical[n] = v;
  }
  auto data = canonical.dump(-1, ' ', false, Json::error_handler_t::strict);
  dstmc::FrameKey k{};
  BCRYPT_ALG_HANDLE algorithm{};
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                  0) < 0)
    throw std::runtime_error("SHA256 provider unavailable");
  auto result =
      BCryptHash(algorithm, nullptr, 0, reinterpret_cast<PUCHAR>(data.data()),
                 ULONG(data.size()), k.pair_hash.data(), 32);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (result < 0)
    throw std::runtime_error("SHA256 failed");
  k.epoch = uuid(j.at("epoch"));
  k.id = integer(j.at("id"), 9007199254740991ull);
  return k;
}
struct Internet {
  HINTERNET h{};
  ~Internet() {
    if (h)
      WinHttpCloseHandle(h);
  }
};
Json status() {
  Internet session{WinHttpOpen(L"DSTMC/2", WINHTTP_ACCESS_TYPE_NO_PROXY,
                               nullptr, nullptr, 0)};
  if (!session.h)
    throw std::runtime_error("status session failed");
  WinHttpSetTimeouts(session.h, 150, 150, 150, 150);
  Internet connection{WinHttpConnect(session.h, L"127.0.0.1", 39379, 0)};
  Internet request{WinHttpOpenRequest(connection.h, L"GET", L"/v2/status",
                                      nullptr, WINHTTP_NO_REFERER,
                                      WINHTTP_DEFAULT_ACCEPT_TYPES, 0)};
  DWORD disable = WINHTTP_DISABLE_REDIRECTS;
  WinHttpSetOption(request.h, WINHTTP_OPTION_DISABLE_FEATURE, &disable,
                   sizeof(disable));
  if (!request.h ||
      !WinHttpSendRequest(request.h, nullptr, 0, nullptr, 0, 0, 0) ||
      !WinHttpReceiveResponse(request.h, nullptr))
    throw std::runtime_error("MC status unavailable");
  DWORD code = 0, n = sizeof(code);
  if (!WinHttpQueryHeaders(
          request.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
          nullptr, &code, &n, nullptr) ||
      code != 200)
    throw std::runtime_error("MC status rejected");
  std::string data;
  char buf[4096];
  DWORD got;
  do {
    if (!WinHttpReadData(request.h, buf, sizeof(buf), &got) ||
        data.size() + got > 65536)
      throw std::runtime_error("invalid status length");
    data.append(buf, got);
  } while (got);
  return Json::parse(data);
}
struct Mapping {
  HANDLE file = INVALID_HANDLE_VALUE, map{};
  void *base{};
  size_t length{};
  ~Mapping() {
    if (base)
      UnmapViewOfFile(base);
    if (map)
      CloseHandle(map);
    if (file != INVALID_HANDLE_VALUE)
      CloseHandle(file);
  }
};
dstmc::WorldTransform transform(const Json &j) {
  auto vec = [](const Json &v) {
    fields(v, {"x", "y", "z"});
    return dstmc::Vec3{v.at("x").get<double>(), v.at("y").get<double>(),
                       v.at("z").get<double>()};
  };
  dstmc::WorldTransform t;
  t.dst_origin = vec(j.at("dst_origin"));
  t.mc_origin = vec(j.at("mc_origin"));
  t.axes = j.at("axes").get<std::array<double, 9>>();
  if (!dstmc::valid_transform(t))
    throw std::runtime_error("unsupported transform");
  return t;
}
void discover(dstmc::FrameKey expected) {
  auto &s = shared();
  try {
    auto j = status();
    if (j.at("protocol") != 2 || j.at("status") != "PAIRED")
      throw std::runtime_error("MC not paired");
    auto width = integer(j.at("width"), 1920, true),
         height = integer(j.at("height"), 1080, true);
    integer(j.at("generation"), 9007199254740991ull, true);
    auto latest = parse_key(j.at("latest_frame"));
    if (latest.pair_hash != expected.pair_hash ||
        latest.epoch != expected.epoch ||
        j.at("pair") != j.at("latest_frame").at("pair") ||
        j.at("epoch") != j.at("latest_frame").at("epoch"))
      throw std::runtime_error("status session mismatch");
    auto t = transform(j);
    if (!s.service.validate_transform(t))
      throw std::runtime_error("binding changed");
    s.service.resize(uint32_t(width), uint32_t(height));
    if (s.service.pinned(latest))
      return;
    auto file_path = wide(j.at("frame_path").get<std::string>());
    if (file_path.size() < 3 || file_path[1] != L':' ||
        (file_path[2] != L'\\' && file_path[2] != L'/'))
      throw std::runtime_error(
          "frame path must be a local absolute drive path");
    auto m = std::make_shared<Mapping>();
    m->file = CreateFileW(
        file_path.c_str(), GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    BY_HANDLE_FILE_INFORMATION info{};
    LARGE_INTEGER size{};
    if (m->file == INVALID_HANDLE_VALUE ||
        GetFileType(m->file) != FILE_TYPE_DISK ||
        !GetFileInformationByHandle(m->file, &info) ||
        (info.dwFileAttributes &
         (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !GetFileSizeEx(m->file, &size) || !valid_mapping_size(size.QuadPart))
      throw std::runtime_error("invalid frame file");
    m->length = size_t(size.QuadPart);
    m->map =
        CreateFileMappingW(m->file, nullptr, PAGE_READWRITE, 0, 0, nullptr);
    if (!m->map ||
        (m->base = MapViewOfFile(m->map, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0,
                                 m->length)) == nullptr)
      throw std::runtime_error("frame mapping failed");
    auto f = dstmc::read_frame(m->base, m->length, latest);
    if (!f || f->width != width || f->height != height ||
        !dstmc::same_transform(*f, t))
      throw std::runtime_error("exact frame or transform unavailable");
    s.service.offer(std::make_shared<dstmc::FrameView>(std::move(*f)), m);
  } catch (...) {
    invalidate("frame discovery failed");
    throw;
  }
}
Json vec(dstmc::Vec3 v) { return {{"x", v.x}, {"y", v.y}, {"z", v.z}}; }
Json handle(const std::string &path, const std::string &method, Json body) {
  static std::recursive_mutex requests;
  std::lock_guard<std::recursive_mutex> request(requests);
  auto &s = shared();
  if (path == "/v2/camera/cycle" && method == "POST") {
    auto ack = handle("/v2/camera/applied", method, body);
    if (!ack.at("accepted").get<bool>())
      throw std::runtime_error("cycle acknowledgement expired");
    body.erase("applied");
    return handle("/v2/camera/lease", method, body);
  }
  if (method == "GET" &&
      (path.rfind("/v2/window", 0) == 0 || path.rfind("/v2/input", 0) == 0)) {
    std::lock_guard<std::mutex> l(s.mutex);
    if (!s.session)
      throw std::runtime_error("no active session");
    auto q = query(s.key);
    if (path == "/v2/input" + q)
      return {{"protocol", 2},
              {"owner", s.input_mc ? "MC" : "DST"},
              {"version", s.input_version}};
    if (s.geometry.is_null() || now() - s.geometry_at >= 250)
      throw std::runtime_error("window unavailable");
    if (path == "/v2/window/geometry" + q)
      return s.geometry;
    if (path == "/v2/window" + q && s.input_mc && s.proof.accepts(s.key, now()))
      return s.geometry;
    throw std::runtime_error("no fresh composited proof");
  }
  if (path == "/v2/input" && method == "POST") {
    fields(body, {"protocol", "key", "owner", "version"});
    auto k = parse_key(body.at("key"));
    auto owner = body.at("owner").get<std::string>();
    std::lock_guard<std::mutex> l(s.mutex);
    if (body.at("protocol") != 2 || !s.session ||
        k.pair_hash != s.key.pair_hash || k.epoch != s.key.epoch)
      throw std::runtime_error("input session mismatch");
    if (owner != "MC" && owner != "DST")
      throw std::runtime_error("input owner");
    if (integer(body.at("version"), 9007199254740991ull) != s.input_version)
      throw std::runtime_error("input revision conflict");
    s.input_mc = owner == "MC";
    s.input_version++;
    s.proof.clear();
    return {{"protocol", 2}, {"owner", owner}, {"version", s.input_version}};
  }
  bool lease = path == "/v2/camera/lease",
       applied = path == "/v2/camera/applied";
  if (method != "POST" || (!lease && !applied))
    throw std::runtime_error("unsupported route");
  if (lease)
    fields(body, {"protocol", "pair", "epoch", "key"});
  else
    fields(body, {"protocol", "pair", "epoch", "key", "applied"});
  if (body.at("protocol") != 2 ||
      body.at("pair") != body.at("key").at("pair") ||
      body.at("epoch") != body.at("key").at("epoch"))
    throw std::runtime_error("request session mismatch");
  auto k = parse_key(body.at("key"));
  if (applied) {
    if (!body.at("applied").is_boolean())
      throw std::runtime_error("applied must be boolean");
    bool accepted = false;
    if (body.at("applied").get<bool>())
      accepted = s.service.camera_applied(k);
    else {
      std::lock_guard<std::mutex> l(s.mutex);
      if (dstmc::same_key(k, s.key)) {
        s.service.release();
        s.proof.clear();
      }
    }
    return {{"protocol", 2},
            {"pair", body.at("pair")},
            {"epoch", body.at("epoch")},
            {"key", body.at("key")},
            {"accepted", accepted}};
  }
  discover(k);
  auto l = s.service.lease_latest(k.pair_hash, k.epoch);
  if (!l)
    throw std::runtime_error("no fresh lease");
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.session || s.key.pair_hash != l->key.pair_hash ||
        s.key.epoch != l->key.epoch) {
      s.proof.clear();
      s.input_mc = true;
      s.input_version++;
    }
    s.key = l->key;
    s.session = true;
  }
  Json key = body.at("key");
  key["id"] = l->key.id;
  return {{"protocol", 2},
          {"pair", body.at("pair")},
          {"epoch", body.at("epoch")},
          {"mailbox", s.mailbox.u8string()},
          {"input_owner", s.input_mc ? "MC" : "DST"},
          {"lease",
           {{"key", key},
            {"pose",
             {{"space", "DST"},
              {"position", vec(l->pose.position)},
              {"forward", vec(l->pose.forward)},
              {"up", vec(l->pose.up)},
              {"view", l->pose.view},
              {"projection", l->pose.projection}}},
            {"width", l->width},
            {"height", l->height}}}};
}
struct Reader {
  SOCKET socket;
  std::string buffer;
  std::string take(size_t n) {
    if (n > 65536)
      throw std::runtime_error("body too large");
    while (buffer.size() < n) {
      char b[4096];
      int got = recv(socket, b, sizeof(b), 0);
      if (got <= 0 || buffer.size() + got > 73728)
        throw std::runtime_error("incomplete request");
      buffer.append(b, got);
    }
    auto s = buffer.substr(0, n);
    buffer.erase(0, n);
    return s;
  }
  std::string line(size_t max = 8192) {
    for (;;) {
      auto p = buffer.find("\r\n");
      if (p != std::string::npos) {
        if (p > max)
          throw std::runtime_error("line too long");
        auto s = take(p + 2);
        s.resize(p);
        return s;
      }
      if (buffer.size() > max)
        throw std::runtime_error("line too long");
      char b[1024];
      int n = recv(socket, b, sizeof(b), 0);
      if (n <= 0)
        throw std::runtime_error("incomplete headers");
      buffer.append(b, n);
    }
  }
};
bool sendall(SOCKET c, const std::string &s) {
  size_t at = 0;
  while (at < s.size()) {
    int n = send(c, s.data() + at, int(s.size() - at), 0);
    if (n <= 0)
      return false;
    at += n;
  }
  return true;
}
void client(SOCKET c) {
  DWORD timeout = 300;
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char *>(&timeout),
             sizeof(timeout));
  setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char *>(&timeout),
             sizeof(timeout));
  Json reply;
  int code = 200;
  try {
    Reader r{c, {}};
    std::istringstream first(r.line());
    std::string method, path, version;
    first >> method >> path >> version;
    if (version != "HTTP/1.1" && version != "HTTP/1.0")
      throw std::runtime_error("invalid HTTP version");
    long long length = -1;
    bool chunked = false, expect = false;
    size_t headers = 0;
    for (;;) {
      auto line = r.line();
      headers += line.size();
      if (headers > 8192)
        throw std::runtime_error("headers too large");
      if (line.empty())
        break;
      std::transform(line.begin(), line.end(), line.begin(),
                     [](unsigned char x) { return char(std::tolower(x)); });
      auto p = line.find(':');
      if (p == std::string::npos)
        throw std::runtime_error("invalid header");
      auto name = line.substr(0, p), v = line.substr(p + 1);
      auto begin = v.find_first_not_of(" \t"), end = v.find_last_not_of(" \t");
      v = begin == std::string::npos ? "" : v.substr(begin, end - begin + 1);
      if (name == "content-length") {
        if (length != -1 || v.empty() ||
            v.find_first_not_of("0123456789") != std::string::npos)
          throw std::runtime_error("invalid content length");
        length = std::stoll(v);
        if (length > 65536)
          throw std::runtime_error("body too large");
      }
      if (name == "transfer-encoding") {
        if (chunked || v != "chunked")
          throw std::runtime_error("unsupported transfer encoding");
        chunked = true;
      }
      if (name == "expect") {
        if (v != "100-continue")
          throw std::runtime_error("unsupported expectation");
        expect = true;
      }
    }
    if (chunked && length >= 0)
      throw std::runtime_error("ambiguous framing");
    if (expect && !sendall(c, "HTTP/1.1 100 Continue\r\n\r\n"))
      throw std::runtime_error("continue failed");
    std::string payload;
    if (chunked) {
      for (;;) {
        auto line = r.line(128);
        auto hex = line.substr(0, line.find(';'));
        if (hex.empty() || hex.find_first_not_of("0123456789abcdefABCDEF") !=
                               std::string::npos)
          throw std::runtime_error("invalid chunk");
        auto n = std::stoull(hex, nullptr, 16);
        if (!n) {
          size_t trailers = 0;
          while (!(line = r.line()).empty()) {
            trailers += line.size();
            if (trailers > 8192)
              throw std::runtime_error("trailers too large");
          }
          break;
        }
        if (n > 65536 - payload.size())
          throw std::runtime_error("body too large");
        payload += r.take(size_t(n));
        if (r.take(2) != "\r\n")
          throw std::runtime_error("chunk terminator");
      }
    } else if (length > 0)
      payload = r.take(size_t(length));
    reply =
        handle(path, method, payload.empty() ? Json() : Json::parse(payload));
  } catch (const std::exception &e) {
    code = 409;
    reply = {
        {"protocol", 2}, {"error", "GATE_NOT_READY"}, {"reason", e.what()}};
    log("request_error", e.what());
  }
  auto data = reply.dump();
  sendall(c, "HTTP/1.1 " + std::to_string(code) +
                 " Response\r\nContent-Type: application/json\r\nConnection: "
                 "close\r\nContent-Length: " +
                 std::to_string(data.size()) + "\r\n\r\n" + data);
  closesocket(c);
}
void mailbox() {
  std::string previous;
  auto &s = shared();
  while (!s.stop) {
    try {
      auto path = s.mailbox / L"request.json";
      if (std::filesystem::exists(path) &&
          std::filesystem::file_size(path) < 16384) {
        std::ifstream f(path);
        auto j = Json::parse(f);
        auto id = j.at("id").get<std::string>();
        if (id != previous) {
          previous = id;
          Json result;
          try {
            auto route = j.at("path").get<std::string>();
            if (route.rfind("/v2/camera/", 0) != 0)
              throw std::runtime_error("invalid mailbox route");
            result = {{"id", id},
                      {"value", handle(route, "POST", j.at("body"))}};
          } catch (const std::exception &e) {
            result = {{"id", id}, {"error", e.what()}};
          }
          auto temp = s.mailbox / L"response.tmp";
          {
            std::ofstream out(temp);
            out << result.dump();
            out.flush();
            if (!out)
              throw std::runtime_error("mailbox write failed");
          }
          unsigned retries = 0;
          while (!s.stop && !MoveFileExW(temp.c_str(),
                                         (s.mailbox / L"response.json").c_str(),
                                         MOVEFILE_REPLACE_EXISTING |
                                             MOVEFILE_WRITE_THROUGH)) {
            if (++retries % 250 == 0)
              log("mailbox_retry",
                  "response replacement blocked by reader or permissions");
            Sleep(4);
          }
        }
      }
    } catch (const std::exception &) {
    }
    Sleep(4);
  }
}
void present(HWND window, int w, int h, std::optional<dstmc::FrameKey> frame) {
  // Query coordinates under a physical-pixel thread context without changing
  // the game's process-wide DPI policy.
  using SetDpi = HANDLE(WINAPI *)(HANDLE);
  static auto set_dpi = reinterpret_cast<SetDpi>(GetProcAddress(
      GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext"));
  struct RestoreDpi {
    SetDpi set;
    HANDLE previous;
    ~RestoreDpi() {
      if (set && previous)
        set(previous);
    }
  } dpi{set_dpi, set_dpi ? set_dpi(reinterpret_cast<HANDLE>(-4)) : nullptr};
  auto &s = shared();
  RECT rect{};
  POINT point{};
  if (!window || !IsWindow(window) || !GetClientRect(window, &rect) ||
      !ClientToScreen(window, &point) || w < 1 || h < 1)
    return;
  const bool aligned =
      rect.right - rect.left == w && rect.bottom - rect.top == h;
  w = rect.right - rect.left;
  h = rect.bottom - rect.top;
  if (w <= 0 || h <= 0)
    return;
  double scale = 1.;
  std::lock_guard<std::mutex> l(s.mutex);
  if (s.window != window || s.geometry.value("physical_width", 0) != w ||
      s.geometry.value("physical_height", 0) != h)
    s.proof.clear();
  s.window = window;
  s.geometry = {{"protocol", 2},
                {"screen_x", point.x},
                {"screen_y", point.y},
                {"logical_width", w / scale},
                {"logical_height", h / scale},
                {"physical_width", w},
                {"physical_height", h},
                {"scale", scale}};
  s.geometry_at = now();
  if (!aligned)
    s.proof.clear();
  if (aligned && frame && s.input_mc && s.service.ready(*frame)) {
    s.proof.record(*frame, now());
    if (!s.last_reported || !dstmc::same_key(*s.last_reported, *frame)) {
      compose_record(*frame, w, h);
      s.last_reported = *frame;
    }
  }
}
DWORD WINAPI run(void *) {
  auto &s = shared();
  wchar_t dir[32768];
  DWORD n = GetEnvironmentVariableW(L"DSTMC_PROBE_DIR", dir, 32768);
  if (!n || n >= 32768)
    return 1;
  s.directory = std::filesystem::path(dir);
  try {
    std::filesystem::create_directories(s.directory);
    s.mailbox = s.directory / L"camera-mailbox";
    std::filesystem::create_directories(s.mailbox);
  } catch (...) {
    return 2;
  }
  WSADATA data{};
  if (WSAStartup(MAKEWORD(2, 2), &data))
    return 3;
  SOCKET server = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  BOOL exclusive = TRUE;
  setsockopt(server, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
             reinterpret_cast<char *>(&exclusive), sizeof(exclusive));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(39380);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (server == INVALID_SOCKET ||
      bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) ||
      listen(server, 8)) {
    log("startup_failed", "39380 loopback bind failed");
    if (server != INVALID_SOCKET)
      closesocket(server);
    WSACleanup();
    return 4;
  }
  std::thread mail(mailbox);
  log("startup", "Windows ANGLE backend awaiting GLES/EGL exports");
  bool installed = false;
  while (!s.stop) {
    if (!installed) {
      installed = install_render();
      if (installed) {
        try {
          atomic_record(s.directory / L"loaded.json",
                        {{"schema", 1},
                         {"pid", GetCurrentProcessId()},
                         {"architecture", "x86_64"},
                         {"present_hook", "eglSwapBuffers"},
                         {"synthetic_draws", false}});
        } catch (const std::exception &e) {
          log("startup_failed", e.what());
        }
      }
    }
    fd_set ready;
    FD_ZERO(&ready);
    FD_SET(server, &ready);
    timeval timeout{0, 100000};
    if (select(0, &ready, nullptr, nullptr, &timeout) > 0) {
      auto c = accept(server, nullptr, nullptr);
      if (c != INVALID_SOCKET)
        client(c);
    }
  }
  closesocket(server);
  mail.join();
  stop_render();
  s.service.release();
  WSACleanup();
  return 0;
}
} // namespace winbridge
// No loader-lock work besides starting the worker. Pin the DLL: callbacks
// remain valid until process exit; arbitrary FreeLibrary cannot unload live
// hooks.
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(module);
    HMODULE pinned{};
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_PIN,
                       reinterpret_cast<LPCWSTR>(&DllMain), &pinned);
    HANDLE thread =
        CreateThread(nullptr, 0, winbridge::run, nullptr, 0, nullptr);
    if (thread)
      CloseHandle(thread);
    else
      return FALSE;
  }
  return TRUE;
}
extern "C" __declspec(dllexport) void WINAPI DSTMC_Stop() {
  winbridge::shared().stop = true;
}
