#ifndef BOUND_TRANSPORT_H
#define BOUND_TRANSPORT_H
#include <stddef.h>

// 只经指定网卡的 HTTPS GET。成功返回 1。
int guard_bound_https_get(const char *url, const char *interface_name,
                          int family, char *body, size_t body_capacity,
                          char *local_ip, size_t local_ip_capacity);

// 按系统路由（interface_name 为空）或绑定网卡的 HTTPS GET，可选代理。成功返回 1，失败返回 0。
// 同上，但返回 HTTP 状态码；没有收到响应返回 0。
int guard_https_status(const char *url, const char *interface_name, const char *proxy,
                       int timeout_ms, char *body, size_t body_capacity);
int guard_https_get(const char *url, const char *interface_name, const char *proxy,
                    int timeout_ms, char *body, size_t body_capacity);

// 内核路由查询，等价于 `route -n get`，不启动子进程。成功返回 1。
int guard_route(const char *destination, char *interface_name, size_t interface_capacity,
                char *gateway, size_t gateway_capacity, int *blocked);
#endif
