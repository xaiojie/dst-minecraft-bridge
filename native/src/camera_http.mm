#include "camera_http.h"
#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <atomic>
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
  WindowProof window_proof;
  bool enabled = false;
  std::atomic<bool> input_mc{true};
  uint64_t input_version=0;
  std::string directory;
  std::string mailbox_directory;
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
bool enabled() { return state().enabled && state().input_mc; }
dstmc::FrameKey key() {
  std::lock_guard<std::mutex> lock(state().key_mutex);
  return state().current_key;
}
void log(NSDictionary *record) {
  // Monotonic timestamp so gate events from different processes can be ordered.
  NSMutableDictionary *stamped = [record mutableCopy];
  stamped[@"t"] = @(milliseconds());
  record = stamped;
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
// Strict active-binding metadata. Missing fields intentionally reject older status producers.
dstmc::WorldTransform parse_transform(NSDictionary *status) {
  auto number=[](id value) -> double {
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)value)==CFBooleanGetTypeID() || !std::isfinite([value doubleValue]))
      throw std::runtime_error("invalid transform number");
    return [value doubleValue];
  };
  auto vector=[&](id value) -> dstmc::Vec3 {
    NSDictionary *v=object(value);fields(v,@[@"x",@"y",@"z"]);
    return {number(v[@"x"]),number(v[@"y"]),number(v[@"z"])};
  };
  dstmc::WorldTransform t;
  t.dst_origin=vector(status[@"dst_origin"]);t.mc_origin=vector(status[@"mc_origin"]);
  id axes=status[@"axes"];
  if (![axes isKindOfClass:[NSArray class]] || [axes count]!=9)
    throw std::runtime_error("missing or invalid transform axes");
  for (unsigned i=0;i<9;i++)t.axes[i]=number(axes[i]);
  if (!dstmc::valid_transform(t))throw std::runtime_error("unsupported transform axes");
  return t;
}
void discover_frame(dstmc::FrameKey expected) {
  NSDictionary *s = get_status();
  if (![s[@"protocol"] isEqual:@2] || ![s[@"status"] isEqual:@"PAIRED"])
    throw std::runtime_error("MC not paired");
  // A paired session normally has no stream during handshake/resize. Reject
  // nulls and wrong types before sending any Foundation numeric selectors.
  auto integer = [](id value, uint64_t maximum) -> uint64_t {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID())
      throw std::runtime_error("incomplete stream number");
    double n = [value doubleValue];
    if (!std::isfinite(n) || n < 1 || n > maximum || n != std::floor(n))
      throw std::runtime_error("invalid stream number");
    return [value unsignedLongLongValue];
  };
  uint32_t width, height;
  NSString *path;
  try {
    width = integer(s[@"width"], 1920);
    height = integer(s[@"height"], 1080);
    integer(s[@"generation"], 9007199254740991ULL);
    path = string(s[@"frame_path"]);
    if (!path.length)
      throw std::runtime_error("empty stream path");
    object(s[@"latest_frame"]);
  } catch (const std::exception &) {
    state().service.release();
    throw;
  }
  auto transform=parse_transform(s);
  if(!state().service.validate_transform(transform))throw std::runtime_error("active binding transform changed");
  // Refresh physical size even while an exact frame is pinned.
  state().service.resize(width, height);
  auto latest = parse_key(object(s[@"latest_frame"]));
  // The client's key may lag the newest publication for a few frames: a lease
  // request crosses status, lease and a native status read, while MC publishes
  // every ~34 ms. Honour any still-published exact frame of the same session
  // instead of demanding the newest key. read_frame re-validates pair, epoch
  // and frame id, so pose and pixels still come from one exact frame; a
  // rotated-out key fails with "exact complete frame unavailable" and the
  // client retries from a fresh status.
  if (latest.pair_hash != expected.pair_hash ||
      latest.epoch != expected.epoch)
    throw std::runtime_error("status session mismatch");
  if (![s[@"pair"] isEqual:object(s[@"latest_frame"])[@"pair"]] ||
      ![s[@"epoch"] isEqual:object(s[@"latest_frame"])[@"epoch"]])
    throw std::runtime_error("status session mismatch");
  auto pinned = state().service.pinned(latest);
  if (pinned) return; // Reuse only this exact publication, never an older slot.
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
  // The status publication is authoritative. The caller's older key is only
  // a session hint; reading it first can perpetually reacquire frozen pixels.
  auto frame = dstmc::read_frame(mapping->base, mapping->length, latest);
  if (!frame)
    throw std::runtime_error("exact complete frame unavailable");
  if (!dstmc::same_transform(*frame,transform))
    throw std::runtime_error("frame binding transform mismatch");
  if (frame->width != width || frame->height != height)
    throw std::runtime_error("stream resize");
  state().service.offer(std::make_shared<dstmc::FrameView>(std::move(*frame)),
                        mapping);
}
void discover(dstmc::FrameKey expected) {
  try { discover_frame(expected); }
  catch (...) {
    state().service.release();
    std::lock_guard<std::mutex> lock(state().window_mutex);
    state().window_proof=WindowProof{};
    throw;
  }
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
  static std::recursive_mutex requests;
  std::lock_guard<std::recursive_mutex> request_lock(requests);
  if([path isEqual:@"/v2/camera/cycle"] && [method isEqual:@"POST"]) {
    auto ack=handle(@"/v2/camera/applied",method,body);
    if(![ack[@"accepted"] boolValue])throw std::runtime_error("cycle acknowledgement expired");
    NSMutableDictionary *next=[NSMutableDictionary dictionaryWithDictionary:body];[next removeObjectForKey:@"applied"];
    return handle(@"/v2/camera/lease",method,next);
  }
  if ([path hasPrefix:@"/v2/input"]) {
    std::lock_guard<std::mutex> lock(state().key_mutex);
    auto expected=WindowProof::request(state().current_key);expected.replace(0,10,"/v2/input");
    if ([method isEqual:@"GET"]) {
      if(expected!=path.UTF8String)throw std::runtime_error("input session mismatch");
    } else if([method isEqual:@"POST"] && [path isEqual:@"/v2/input"]) {
      fields(body,@[@"protocol",@"key",@"owner",@"version"]);
      auto requested=parse_key(object(body[@"key"]));
      if(![body[@"protocol"] isEqual:@2]||requested.pair_hash!=state().current_key.pair_hash||requested.epoch!=state().current_key.epoch)throw std::runtime_error("input session mismatch");
      NSString *owner=string(body[@"owner"]);
      if(![owner isEqual:@"MC"]&&![owner isEqual:@"DST"])throw std::runtime_error("input owner");
      if([body[@"version"] unsignedLongLongValue]!=state().input_version)throw std::runtime_error("input revision conflict");
      state().input_mc=[owner isEqual:@"MC"];state().input_version++;
    } else throw std::runtime_error("input method");
    return @{@"protocol":@2,@"owner":state().input_mc?@"MC":@"DST",@"version":@(state().input_version)};
  }

  if ([path hasPrefix:@"/v2/window"] && [method isEqual:@"GET"]) {
    std::lock_guard<std::mutex> lock(state().window_mutex);
    if (!state().window_info ||
        !state().window_proof.accepts(path.UTF8String, milliseconds()))
      throw std::runtime_error(
          "no recently composited frame for requested identity");
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
    {  // Gate diagnostics: the acknowledgement outcome with its timing.
      auto ls = state().service.lease_state();
      log(@{ @"event" : @"ack", @"key" : @(k.id), @"accepted" : @(accepted),
             @"pinned" : @(ls.key_id), @"acked" : @(ls.acked),
             @"remaining_ms" : @(ls.remaining_ms) });
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
  // requested key. The response key names the frame actually pinned: it can be
  // newer than the requested key when that slot already rotated out, and the
  // caller must confirm and compose exactly that key.
  discover(k);
  auto l = state().service.lease_latest(k.pair_hash, k.epoch);
  if (!l)
    throw std::runtime_error("different frame pinned or stale");
  {
    std::lock_guard<std::mutex> lock(state().key_mutex);
    if(state().current_key.pair_hash!=l->key.pair_hash||state().current_key.epoch!=l->key.epoch){state().input_mc=true;state().input_version++;}
    state().current_key = l->key;
  }
  NSDictionary *leased_key = @{
    @"pair" : body[@"pair"],
    @"epoch" : body[@"epoch"],
    @"id" : @(l->key.id)
  };
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
    @"mailbox" : [NSString stringWithUTF8String:state().mailbox_directory.c_str()],
    @"input_owner" : state().input_mc?@"MC":@"DST",
    @"lease" : @{
      @"key" : leased_key,
      @"pose" : pose,
      @"width" : @(l->width),
      @"height" : @(l->height)
    }
  };
}
bool send_all(int client, const std::string &bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
    ssize_t n = send(client, bytes.data() + sent, bytes.size() - sent, 0);
    if (n <= 0)
      return false;
    sent += n;
  }
  return true;
}
// The game's own HTTP client decides framing; it is not ours to assume. A
// request whose body arrived chunked or behind Expect: 100-continue is valid
// HTTP and must be read, otherwise the endpoint silently rejects a client that
// speaks it (the Java half accepts both).
struct SocketReader {
  int client;
  std::string buffer;
  bool fill(size_t need) {
    char chunk[4096];
    while (buffer.size() < need) {
      ssize_t n = recv(client, chunk, sizeof(chunk), 0);
      if (n <= 0 || buffer.size() + n > 1u << 20)
        return false;
      buffer.append(chunk, n);
    }
    return true;
  }
  bool take(size_t n, std::string &out) {
    if (!fill(n))
      return false;
    out.assign(buffer, 0, n);
    buffer.erase(0, n);
    return true;
  }
  bool line(std::string &out) {
    for (;;) {
      size_t pos = buffer.find("\r\n");
      if (pos != std::string::npos) {
        out.assign(buffer, 0, pos);
        buffer.erase(0, pos + 2);
        return true;
      }
      if (!fill(buffer.size() + 1))
        return false;
    }
  }
};
// One accepted connection: read the request, answer it, close. Kept separate
// from the accept loop so framing can be tested without a real port.
void serve_client(int client) {
  @autoreleasepool {
    timeval timeout{0, 300000};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int no_sigpipe = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe,
               sizeof(no_sigpipe));
    NSDictionary *response = nil;
    std::string request;
    int code = 200;
    try {
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
      long long length = -1;
      bool chunked = false, expect_continue = false;
      while (std::getline(headers, line)) {
        std::transform(line.begin(), line.end(), line.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        auto value = [&line](size_t from) {
          std::string v = line.substr(from);
          size_t first = v.find_first_not_of(" \t\r");
          size_t last = v.find_last_not_of(" \t\r");
          return first == std::string::npos ? std::string()
                                           : v.substr(first, last - first + 1);
        };
        if (line.rfind("transfer-encoding:", 0) == 0) {
          if (value(18).find("chunked") == std::string::npos)
            throw std::runtime_error("unsupported transfer encoding");
          chunked = true;
        } else if (line.rfind("content-length:", 0) == 0) {
          if (length >= 0)
            throw std::runtime_error("duplicate length");
          length = std::stoll(value(15));
          if (length < 0 || length > 65536)
            throw std::runtime_error("body too large");
        } else if (line.rfind("expect:", 0) == 0) {
          if (value(7).find("100-continue") != std::string::npos)
            expect_continue = true;
        }
      }
      size_t offset = end + 4;
      std::string payload;
      if (chunked || length > 0) {
        if (expect_continue &&
            !send_all(client, "HTTP/1.1 100 Continue\r\n\r\n"))
          throw std::runtime_error("continue write failed");
        SocketReader reader{client, request.substr(offset)};
        if (chunked) {
          std::string size_line, decoded, crlf;
          for (;;) {
            if (!reader.line(size_line))
              throw std::runtime_error("incomplete chunk");
            size_t semi = size_line.find(';');
            std::string hex =
                semi == std::string::npos ? size_line : size_line.substr(0, semi);
            if (hex.empty())
              throw std::runtime_error("invalid chunk size");
            size_t n = std::stoul(hex, nullptr, 16);
            if (n == 0)
              break;
            if (payload.size() + n > 65536)
              throw std::runtime_error("body too large");
            if (!reader.take(n, decoded))
              throw std::runtime_error("incomplete body");
            payload += decoded;
            if (!reader.line(crlf) || !crlf.empty())
              throw std::runtime_error("invalid chunk terminator");
          }
        } else if (!reader.take((size_t)length, payload)) {
          throw std::runtime_error("incomplete body");
        }
      }
      NSDictionary *body = nil;
      if (!payload.empty()) {
        NSData *d = [NSData dataWithBytes:payload.data()
                                   length:payload.size()];
        body = object([NSJSONSerialization JSONObjectWithData:d
                                                      options:0
                                                        error:nil]);
      }
      response = handle([NSString stringWithUTF8String:path.c_str()],
                        [NSString stringWithUTF8String:method.c_str()], body);
    } catch (const std::exception &e) {
      code = 409;
      // A rejected request is invisible from the game side (its client only
      // sees a non-200), so record why it was rejected.
      size_t line_end = request.find("\r\n");
      log(@{
        @"event" : @"request_error",
        @"reason" : [NSString stringWithUTF8String:e.what()],
        @"request" : [NSString
            stringWithUTF8String:request.substr(0, std::min<size_t>(
                                                       line_end == std::string::npos
                                                           ? request.size()
                                                           : line_end,
                                                       120))
                                .c_str()]
      });
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
void serve(int server) {
  for (;;) {
    int client = accept(server, nullptr, nullptr);
    if (client < 0)
      break;
    serve_client(client);
  }
  close(server);
}
void serve_mailbox() {
  std::string previous;
  while(true) {
    @autoreleasepool {
      NSString *requestPath=[NSString stringWithUTF8String:(state().mailbox_directory+"/request.json").c_str()];
      NSData *data=[NSData dataWithContentsOfFile:requestPath];
      if(data && data.length<16384) {
        id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if([value isKindOfClass:[NSDictionary class]]) {
          NSDictionary *r=value;id identifier=r[@"id"];
          if([identifier isKindOfClass:[NSString class]] && std::string([identifier UTF8String])!=previous) {
            previous=[identifier UTF8String];NSDictionary *reply;
            try {
              NSString *route=string(r[@"path"]);
              if(![route hasPrefix:@"/v2/camera/"])throw std::runtime_error("invalid mailbox route");
              reply=@{@"id":identifier,@"value":handle(route,@"POST",object(r[@"body"]))};
            }catch(const std::exception &e){reply=@{@"id":identifier,@"error":[NSString stringWithUTF8String:e.what()]};}
            NSData *output=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
            [output writeToFile:[NSString stringWithUTF8String:(state().mailbox_directory+"/response.json").c_str()] options:NSDataWritingAtomic error:nil];
          }
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
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
  state().mailbox_directory=state().directory+"/camera-mailbox";
  if(mkdir(state().mailbox_directory.c_str(),0700)==0)std::thread(serve_mailbox).detach();
  else state().mailbox_directory.clear();
  state().enabled = true;
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      if(event.keyCode==100 && !event.isARepeat) {
        std::lock_guard<std::mutex> lock(state().key_mutex);
        state().input_mc=!state().input_mc.load();state().input_version++;
        return nil;
      }
      return event;
    }];
  });
  std::thread(serve, server).detach();
  log(@{@"event" : @"camera_service_started", @"port" : @39380});
}
void report_compose(const dstmc::RenderProbe &camera, dstmc::FrameKey key,
                    const dstmc::ComposeResult &result) {
  auto ls = camera_service().lease_state();
  static uint64_t last = 0;
  static const bool gate_all = getenv("DSTMC_GATE_ALL") != nullptr;
  if (gate_all || result.status == dstmc::ComposeStatus::COMPOSITED ||
      milliseconds() - last > 1000) {
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
      @"mailbox" : [NSString stringWithUTF8String:state().mailbox_directory.c_str()],
    @"input_owner" : state().input_mc?@"MC":@"DST",
    @"lease" : @{
        @"pinned" : @(ls.pinned),
        @"acked" : @(ls.acked),
        @"leased" : @(ls.leased),
        @"key" : @(ls.key_id),
        @"remaining_ms" : @(ls.remaining_ms)
      },
      @"matrices" : matrices,
      @"width" : @(camera.viewport[2]),
      @"height" : @(camera.viewport[3])
    });
  }
}
void present_window(int pw, int ph,
                    std::optional<dstmc::FrameKey> composited_frame) {
  if (composited_frame) {
    std::lock_guard<std::mutex> lock(state().window_mutex);
    state().window_proof.recorded(*composited_frame, milliseconds());
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
