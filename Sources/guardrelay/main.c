// guardrelay <网卡> <DNS,逗号分隔> <端口|0> <uid> <gid>
// 只绑定到指定网卡的本机转发器：同一端口支持 SOCKS5、HTTP CONNECT 和普通 HTTP。
// 域名在该网卡上自行解析，不经过系统 DNS。网卡不可用时所有连接失败，不会改走其他网卡。
// 由守护进程启动；降权后运行；标准输入关闭即退出。
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define MAX_CLIENTS 512
#define BUFFER 65536

static char interface_name[IFNAMSIZ];
static unsigned int interface_index;
static struct in_addr dns_servers[4];
static int dns_count;
static atomic_int clients;
static atomic_ullong sent_bytes, received_bytes;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int bound_socket(int type) {
    // 网卡重新插拔后索引会变；索引不符即拒绝，由守护进程重新核对。
    if (if_nametoindex(interface_name) != interface_index) { errno = ENETDOWN; return -1; }
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) return -1;
    unsigned int check = 0;
    socklen_t size = sizeof(check);
    int one = 1;
    if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interface_index, sizeof(interface_index)) ||
        getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &check, &size) || check != interface_index) {
        close(fd);
        errno = ENETDOWN;
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    return fd;
}

static bool public_address(struct in_addr address) {
    uint32_t a = ntohl(address.s_addr);
    uint8_t b1 = a >> 24, b2 = (a >> 16) & 255;
    if (b1 == 0 || b1 == 10 || b1 == 127 || b1 >= 224) return false;
    if (b1 == 100 && b2 >= 64 && b2 <= 127) return false;
    if (b1 == 169 && b2 == 254) return false;
    if (b1 == 172 && b2 >= 16 && b2 <= 31) return false;
    if (b1 == 192 && b2 == 168) return false;
    if (b1 == 198 && (b2 == 18 || b2 == 19)) return false;
    return true;
}

// ---- DNS（A 记录，UDP，只从绑定网卡发出） ----

struct cached { char name[256]; struct in_addr address[4]; int count; double expires; };
static struct cached cache[256];
static pthread_mutex_t cache_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t hash_name(const char *name) {
    uint32_t h = 2166136261u;
    for (; *name; name++) h = (h ^ (uint8_t)*name) * 16777619u;
    return h;
}

static int skip_name(const uint8_t *data, int size, int offset) {
    while (offset < size) {
        uint8_t length = data[offset];
        if (length == 0) return offset + 1;
        if ((length & 0xC0) == 0xC0) return offset + 2 <= size ? offset + 2 : -1;
        if (length & 0xC0) return -1;
        offset += length + 1;
    }
    return -1;
}

static int query_dns(const char *name, struct in_addr server, struct in_addr out[4], uint32_t *ttl) {
    uint8_t packet[512] = {0};
    uint16_t id = (uint16_t)arc4random();
    packet[0] = id >> 8; packet[1] = (uint8_t)id; packet[2] = 1; packet[5] = 1;
    int at = 12;
    for (const char *part = name; *part;) {
        const char *dot = strchr(part, '.');
        size_t length = dot ? (size_t)(dot - part) : strlen(part);
        if (length == 0 || length > 63 || at + (int)length + 6 > (int)sizeof(packet)) return -1;
        packet[at++] = (uint8_t)length;
        memcpy(packet + at, part, length);
        at += (int)length;
        part += length + (dot ? 1 : 0);
    }
    at++;
    packet[at++] = 0; packet[at++] = 1; packet[at++] = 0; packet[at++] = 1;

    int fd = bound_socket(SOCK_DGRAM);
    if (fd < 0) return -1;
    struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(53), .sin_addr = server};
    int count = -1;
    if (connect(fd, (struct sockaddr *)&to, sizeof(to)) == 0 && send(fd, packet, (size_t)at, 0) == at) {
        double deadline = now() + 2;
        uint8_t reply[1500];
        while (count < 0) {
            int wait = (int)((deadline - now()) * 1000);
            struct pollfd p = {.fd = fd, .events = POLLIN};
            if (wait <= 0 || poll(&p, 1, wait) <= 0) break;
            ssize_t size = recv(fd, reply, sizeof(reply), 0);
            if (size < 0) break;
            if (size < 12 || reply[0] != packet[0] || reply[1] != packet[1] || !(reply[2] & 0x80)) continue;
            count = 0;
            if (reply[3] & 0x0F) break;
            int offset = 12, questions = reply[4] << 8 | reply[5], answers = reply[6] << 8 | reply[7];
            while (questions-- > 0 && offset > 0) { offset = skip_name(reply, (int)size, offset); if (offset > 0) offset += 4; }
            *ttl = 60;
            while (answers-- > 0 && offset > 0 && count < 4) {
                offset = skip_name(reply, (int)size, offset);
                if (offset < 0 || offset + 10 > size) break;
                int type = reply[offset] << 8 | reply[offset + 1];
                uint32_t life = (uint32_t)reply[offset + 4] << 24 | reply[offset + 5] << 16 | reply[offset + 6] << 8 | reply[offset + 7];
                int length = reply[offset + 8] << 8 | reply[offset + 9];
                offset += 10;
                if (offset + length > size) break;
                if (type == 1 && length == 4) { memcpy(&out[count++], reply + offset, 4); if (life < *ttl) *ttl = life; }
                offset += length;
            }
        }
    }
    close(fd);
    return count;
}

