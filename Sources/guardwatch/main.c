// guardwatch <pid> <可执行路径> <启动秒> <启动微秒> <日志文件> [超时秒]
// Guard 会话的独立守护：标准输入收到心跳则续期，断开或超时就结束指定进程（核对路径与启动时间后）。
#include <errno.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>

static pid_t pid;
static char expected[PROC_PIDPATHINFO_MAXSIZE];
static unsigned long long seconds, microseconds;

static bool same(void) {
    struct proc_bsdinfo info;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_status == 5) return false;
    if (info.pbi_start_tvsec != seconds || info.pbi_start_tvusec != microseconds) return false;
    return proc_pidpath(pid, path, sizeof(path)) > 0 && strcmp(path, expected) == 0;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static bool stop_target(void) {
    int signals[] = {SIGTERM, SIGKILL};
    for (int i = 0; i < 2; i++) {
        if (!same()) return true;
        if (kill(pid, signals[i]) && errno != ESRCH) return false;
        for (int n = 0; n < 10; n++) { usleep(150000); if (!same()) return true; }
    }
    return false;
}

static void record(const char *file, const char *reason, bool finished) {
    int fd = open(file, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    uuid_t id;
    uuid_string_t text;
    char date[32], line[256];
    time_t t = time(NULL);
    struct tm utc;
    uuid_generate(id);
    uuid_unparse(id, text);
    gmtime_r(&t, &utc);
    strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%SZ", &utc);
    int size = snprintf(line, sizeof(line), "{\"reason\":\"%s\",\"mainExited\":%s,\"date\":\"%s\",\"id\":\"%s\"}\n",
                        reason, finished ? "true" : "false", date, text);
    if (write(fd, line, (size_t)size) != size) {}
    close(fd);
}

int main(int argc, char **argv) {
    if (argc < 6) return 64;
    pid = (pid_t)atoi(argv[1]);
    double timeout = argc > 6 ? atof(argv[6]) : 18;
    if (pid < 2 || timeout < 1 || timeout > 120 || !realpath(argv[2], expected)) return 64;
    seconds = strtoull(argv[3], NULL, 10);
    microseconds = strtoull(argv[4], NULL, 10);
    if (!same()) return 2;
    signal(SIGTERM, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    printf("ready\n");
    fflush(stdout);
    double deadline = now() + timeout;
    const char *reason = "heartbeat_timeout";
    while (same()) {
        double left = deadline - now();
        if (left <= 0) break;
        struct pollfd wait = {.fd = STDIN_FILENO, .events = POLLIN};
        if (poll(&wait, 1, left < 1 ? (int)(left * 1000) + 1 : 1000) > 0) {
            char buffer[4096];
            if (read(STDIN_FILENO, buffer, sizeof(buffer)) <= 0) { reason = "guard_exited"; break; }
            deadline = now() + timeout;
        }
    }
    if (same()) record(argv[5], reason, stop_target());
    return 0;
}
