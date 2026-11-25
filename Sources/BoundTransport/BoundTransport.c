#include "BoundTransport.h"

#include <arpa/inet.h>
#include <curl/curl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <pthread.h>
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <stdatomic.h>
#include <unistd.h>

struct request {
    unsigned int interface_index;
    int family;
    char *body;
    size_t capacity;
    size_t length;
};

static pthread_once_t curl_once = PTHREAD_ONCE_INIT;
static CURLcode init_result = CURLE_FAILED_INIT;

static void initialize_curl(void) {
    init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static curl_socket_t open_bound_socket(void *context, curlsocktype purpose,
                                       struct curl_sockaddr *address) {
    const struct request *request = context;
    if (purpose != CURLSOCKTYPE_IPCXN || address->family != request->family ||
        address->socktype != SOCK_STREAM) {
        return CURL_SOCKET_BAD;
    }

    int fd = socket(address->family, address->socktype, address->protocol);
    if (fd < 0) {
        return CURL_SOCKET_BAD;
    }

    int level = address->family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6;
    int option = address->family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF;
    unsigned int confirmed_index = 0;
    socklen_t confirmed_length = sizeof(confirmed_index);
    if (setsockopt(fd, level, option, &request->interface_index, sizeof(request->interface_index)) != 0 ||
        getsockopt(fd, level, option, &confirmed_index, &confirmed_length) != 0 ||
        confirmed_index != request->interface_index) {
        close(fd);
        return CURL_SOCKET_BAD;
    }
    return fd;
}

static size_t append_body(char *bytes, size_t size, size_t count, void *context) {
    struct request *request = context;
    size_t space = request->capacity - request->length - 1;
    if (size == 0 || count > space / size) {
        return 0;
    }
    size_t length = size * count;
    memcpy(request->body + request->length, bytes, length);
    request->length += length;
    request->body[request->length] = '\0';
    return length;
}

int guard_bound_https_get(const char *url, const char *interface_name,
                          int family, char *body, size_t body_capacity,
                          char *local_ip, size_t local_ip_capacity) {
    if ((family != AF_INET && family != AF_INET6) ||
        body_capacity == 0 || local_ip_capacity == 0 ||
        strncmp(url, "https://", 8) != 0) {
        return 0;
    }

    struct request request = {
        .interface_index = if_nametoindex(interface_name),
        .family = family,
        .body = body,
        .capacity = body_capacity
    };
    if (request.interface_index == 0 || pthread_once(&curl_once, initialize_curl) != 0 ||
        init_result != CURLE_OK) {
        return 0;
    }

    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        return 0;
    }

    int ok = 0;
    long response = 0;
    char *source = NULL;
    body[0] = '\0';
    local_ip[0] = '\0';

    // Abort on any configuration failure, especially if the socket callback cannot be installed.
    if (curl_easy_setopt(curl, CURLOPT_URL, url) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_PROXY, "") != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_IPRESOLVE, (long)(family == AF_INET ? CURL_IPRESOLVE_V4 : CURL_IPRESOLVE_V6)) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 3000L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 5000L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_OPENSOCKETFUNCTION, open_bound_socket) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_OPENSOCKETDATA, &request) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_body) != CURLE_OK ||
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &request) != CURLE_OK) {
        goto done;
    }

    if (curl_easy_perform(curl) == CURLE_OK &&
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response) == CURLE_OK && response == 200 &&
        curl_easy_getinfo(curl, CURLINFO_LOCAL_IP, &source) == CURLE_OK && source != NULL &&
        if_nametoindex(interface_name) == request.interface_index &&
        strlcpy(local_ip, source, local_ip_capacity) < local_ip_capacity) {
        ok = 1;
    }

done:
    curl_easy_cleanup(curl);
    return ok;
}

int guard_https_get(const char *url, const char *interface_name, const char *proxy,
                    int timeout_ms, char *body, size_t body_capacity) {
    return guard_https_status(url, interface_name, proxy, timeout_ms, body, body_capacity) == 200;
}

