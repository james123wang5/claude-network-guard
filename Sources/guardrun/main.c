// guardrun <程序> [参数...]   安装后为 root:appnetguard、权限 2755（setgid）。
// 先向守护进程确认保护已就绪，再以受限组身份原地执行目标程序；未就绪即拒绝。
// 组身份一经设置无法由普通进程退出，子进程（Helper、MCP、命令行工具）自动继承。
#include "GuardConfine.h"
#include <dlfcn.h>
#include <errno.h>
#include <grp.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#ifndef GUARD_SOCKET
#define GUARD_SOCKET "/var/run/appnetworkguard/control.sock"
#endif
#define GUARD_SHELLS "/Library/PrivilegedHelperTools/AppNetworkGuard/shell"
#ifndef GUARD_GROUP
#define GUARD_GROUP "appnetguard"
#endif

extern char **environ;

static int armed(void) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, GUARD_SOCKET, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0), ready = 0;
    struct timeval limit = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    static const char request[] = "{\"command\":\"status\"}\n";
    char reply[65536];
    size_t size = 0;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0 &&
        write(fd, request, sizeof(request) - 1) == (ssize_t)sizeof(request) - 1) {
        ssize_t n;
        while (size < sizeof(reply) - 1 && (n = read(fd, reply + size, sizeof(reply) - 1 - size)) > 0) size += (size_t)n;
        reply[size] = 0;
        ready = strstr(reply, "\"state\":\"armed\"") != NULL;
    }
    close(fd);
    return ready;
}

int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/') { fprintf(stderr, "usage: guardrun /absolute/program [args]\n"); return 64; }
    struct group *group = getgrnam(GUARD_GROUP);
    if (!group || getegid() != group->gr_gid || geteuid() == 0) { fprintf(stderr, "guardrun: 隔离组未就绪\n"); return 77; }
    if (!armed()) { fprintf(stderr, "guardrun: 保护未就绪，拒绝启动\n"); return 75; }
    gid_t gid = group->gr_gid;
    if (setregid(gid, gid) || getgid() != gid || getegid() != gid) { perror("guardrun: setregid"); return 77; }

    // 清除外部代理与动态库注入变量；代理变量由 GUARD_PROXY 统一设置。
    static const char *drop[] = {"http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY",
                                 "ALL_PROXY", "NO_PROXY", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "NODE_OPTIONS"};
    for (size_t i = 0; i < sizeof(drop) / sizeof(*drop); i++) unsetenv(drop[i]);
    const char *port = getenv("GUARD_PROXY");
    if (port && atoi(port) > 0) {
        char proxy[64];
        snprintf(proxy, sizeof(proxy), "http://127.0.0.1:%d", atoi(port));
        static const char *set[] = {"http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"};
        for (size_t i = 0; i < sizeof(set) / sizeof(*set); i++) setenv(set[i], proxy, 1);
        setenv("NO_PROXY", "localhost,127.0.0.1,::1", 1);
        setenv("no_proxy", "localhost,127.0.0.1,::1", 1);
        setenv("NODE_USE_ENV_PROXY", "1", 1);
        // ssh 不看代理变量；默认线路是 VPN 时改道的回包会被系统丢弃，所以让 git 的 ssh 走转发器。
        char ssh[160];
        snprintf(ssh, sizeof(ssh), "ssh -o ProxyCommand='/usr/bin/nc -X 5 -x 127.0.0.1:%d %%h %%p'", atoi(port));
        setenv("GIT_SSH_COMMAND", ssh, 0);
    }
    unsetenv("GUARD_PROXY");

    const char *frameworks = getenv("GUARD_CONFINE");  // 存在即启用；值为豁免的 Frameworks 目录，可为空
    if (frameworks) {
        int locked = getenv("GUARD_LOCK") != NULL;
        if (guard_confine(frameworks, locked)) return 78;  // 不能限制就不启动
        // 豁免的 Helper 里有的会再开终端（Claude 的终端面板），它的子进程继承不到限制。
        // 让它们经 guardshell 启动，由 guardshell 补上同样的限制。
        const char *shell = getenv("SHELL");
        const char *wrapped = !shell ? NULL : !strcmp(shell, "/bin/zsh") ? GUARD_SHELLS "/zsh" : !strcmp(shell, "/bin/bash") ? GUARD_SHELLS "/bash" : NULL;
        if (*frameworks && wrapped && access(wrapped, X_OK) == 0) {
            setenv("SHELL", wrapped, 1);
            if (locked) setenv("GUARD_SHELL_LOCK", "1", 1); else unsetenv("GUARD_SHELL_LOCK");
        }
        unsetenv("GUARD_CONFINE");
        unsetenv("GUARD_LOCK");
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // 会话首进程或已是组长时不能再设置进程组，否则内核会在替换映像后直接结束进程。
    short flags = POSIX_SPAWN_SETEXEC;
    if (getpgrp() != getpid() && getsid(0) != getpid()) flags |= POSIX_SPAWN_SETPGROUP;
    posix_spawnattr_setflags(&attributes, flags);
    posix_spawnattr_setpgroup(&attributes, 0);
    // 让目标应用自己承担隐私授权身份（相机、文件夹等提示归它，而不是归 Guard）。
    int (*disclaim)(posix_spawnattr_t *, int) = (int (*)(posix_spawnattr_t *, int))dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (disclaim) disclaim(&attributes, 1);
    errno = posix_spawn(NULL, argv[1], NULL, &attributes, argv + 1, environ);
    perror("guardrun: 启动失败");
    return 71;
}
