// 以 zsh / bash 的名字安装在 shell 目录里。受限组内、尚未套上进程级限制时先补上，再原地执行真正的 shell。
// 不在受限组内时（例如被复制到别处使用）什么都不做，直接执行。
#include "GuardConfine.h"
#include <grp.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <sandbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef GUARD_GROUP
#define GUARD_GROUP "appnetguard"
#endif

// libsystem_sandbox 导出、头文件未声明：操作为空时返回进程是否已在沙箱内。
int sandbox_check(pid_t pid, const char *operation, int type, ...);

int main(int argc, char **argv) {
    (void)argc;
    // 登录 shell 的 argv[0] 会被改写，所以看文件本身的名字。
    char path[4096];
    uint32_t size = sizeof(path);
    const char *name = _NSGetExecutablePath(path, &size) == 0 && strrchr(path, '/') ? strrchr(path, '/') + 1 : "zsh";
    const char *target = !strcmp(name, "bash") ? "/bin/bash" : "/bin/zsh";
    struct group *group = getgrnam(GUARD_GROUP);
    if (group && getegid() == group->gr_gid && sandbox_check(getpid(), NULL, 0) == 0 &&
        guard_confine("", getenv("GUARD_SHELL_LOCK") != NULL)) {
        fprintf(stderr, "Claude Network Guard：限制未生效，没有打开终端\n");
        return 78;
    }
    setenv("SHELL", target, 1);
    execv(target, argv);
    perror(target);
    return 71;
}