int guard_https_status(const char *url, const char *interface_name, const char *proxy,
                       int timeout_ms, char *body, size_t body_capacity) {
    if (body_capacity == 0 || strncmp(url, "https://", 8) != 0 ||
        pthread_once(&curl_once, initialize_curl) != 0 || init_result != CURLE_OK) return 0;
    struct request request = {.family = AF_INET, .body = body, .capacity = body_capacity};
    CURL *curl = curl_easy_init();
    if (curl == NULL) return 0;
    int ok = 0;
    long response = 0;
    body[0] = '\0';
    CURLcode setup = curl_easy_setopt(curl, CURLOPT_URL, url);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_PROXY, proxy ? proxy : "");
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_V4);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)timeout_ms);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, append_body);
    if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_WRITEDATA, &request);
    if (setup == CURLE_OK && interface_name != NULL) {
        request.interface_index = if_nametoindex(interface_name);
        if (request.interface_index == 0) setup = CURLE_INTERFACE_FAILED;
        else {
            setup = curl_easy_setopt(curl, CURLOPT_OPENSOCKETFUNCTION, open_bound_socket);
            if (setup == CURLE_OK) setup = curl_easy_setopt(curl, CURLOPT_OPENSOCKETDATA, &request);
        }
    }
    if (setup == CURLE_OK && curl_easy_perform(curl) == CURLE_OK &&
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response) == CURLE_OK) ok = (int)response;
    curl_easy_cleanup(curl);
    return ok;
}

#define ROUNDUP(a) ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

int guard_route(const char *destination, char *interface_name, size_t interface_capacity,
                char *gateway, size_t gateway_capacity, int *blocked) {
    static atomic_int sequence;
    struct { struct rt_msghdr header; char data[512]; } message;
    union { struct sockaddr any; struct sockaddr_in v4; struct sockaddr_in6 v6; } target;
    memset(&message, 0, sizeof(message));
    memset(&target, 0, sizeof(target));
    if (inet_pton(AF_INET, destination, &target.v4.sin_addr) == 1) {
        target.v4.sin_len = sizeof(target.v4);
        target.v4.sin_family = AF_INET;
    } else if (inet_pton(AF_INET6, destination, &target.v6.sin6_addr) == 1) {
        target.v6.sin6_len = sizeof(target.v6);
        target.v6.sin6_family = AF_INET6;
    } else return 0;
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return 0;
    int number = atomic_fetch_add(&sequence, 1) + 1;
    message.header.rtm_version = RTM_VERSION;
    message.header.rtm_type = RTM_GET;
    message.header.rtm_addrs = RTA_DST | RTA_IFP;
    message.header.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_HOST;
    message.header.rtm_pid = getpid();
    message.header.rtm_seq = number;
    char *cursor = message.data;
    memcpy(cursor, &target, target.any.sa_len);
    cursor += ROUNDUP(target.any.sa_len);
    struct sockaddr_dl link = {.sdl_len = sizeof(link), .sdl_family = AF_LINK};
    memcpy(cursor, &link, sizeof(link));
    cursor += ROUNDUP(sizeof(link));
    message.header.rtm_msglen = (unsigned short)(cursor - (char *)&message);
    int ok = 0;
    if (write(fd, &message, message.header.rtm_msglen) == message.header.rtm_msglen) {
        for (int i = 0; i < 64; i++) {
            struct pollfd wait = {.fd = fd, .events = POLLIN};
            if (poll(&wait, 1, 500) <= 0) break;
            ssize_t size = read(fd, &message, sizeof(message));
            if (size < (ssize_t)sizeof(message.header)) break;
            if (message.header.rtm_seq != number || message.header.rtm_pid != getpid() || message.header.rtm_type != RTM_GET) continue;
            if (message.header.rtm_errno) break;
            interface_name[0] = gateway[0] = '\0';
            cursor = message.data;
            char *end = (char *)&message + size;
            for (int bit = 1; bit && cursor < end; bit <<= 1) {
                if (!(message.header.rtm_addrs & bit)) continue;
                struct sockaddr *address = (struct sockaddr *)cursor;
                if (bit == RTA_GATEWAY) {
                    if (address->sa_family == AF_INET) inet_ntop(AF_INET, &((struct sockaddr_in *)address)->sin_addr, gateway, (socklen_t)gateway_capacity);
                    else if (address->sa_family == AF_INET6) inet_ntop(AF_INET6, &((struct sockaddr_in6 *)address)->sin6_addr, gateway, (socklen_t)gateway_capacity);
                    else if (address->sa_family == AF_LINK) strlcpy(gateway, "link", gateway_capacity);
                } else if (bit == RTA_IFP && address->sa_family == AF_LINK) {
                    struct sockaddr_dl *dl = (struct sockaddr_dl *)address;
                    if (dl->sdl_nlen > 0 && dl->sdl_nlen < interface_capacity) {
                        memcpy(interface_name, dl->sdl_data, dl->sdl_nlen);
                        interface_name[dl->sdl_nlen] = '\0';
                    }
                }
                cursor += ROUNDUP(address->sa_len);
            }
            if (interface_name[0] == '\0') {
                char name[IF_NAMESIZE];
                if (if_indextoname(message.header.rtm_index, name)) strlcpy(interface_name, name, interface_capacity);
            }
            *blocked = (message.header.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE)) != 0;
            ok = interface_name[0] != '\0';
            break;
        }
    }
    close(fd);
    return ok;
}
