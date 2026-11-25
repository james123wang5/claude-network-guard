// guardcheck <USB网卡> <默认网卡> <转发端口|0>
// 由 guardrun 在受限组内运行，主动尝试从其他线路联网，输出一行 JSON 证据。
#include "BoundTransport.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static void trace_ip(int ok, const char *body, char out[64]) {
    out[0] = 0;
    const char *at = ok ? strstr(body, "ip=") : NULL;
    if (at) sscanf(at + 3, "%63[0-9a-fA-F.:]", out);
}

static void fetch(const char *name, const char *interface, const char *proxy, const char *url, int timeout) {
    char body[8192], ip[64];
    trace_ip(guard_https_get(url, interface, proxy, timeout, body, sizeof(body)), body, ip);
    printf("\"%s\":\"%s\",", name, ip);
}

// UDP 53：公共 DNS 会回报它看到的来源地址，用来判断 UDP 从哪条线路出去。
static void udp_identity(const char *name, unsigned int interface) {
    unsigned char query[] = "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x06whoami\x0a" "cloudflare\x00\x00\x10\x00\x03";
    unsigned char reply[512];
    char found[64] = "";
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(53)};
    inet_pton(AF_INET, "1.0.0.1", &to.sin_addr);
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval limit = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    if (interface) setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interface, sizeof(interface));
    ssize_t n = -1;
    if (connect(fd, (struct sockaddr *)&to, sizeof(to)) == 0 && send(fd, query, sizeof(query) - 1, 0) > 0)
        n = recv(fd, reply, sizeof(reply), 0);
    for (ssize_t i = n - 1; i > 12; i--)
        if (reply[i] < 32 || reply[i] > 126) { snprintf(found, sizeof(found), "%.*s", (int)(n - i - 1), reply + i + 1); break; }
    for (char *c = found; *c; c++) if (!strchr("0123456789abcdef.:", *c)) *c = '?';
    printf("\"%s\":\"%s\",", name, found);
    close(fd);
}

// UDP 443：发送一个不合法的 QUIC 版本协商探测；若线路放行，服务器会回应。
static void quic_open(const char *name, unsigned int interface) {
    unsigned char packet[1200] = {0xC0, 0x1a, 0x2a, 0x3a, 0x4a, 8, 1, 2, 3, 4, 5, 6, 7, 8, 8, 1, 2, 3, 4, 5, 6, 7, 8};
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(443)};
    inet_pton(AF_INET, "1.0.0.1", &to.sin_addr);
    int fd = socket(AF_INET, SOCK_DGRAM, 0), open = 0;
    struct timeval limit = {.tv_sec = 2};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    if (interface) setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interface, sizeof(interface));
    if (connect(fd, (struct sockaddr *)&to, sizeof(to)) == 0 && send(fd, packet, sizeof(packet), 0) > 0) {
        unsigned char reply[1500];
        open = recv(fd, reply, sizeof(reply), 0) > 0;
    }
    printf("\"%s\":%s,", name, open ? "true" : "false");
    close(fd);
}

static void tcp_open(const char *name, const char *host, int port, int family) {
    int fd = socket(family, SOCK_STREAM, 0), result = -1;
    union { struct sockaddr any; struct sockaddr_in v4; struct sockaddr_in6 v6; } to = {0};
    if (family == AF_INET) {
        to.v4 = (struct sockaddr_in){.sin_len = sizeof(to.v4), .sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
        inet_pton(AF_INET, host, &to.v4.sin_addr);
    } else {
        to.v6 = (struct sockaddr_in6){.sin6_len = sizeof(to.v6), .sin6_family = AF_INET6, .sin6_port = htons((uint16_t)port)};
        inet_pton(AF_INET6, host, &to.v6.sin6_addr);
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    if (connect(fd, &to.any, to.any.sa_len) == 0) result = 0;
    else if (errno == EINPROGRESS) {
        struct pollfd wait = {.fd = fd, .events = POLLOUT};
        int error = ETIMEDOUT;
        socklen_t size = sizeof(error);
        if (poll(&wait, 1, 2000) > 0) getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
        result = error ? -1 : 0;
    }
    printf("\"%s\":%s,", name, result == 0 ? "true" : "false");
    close(fd);
}

int main(int argc, char **argv) {
    if (argc != 4) return 64;
    unsigned int other = if_nametoindex(argv[2]);
    char proxy[64] = "", iface[IF_NAMESIZE], gateway[64];
    int blocked = 0;
    printf("{\"gid\":%d,", (int)getegid());
    fetch("tcp", NULL, NULL, "https://1.1.1.1/cdn-cgi/trace", 9000);
    fetch("tcpForced", argv[2], NULL, "https://1.0.0.1/cdn-cgi/trace", 5000);
    if (atoi(argv[3]) > 0) {
        snprintf(proxy, sizeof(proxy), "http://127.0.0.1:%d", atoi(argv[3]));
        fetch("relay", NULL, proxy, "https://www.cloudflare.com/cdn-cgi/trace", 12000);
    }
    udp_identity("udp", 0);
    quic_open("quic", 0);
    quic_open("quicForced", other);
    if (guard_route("1.1.1.1", iface, sizeof(iface), gateway, sizeof(gateway), &blocked) && strncmp(gateway, "link", 4))
        tcp_open("lan", gateway, 80, AF_INET);
    tcp_open("dnsTCP", "1.1.1.1", 53, AF_INET);
    tcp_open("ipv6", "2606:4700:4700::1111", 443, AF_INET6);
    printf("\"done\":true}\n");
    return 0;
}
