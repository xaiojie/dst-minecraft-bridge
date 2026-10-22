#include "camera_http.h"
#import <Cocoa/Cocoa.h>
#include <cassert>
#include <iostream>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

namespace bridge {
void serve_client(int client);
}

namespace {
bool contains(const std::string &haystack, const std::string &needle) {
  return haystack.find(needle) != std::string::npos;
}
void send_all(int fd, const std::string &bytes) {
  size_t sent = 0;
  while (sent < bytes.size()) {
    ssize_t n = send(fd, bytes.data() + sent, bytes.size() - sent, 0);
    assert(n > 0);
    sent += (size_t)n;
  }
}
std::string read_to_close(int fd) {
  std::string response;
  char buffer[4096];
  ssize_t n;
  while ((n = recv(fd, buffer, sizeof(buffer), 0)) > 0)
    response.append(buffer, (size_t)n);
  return response;
}
// One raw request through the real handler. The request line targets an
// unknown endpoint on purpose: reaching it means the body was framed and
// parsed, which is exactly what is under test.
std::string exchange(const std::string &request) {
  int fds[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
  std::thread server([&] { bridge::serve_client(fds[0]); });
  send_all(fds[1], request);
  shutdown(fds[1], SHUT_WR);
  std::string response = read_to_close(fds[1]);
  close(fds[1]);
  server.join();
  return response;
}
std::string exchange_expect_continue() {
  int fds[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
  std::thread server([&] { bridge::serve_client(fds[0]); });
  send_all(fds[1], "POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                   "Content-Type: application/json\r\nContent-Length: 2\r\n"
                   "Expect: 100-continue\r\n\r\n");
  std::string interim;
  char buffer[256];
  while (!contains(interim, "\r\n\r\n")) {
    ssize_t n = recv(fds[1], buffer, sizeof(buffer), 0);
    assert(n > 0);
    interim.append(buffer, (size_t)n);
  }
  assert(contains(interim, "100 Continue"));
  send_all(fds[1], "{}");
  shutdown(fds[1], SHUT_WR);
  std::string response = read_to_close(fds[1]);
  close(fds[1]);
  server.join();
  return response;
}
} // namespace

int main() {
  @autoreleasepool {
    auto length_bodied = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                                  "Content-Type: application/json\r\n"
                                  "Content-Length: 2\r\n\r\n{}");
    assert(contains(length_bodied, "unknown endpoint"));

    auto chunked = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                            "Transfer-Encoding: chunked\r\n\r\n"
                            "2\r\n{}\r\n0\r\n\r\n");
    assert(contains(chunked, "unknown endpoint"));

    auto split_chunks = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                                 "Transfer-Encoding: chunked\r\n\r\n"
                                 "1\r\n{\r\n1;ext=1\r\n}\r\n0\r\n\r\n");
    assert(contains(split_chunks, "unknown endpoint"));

    auto expect_continue = exchange_expect_continue();
    assert(contains(expect_continue, "unknown endpoint"));

    auto array_body = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                               "Content-Length: 2\r\n\r\n[]");
    assert(contains(array_body, "expected object"));

    auto bad_terminator = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                                   "Transfer-Encoding: chunked\r\n\r\n"
                                   "2\r\n{}XX");
    assert(contains(bad_terminator, "invalid chunk terminator"));

    auto unsupported = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                                "Transfer-Encoding: gzip\r\n\r\n");
    assert(contains(unsupported, "unsupported transfer encoding"));

    auto truncated = exchange("POST /v2/not-a-thing HTTP/1.1\r\nHost: x\r\n"
                              "Content-Length: 10\r\n\r\n{}");
    assert(contains(truncated, "incomplete body"));

    std::cout << "PASS chunked_and_expect_continue_bodies_are_read "
                 "malformed_framing_fails_closed\n";
  }
}
