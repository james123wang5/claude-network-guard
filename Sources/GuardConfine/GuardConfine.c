#include "GuardConfine.h"
#include <sandbox.h>
#include <stdio.h>

// 在内核里只对本应用（及其子进程）生效的限制：
// 禁止本机以外的 UDP 和 TCP 53，并禁止把联网交给系统代办（后台下载、WebKit 网络进程）。
// 应用自带沙箱的 Helper 豁免（两层沙箱不能叠加），它们的 UDP 已由启动参数关闭。
int guard_confine(const char *frameworks, int locked) {
    char quoted[2048];
    size_t used = 0;
    for (const char *c = frameworks; *c; c++) {
        if (used + 3 >= sizeof(quoted) || (unsigned char)*c < 32) return -1;
        if (*c == '"' || *c == '\\') quoted[used++] = '\\';
        quoted[used++] = *c;
    }
    quoted[used] = 0;
    char profile[8192];
    int size = snprintf(profile, sizeof(profile),
        "(version 1)(allow default)"
        "(deny network-outbound (remote udp \"*:*\"))"
        "(allow network-outbound (remote udp \"localhost:*\"))"
        // TCP 53 在系统里可能被 DNS 代理扩展接管，接管发生在防火墙之前，只能在这里拒绝。
        "(deny network-outbound (remote tcp \"*:53\"))"
        "(allow network-outbound (remote tcp \"localhost:53\"))"
        "(deny mach-lookup (xpc-service-name \"com.apple.WebKit.Networking\")"
        " (global-name \"com.apple.nsurlsessiond\") (global-name \"com.apple.nsurlsessiond.NSURLSessionProxyService\"))"
        "%s"
        "(allow process-exec (with no-sandbox) (literal \"/bin/ps\") (literal \"/usr/bin/top\")"
        " (literal \"/usr/bin/sandbox-exec\")%s%s%s%s)",
        // 锁死模式：只能连本机（转发器），不能用系统 DNS。不依赖防火墙，防火墙被清空也漏不出去。
        locked ? "(deny network-outbound (remote tcp \"*:*\"))(allow network-outbound (remote tcp \"localhost:*\"))"
                 "(deny network-outbound (literal \"/private/var/run/mDNSResponder\"))"
                 "(deny mach-lookup (global-name \"com.apple.dnssd.service\"))" : "",
        // 系统不让套了限制的进程发 AppleScript 事件。豁免后它仍在隔离组，TCP 照样由防火墙管，UDP 靠审计。
        locked ? "" : " (literal \"/usr/bin/osascript\")",
        *quoted ? " (subpath \"" : "", quoted, *quoted ? "\")" : "");
    if (size < 0 || (size_t)size >= sizeof(profile)) return -1;
    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = sandbox_init(profile, 0, &error);
#pragma clang diagnostic pop
    if (result) fprintf(stderr, "限制规则未生效 %s\n", error ? error : "");
    return result;
}