static int resolve(const char *host, struct in_addr out[4]) {
    if (inet_pton(AF_INET, host, &out[0]) == 1) return 1;
    char name[256];
    size_t length = strlen(host);
    if (length && host[length - 1] == '.') length--;
    if (length == 0 || length > 253) return 0;
    for (size_t i = 0; i < length; i++) {
        char c = (char)tolower((unsigned char)host[i]);
        if (!isalnum((unsigned char)c) && c != '-' && c != '.' && c != '_') return 0;
        name[i] = c;
    }
    name[length] = 0;
    struct cached *slot = &cache[hash_name(name) % 256];
    pthread_mutex_lock(&cache_lock);
    if (slot->expires > now() && strcmp(slot->name, name) == 0) {
        int count = slot->count;
        memcpy(out, slot->address, sizeof(slot->address));
        pthread_mutex_unlock(&cache_lock);
        return count;
    }
    pthread_mutex_unlock(&cache_lock);
    for (int attempt = 0; attempt < 2 * dns_count; attempt++) {
        uint32_t ttl = 0;
        int count = query_dns(name, dns_servers[attempt % dns_count], out, &ttl);
        if (count > 0) {
            pthread_mutex_lock(&cache_lock);
            strlcpy(slot->name, name, sizeof(slot->name));
            memcpy(slot->address, out, sizeof(slot->address));
            slot->count = count;
            slot->expires = now() + (ttl < 5 ? 5 : ttl);
            pthread_mutex_unlock(&cache_lock);
            return count;
        }
        if (count == 0) return 0;
    }
    return 0;
}

// ---- 连接 ----

static int dial(const char *host, uint16_t port) {
    // 53 端口可能被系统的 DNS 代理扩展接管而不走绑定的网卡，一律不转发。
    if (port == 53) { errno = EACCES; return -1; }
    struct in_addr addresses[4];
    int count = resolve(host, addresses);
    errno = EHOSTUNREACH;
    for (int i = 0; i < count; i++) {
        if (!public_address(addresses[i])) { errno = EACCES; continue; }
        int fd = bound_socket(SOCK_STREAM);
        if (fd < 0) return -1;
        struct sockaddr_in to = {.sin_len = sizeof(to), .sin_family = AF_INET, .sin_port = htons(port), .sin_addr = addresses[i]};
        int flags = fcntl(fd, F_GETFL);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int result = connect(fd, (struct sockaddr *)&to, sizeof(to));
        if (result < 0 && errno == EINPROGRESS) {
            struct pollfd p = {.fd = fd, .events = POLLOUT};
            int error = ETIMEDOUT;
            socklen_t size = sizeof(error);
            if (poll(&p, 1, 6000) > 0) getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
            errno = error;
            result = error ? -1 : 0;
        }
        if (result == 0) {
            int one = 1;
            fcntl(fd, F_SETFL, flags);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            return fd;
        }
        int saved = errno;
        close(fd);
        errno = saved;
    }
    return -1;
}

