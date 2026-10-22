#include "camera_http.h"
#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <chrono>
#include <fcntl.h>
#include <fstream>
#include <netinet/in.h>
#include <sstream>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
namespace bridge {
namespace {
struct State {
  dstmc::CameraService service;
  std::mutex key_mutex, window_mutex;
  dstmc::FrameKey current_key{};
  NSDictionary *window_info = nil;
  uint64_t last_composite = 0;
  bool enabled = false;
  std::string directory;
};
State &state() {
  static auto *value = new State;
  return *value;
}
uint64_t milliseconds() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
} // namespace
dstmc::CameraService &camera_service() { return state().service; }
bool enabled() { return state().enabled; }
dstmc::FrameKey key() {
  std::lock_guard<std::mutex> lock(state().key_mutex);
  return state().current_key;
}
void log(NSDictionary *record) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:record
                                                 options:0
                                                   error:nil];
  if (data) {
    std::ofstream out(state().directory + "/camera-gate.jsonl", std::ios::app);
    out.write((const char *)data.bytes, data.length);
    out << '\n';
  }
}
NSString *string(id object) {
  if (![object isKindOfClass:[NSString class]])
    throw std::runtime_error("expected string");
  return object;
}
NSDictionary *object(id value) {
  if (![value isKindOfClass:[NSDictionary class]])
    throw std::runtime_error("expected object");
  return value;
}
void fields(NSDictionary *o, NSArray *keys) {
  object(o);
  if (![[NSSet setWithArray:o.allKeys] isEqual:[NSSet setWithArray:keys]])
    throw std::runtime_error("unexpected fields");
}
std::array<uint8_t, 16> uuid(id value) {
  NSUUID *u = [[NSUUID alloc] initWithUUIDString:string(value)];
  if (!u)
    throw std::runtime_error("invalid UUID");
  std::array<uint8_t, 16> b{};
  [u getUUIDBytes:b.data()];
  [u release];
  return b;
}
NSString *quote(NSString *s) {
  NSData *d = [NSJSONSerialization
      dataWithJSONObject:@[ s ]
                 options:(NSJSONWritingFragmentsAllowed |
                          NSJSONWritingWithoutEscapingSlashes)
                   error:nil];
  NSString *t = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
      autorelease];
  return [t substringWithRange:NSMakeRange(1, t.length - 2)];
}
dstmc::FrameKey parse_key(NSDictionary *key) {
  fields(key, @[ @"pair", @"epoch", @"id" ]);
  NSDictionary *p = object(key[@"pair"]);
  fields(
      p,
      @[ @"dst_world", @"dst_shard", @"mc_world", @"mc_dimension", @"region" ]);
  uuid(p[@"dst_world"]);
  uuid(p[@"mc_world"]);
  NSMutableString *canonical = [NSMutableString stringWithString:@"{"];
  bool first = true;
  for (NSString *k in @[
         @"dst_world", @"dst_shard", @"mc_world", @"mc_dimension", @"region"
       ]) {
    NSString *v = string(p[k]);
    if ([k isEqual:@"dst_world"] || [k isEqual:@"mc_world"])
      v = v.lowercaseString;
    if (!v.length)
      throw std::runtime_error("empty pair field");
    if (!first)
      [canonical appendString:@","];
    first = false;
    [canonical appendFormat:@"%@:%@", quote(k), quote(v)];
  }
  [canonical appendString:@"}"];
  dstmc::FrameKey out{};
  NSData *d = [canonical dataUsingEncoding:NSUTF8StringEncoding];
  CC_SHA256(d.bytes, (CC_LONG)d.length, out.pair_hash.data());
  out.epoch = uuid(key[@"epoch"]);
  id n = key[@"id"];
  if (![n isKindOfClass:[NSNumber class]] || [n doubleValue] < 0 ||
      [n doubleValue] > 9007199254740991. ||
      [n doubleValue] != std::floor([n doubleValue]))
    throw std::runtime_error("invalid frame ID");
  out.id = [n unsignedLongLongValue];
  return out;
}
NSDictionary *get_status() {
  NSURLRequest *r = [NSURLRequest
       requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:39379/v2/status"]
          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
      timeoutInterval:.15];
  NSURLResponse *response = nil;
  NSData *d = [NSURLConnection sendSynchronousRequest:r
                                    returningResponse:&response
                                                error:nil];
  if (!d || d.length > 65536 ||
      [(NSHTTPURLResponse *)response statusCode] != 200)
    throw std::runtime_error("MC status unavailable");
  return object([NSJSONSerialization JSONObjectWithData:d options:0 error:nil]);
}
struct Mapping {
  void *base = MAP_FAILED;
  size_t length = 0;
  ~Mapping() {
    if (base != MAP_FAILED)
      munmap(base, length);
  }
};
void discover(dstmc::FrameKey expected) {
  NSDictionary *s = get_status();
  if (![s[@"protocol"] isEqual:@2] || ![s[@"status"] isEqual:@"PAIRED"])
    throw std::runtime_error("MC not paired");
  // Refresh physical size even while an exact frame is pinned. A new mapping
  // announced after resize must invalidate the old camera acknowledgment.
  state().service.resize([s[@"width"] unsignedIntValue],
                         [s[@"height"] unsignedIntValue]);
  auto latest = parse_key(object(s[@"latest_frame"]));
  if (!dstmc::same_key(latest, expected))
    throw std::runtime_error("exact frame changed; retry");
  if (![s[@"pair"] isEqual:object(s[@"latest_frame"])[@"pair"]] ||
      ![s[@"epoch"] isEqual:object(s[@"latest_frame"])[@"epoch"]])
    throw std::runtime_error("status session mismatch");
  if (state().service.lease_latest(expected.pair_hash, expected.epoch))
    return; // Keep the existing slot; never attempt a second reader lease.
  NSString *path = string(s[@"frame_path"]);
  int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOFOLLOW);
  if (fd < 0)
    throw std::runtime_error("frame open failed");
  struct stat st{};
  if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() ||
      st.st_size < 4096 || st.st_size > 80 * 1024 * 1024) {
    close(fd);
    throw std::runtime_error("invalid mapping");
  }
  auto mapping = std::make_shared<Mapping>();
  mapping->length = st.st_size;
  mapping->base =
      mmap(nullptr, mapping->length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (mapping->base == MAP_FAILED)
    throw std::runtime_error("mapping failed");
  auto frame = dstmc::read_frame(mapping->base, mapping->length, expected);
  if (!frame)
    throw std::runtime_error("exact complete frame unavailable");
  if (frame->width != [s[@"width"] unsignedIntValue] ||
      frame->height != [s[@"height"] unsignedIntValue])
    throw std::runtime_error("stream resize");
  state().service.offer(std::make_shared<dstmc::FrameView>(std::move(*frame)),
                        mapping);
}
NSArray *matrix(const std::array<float, 16> &m) {
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:16];
  for (float x : m)
    [a addObject:@(x)];
  return a;
}
NSDictionary *vec(dstmc::Vec3 v) {
  return @{@"x" : @(v.x), @"y" : @(v.y), @"z" : @(v.z)};
}
NSDictionary *handle(NSString *path, NSString *method, NSDictionary *body) {
  if ([path isEqual:@"/v2/window"] && [method isEqual:@"GET"]) {
    std::lock_guard<std::mutex> lock(state().window_mutex);
    if (!state().window_info || milliseconds() - state().last_composite >= 250)
      throw std::runtime_error("no recently composited frame");
    return [[state().window_info retain] autorelease];
  }
  if (![method isEqual:@"POST"])
    throw std::runtime_error("method not supported");
  bool lease = [path isEqual:@"/v2/camera/lease"],
       applied = [path isEqual:@"/v2/camera/applied"];
  if (!lease && !applied)
    throw std::runtime_error("unknown endpoint");
  fields(body, lease ? @[ @"protocol", @"pair", @"epoch", @"key" ]
                     : @[ @"protocol", @"pair", @"epoch", @"key", @"applied" ]);
  if (![body[@"protocol"] isEqual:@2])
    throw std::runtime_error("protocol mismatch");
  NSDictionary *key = object(body[@"key"]);
  if (![body[@"pair"] isEqual:key[@"pair"]] ||
      ![body[@"epoch"] isEqual:key[@"epoch"]])
    throw std::runtime_error("request session mismatch");
  auto k = parse_key(key);
  if (applied) {
    if (CFGetTypeID((CFTypeRef)body[@"applied"]) != CFBooleanGetTypeID())
      throw std::runtime_error("applied must be boolean");
    bool accepted = false;
    if ([body[@"applied"] boolValue])
      accepted = state().service.camera_applied(k);
    else {
      std::lock_guard<std::mutex> lock(state().key_mutex);
      if (dstmc::same_key(k, state().current_key))
        state().service.release();
    }
    return @{
      @"protocol" : @2,
      @"pair" : body[@"pair"],
      @"epoch" : body[@"epoch"],
      @"key" : key,
      @"accepted" : @(accepted)
    };
  }
  // Repeated requests return the pinned pose, never a different image under the
  // requested key.
  discover(k);
  auto l = state().service.lease_latest(k.pair_hash, k.epoch);
  if (!l || !dstmc::same_key(l->key, k))
    throw std::runtime_error("different frame pinned or stale");
  {
    std::lock_guard<std::mutex> lock(state().key_mutex);
    state().current_key = k;
  }
  NSDictionary *pose = @{
    @"space" : @"DST",
    @"position" : vec(l->pose.position),
    @"forward" : vec(l->pose.forward),
    @"up" : vec(l->pose.up),
    @"view" : matrix(l->pose.view),
    @"projection" : matrix(l->pose.projection)
  };
  return @{
    @"protocol" : @2,
    @"pair" : body[@"pair"],
    @"epoch" : body[@"epoch"],
    @"lease" : @{
      @"key" : key,
      @"pose" : pose,
      @"width" : @(l->width),
      @"height" : @(l->height)
    }
  };
}
void serve(int server) {
  for (;;) {
    int client = accept(server, nullptr, nullptr);
    if (client < 0)
      break;
    @autoreleasepool {
      timeval timeout{0, 300000};
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
      setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
      int no_sigpipe = 1;
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
                 sizeof(no_sigpipe));
      NSDictionary *response = nil;
      int code = 200;
      try {
        std::string request;
        size_t end = std::string::npos;
        char buffer[4096];
        while ((end = request.find("\r\n\r\n")) == std::string::npos) {
          ssize_t n = recv(client, buffer, sizeof(buffer), 0);
          if (n <= 0 || request.size() + n > 8192)
            throw std::runtime_error("invalid HTTP header");
          request.append(buffer, n);
        }
        std::istringstream headers(request.substr(0, end));
        std::string method, path, version, line;
        headers >> method >> path >> version;
        std::getline(headers, line);
        size_t length = 0;
        bool found = false;
        while (std::getline(headers, line)) {
          std::transform(line.begin(), line.end(), line.begin(),
                         [](unsigned char c) { return std::tolower(c); });
          if (line.rfind("transfer-encoding:", 0) == 0)
            throw std::runtime_error("chunked body unsupported");
          if (line.rfind("content-length:", 0) == 0) {
            if (found)
              throw std::runtime_error("duplicate length");
            found = true;
            length = std::stoul(line.substr(15));
            if (length > 65536)
              throw std::runtime_error("body too large");
          }
        }
        size_t offset = end + 4;
        while (request.size() - offset < length) {
          ssize_t n = recv(
              client, buffer,
              std::min(sizeof(buffer), length - (request.size() - offset)), 0);
          if (n <= 0)
            throw std::runtime_error("incomplete body");
          request.append(buffer, n);
        }
        NSDictionary *body = nil;
        if (length) {
          NSData *d = [NSData dataWithBytes:request.data() + offset
                                     length:length];
          body = object([NSJSONSerialization JSONObjectWithData:d
                                                        options:0
                                                          error:nil]);
        }
        response = handle([NSString stringWithUTF8String:path.c_str()],
                          [NSString stringWithUTF8String:method.c_str()], body);
      } catch (const std::exception &e) {
        code = 409;
        response = @{
          @"protocol" : @2,
          @"error" : @"GATE_NOT_READY",
          @"reason" : [NSString stringWithUTF8String:e.what()]
        };
      }
      NSData *json = [NSJSONSerialization dataWithJSONObject:response
                                                     options:0
                                                       error:nil];
      std::string header =
          "HTTP/1.1 " + std::to_string(code) +
          " OK\r\nContent-Type: application/json\r\nConnection: "
          "close\r\nContent-Length: " +
          std::to_string(json.length) + "\r\n\r\n";
      std::string bytes =
          header + std::string((const char *)json.bytes, json.length);
      size_t sent = 0;
      while (sent < bytes.size()) {
        ssize_t n = send(client, bytes.data() + sent, bytes.size() - sent, 0);
        if (n <= 0)
          break;
        sent += n;
      }
    }
    close(client);
  }
  close(server);
}
void start(const char *dir) {
  if (!getenv("DSTMC_FIRST_PERSON"))
    return;
  state().directory = dir;
  int server = socket(AF_INET, SOCK_STREAM, 0);
  int reuse = 1;
  if (server >= 0)
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(39380);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (server < 0 || bind(server, (sockaddr *)&addr, sizeof(addr)) ||
      listen(server, 8)) {
    if (server >= 0)
      close(server);
    log(@{
      @"event" : @"camera_service_failed",
      @"reason" : @"39380 bind conflict"
    });
    return;
  }
  state().enabled = true;
  std::thread(serve, server).detach();
  log(@{@"event" : @"camera_service_started", @"port" : @39380});
}
void report_compose(const dstmc::RenderProbe &camera, dstmc::FrameKey key,
                    const dstmc::ComposeResult &result) {
  static uint64_t last = 0;
  if (milliseconds() - last > 1000) {
    last = milliseconds();
    NSMutableArray *matrices = [NSMutableArray array];
    for (auto &m : camera.shader_matrices)
      if (m.name == "MatrixV" || m.name == "MatrixP")
        [matrices addObject:@{
          @"name" : [NSString stringWithUTF8String:m.name.c_str()],
          @"value" : matrix(m.value)
        }];
    log(@{
      @"event" : @"compose",
      @"frame" : @(key.id),
      @"status" : @(int(result.status)),
      @"reason" : [NSString stringWithUTF8String:result.reason.c_str()],
      @"matrices" : matrices,
      @"width" : @(camera.viewport[2]),
      @"height" : @(camera.viewport[3])
    });
  }
}
void present_window(int pw, int ph, bool composited) {
  if (composited) {
    std::lock_guard<std::mutex> lock(state().window_mutex);
    state().last_composite = milliseconds();
  }
  // Cocoa view geometry is captured only on the native UI thread. Render pixels
  // come from the profiled scene.
  if ([NSThread isMainThread]) {
    NSWindow *w = [[[NSOpenGLContext currentContext] view] window];
    NSView *v = w.contentView;
    if (w && v) {
      NSRect r = [w convertRectToScreen:[v convertRect:v.bounds toView:nil]];
      double top = NSMaxY([NSScreen screens][0].frame) - NSMaxY(r);
      if (pw > 0 && ph > 0) {
        std::lock_guard<std::mutex> lock(state().window_mutex);
        [state().window_info release];
        state().window_info = [@{
          @"protocol" : @2,
          @"screen_x" : @(r.origin.x),
          @"screen_y" : @(top),
          @"logical_width" : @(r.size.width),
          @"logical_height" : @(r.size.height),
          @"physical_width" : @(pw),
          @"physical_height" : @(ph),
          @"scale" : @(pw / r.size.width)
        } retain];
      }
    }
  }
}
} // namespace bridge
