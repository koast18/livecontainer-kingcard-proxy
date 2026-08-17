#ifndef KPKQueenCore_h
#define KPKQueenCore_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 通过 POSIX socket 发送 HTTP/1.1 POST。
/// host/port: 目标服务器；path_and_query: 以 / 开头（含 query）。
/// headers: 完整的头行（不含 CRLF），如 "Content-Type: application/multipart-formdata"。
/// resp 回填完整响应（状态行 + 头 + body），resp_len 为实际长度。
/// 返回 HTTP 状态码；网络失败返回 0；发送失败返回 -1。
int kpq_http_post(const char *host, int port, const char *path_and_query,
                  const char *const headers[], size_t header_count,
                  const uint8_t *body, size_t body_len,
                  uint8_t *resp, size_t resp_cap, size_t *resp_len,
                  int timeout_ms);

/// 从完整 HTTP 响应中提取响应头（大小写不敏感）。无则返回 0。
int kpq_http_header(const uint8_t *resp, size_t resp_len,
                    const char *name, char *out, size_t out_cap);

/// 从完整 HTTP 响应中定位 body 起始偏移；无 body 分隔返回 -1。
int kpq_http_body_offset(const uint8_t *resp, size_t resp_len);

#ifdef __cplusplus
}
#endif

#endif