static bool write_all(int fd, const void *data, size_t size) {
    const char *p = data;
    while (size) {
        ssize_t n = send(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= (size_t)n;
    }
    return true;
}

static bool read_exact(int fd, void *data, size_t size) {
    char *p = data;
    while (size) {
        ssize_t n = recv(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        size -= (size_t)n;
    }
    return true;
}

static void exchange(int client, int upstream) {
    char *buffer = malloc(BUFFER);
    if (!buffer) return;
    struct timeval none = {0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof(none));
    struct pollfd fds[2] = {{.fd = client, .events = POLLIN}, {.fd = upstream, .events = POLLIN}};
    int open = 2;
    while (open > 0) {
        if (poll(fds, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        bool failed = false;
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            int source = i ? upstream : client, target = i ? client : upstream;
            ssize_t n = recv(source, buffer, BUFFER, 0);
            if (n < 0) { if (errno == EINTR || errno == EAGAIN) continue; failed = true; break; }
            if (n == 0) { shutdown(target, SHUT_WR); fds[i].fd = -1; open--; continue; }
            if (!write_all(target, buffer, (size_t)n)) { failed = true; break; }
            atomic_fetch_add(i ? &received_bytes : &sent_bytes, (unsigned long long)n);
        }
        if (failed) break;
    }
    free(buffer);
}

static void socks(int client) {
    uint8_t b[262], count;
    if (!read_exact(client, &count, 1) || !read_exact(client, b, count)) return;
    bool plain = memchr(b, 0, count) != NULL;
    uint8_t method[2] = {5, plain ? 0 : 0xFF};
    if (!write_all(client, method, 2) || !plain || !read_exact(client, b, 4)) return;
    uint8_t reply[10] = {5, 7, 0, 1, 0, 0, 0, 0, 0, 0};
    if (b[0] != 5) return;
    char host[256];
    uint8_t command = b[1], kind = b[3];
    if (kind == 1) {
        struct in_addr a;
        if (!read_exact(client, &a, 4) || !inet_ntop(AF_INET, &a, host, sizeof(host))) return;
    } else if (kind == 3) {
        uint8_t length;
        if (!read_exact(client, &length, 1) || !read_exact(client, host, length)) return;
        host[length] = 0;
        if (strlen(host) != length) return;
    } else {
        reply[1] = 8;  // 该线路只使用 IPv4
        write_all(client, reply, 10);
        return;
    }
    uint8_t raw[2];
    if (!read_exact(client, raw, 2)) return;
    if (command != 1) { write_all(client, reply, 10); return; }  // 拒绝 UDP ASSOCIATE / BIND
    int upstream = dial(host, (uint16_t)(raw[0] << 8 | raw[1]));
    reply[1] = upstream >= 0 ? 0 : 4;
    if (write_all(client, reply, 10) && upstream >= 0) exchange(client, upstream);
    if (upstream >= 0) close(upstream);
}

static bool split_authority(char *authority, uint16_t fallback, uint16_t *port) {
    char *colon = strrchr(authority, ':');
    *port = fallback;
    if (colon) {
        char *end;
        long value = strtol(colon + 1, &end, 10);
        if (colon[1] == 0 || *end || value < 1 || value > 65535) return false;
        *port = (uint16_t)value;
        *colon = 0;
    }
    return *authority && *authority != '[';
}

static void http(int client, char first) {
    static const char refused[] = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    char *head = malloc(BUFFER);
    if (!head) return;
    size_t size = 1;
    head[0] = first;
    char *end = NULL;
    while (!end && size < BUFFER - 1) {
        ssize_t n = recv(client, head + size, BUFFER - 1 - size, 0);
        if (n <= 0) { free(head); return; }
        size += (size_t)n;
        head[size] = 0;
        end = strstr(head, "\r\n\r\n");
    }
    char *line_end = end ? strstr(head, "\r\n") : NULL;
    char method[16], target[4096], version[16];
    int upstream = -1;
    if (line_end) {
        *line_end = 0;
        if (sscanf(head, "%15s %4095s %15s", method, target, version) == 3) {
            char host[512];
            uint16_t port;
            if (strcmp(method, "CONNECT") == 0) {
                if (strlcpy(host, target, sizeof(host)) < sizeof(host) && split_authority(host, 443, &port))
                    upstream = dial(host, port);
                if (upstream >= 0 && write_all(client, "HTTP/1.1 200 Connection Established\r\n\r\n", 39)) {
                    size_t rest = size - (size_t)(end + 4 - head);
                    if (!rest || write_all(upstream, end + 4, rest)) exchange(client, upstream);
                }
            } else if (strncasecmp(target, "http://", 7) == 0) {
                char *path = strchr(target + 7, '/');
                size_t length = path ? (size_t)(path - target - 7) : strlen(target + 7);
                if (length < sizeof(host)) {
                    memcpy(host, target + 7, length);
                    host[length] = 0;
                    if (split_authority(host, 80, &port)) upstream = dial(host, port);
                }
                if (upstream >= 0) {
                    // 每条连接只承载一个请求，避免同一连接上的后续请求指向其他主机。
                    char *request = malloc(BUFFER);
                    size_t used = request ? (size_t)snprintf(request, BUFFER, "%s %s %s\r\n", method, path ? path : "/", version) : 0;
                    char *cursor = line_end + 2;
                    while (request && cursor < end + 2) {
                        char *next = strstr(cursor, "\r\n");
                        size_t width = (size_t)(next - cursor);
                        if (strncasecmp(cursor, "Proxy-", 6) && strncasecmp(cursor, "Connection:", 11) && used + width + 2 < BUFFER) {
                            memcpy(request + used, cursor, width + 2);
                            used += width + 2;
                        }
                        cursor = next + 2;
                    }
                    if (request && used + 21 < BUFFER) {
                        memcpy(request + used, "Connection: close\r\n\r\n", 21);
                        used += 21;
                        size_t rest = size - (size_t)(end + 4 - head);
                        if (write_all(upstream, request, used) && (!rest || write_all(upstream, end + 4, rest)))
                            exchange(client, upstream);
                    }
                    free(request);
                }
            }
        }
    }
    if (upstream < 0) write_all(client, refused, sizeof(refused) - 1);
    else close(upstream);
    free(head);
}

static void *serve(void *argument) {
    int client = (int)(intptr_t)argument;
    char first;
    if (read_exact(client, &first, 1)) {
        if (first == 5) socks(client);
        else http(client, first);
    }
    close(client);
    atomic_fetch_sub(&clients, 1);
    return NULL;
}

static void *report(void *argument) {
    (void)argument;
    for (;;) {
        sleep(1);
        printf("bytes %llu %llu %d\n", atomic_load(&sent_bytes), atomic_load(&received_bytes), atomic_load(&clients));
        fflush(stdout);
    }
    return NULL;
}

static void *watch_owner(void *argument) {
    (void)argument;
    char byte;
    while (read(STDIN_FILENO, &byte, 1) > 0) {}
    _exit(0);
}

int main(int argc, char **argv) {
    if (argc != 6) return 64;
    signal(SIGPIPE, SIG_IGN);
    uid_t uid = (uid_t)strtoul(argv[4], NULL, 10);
    gid_t gid = (gid_t)strtoul(argv[5], NULL, 10);
    if (geteuid() == 0 && (uid == 0 || gid == 0 || setgroups(1, &gid) || setgid(gid) || setuid(uid) || geteuid() == 0)) return 77;
    if (strlcpy(interface_name, argv[1], sizeof(interface_name)) >= sizeof(interface_name)) return 64;
    interface_index = if_nametoindex(interface_name);
    if (!interface_index) return 69;
    for (char *part = strtok(argv[2], ","); part && dns_count < 4; part = strtok(NULL, ","))
        if (inet_pton(AF_INET, part, &dns_servers[dns_count]) == 1) dns_count++;
    if (!dns_count) return 64;

    int one = 1, listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in local = {.sin_len = sizeof(local), .sin_family = AF_INET,
                                .sin_port = htons((uint16_t)atoi(argv[3])), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t size = sizeof(local);
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (listener < 0 || bind(listener, (struct sockaddr *)&local, sizeof(local)) || listen(listener, 256) ||
        getsockname(listener, (struct sockaddr *)&local, &size)) { perror("listen"); return 71; }
    printf("port %d\n", ntohs(local.sin_port));
    fflush(stdout);

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attributes, 256 * 1024);
    pthread_t thread;
    pthread_create(&thread, &attributes, watch_owner, NULL);
    pthread_create(&thread, &attributes, report, NULL);
    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) { if (errno == EINTR || errno == ECONNABORTED) continue; usleep(20000); continue; }
        struct timeval limit = {.tv_sec = 15};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (atomic_fetch_add(&clients, 1) >= MAX_CLIENTS ||
            pthread_create(&thread, &attributes, serve, (void *)(intptr_t)client)) {
            atomic_fetch_sub(&clients, 1);
            close(client);
        }
    }
}
