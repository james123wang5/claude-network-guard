#ifndef GUARD_CONFINE_H
#define GUARD_CONFINE_H

// 对当前进程（及其子进程）套上进程级限制。成功返回 0。
int guard_confine(const char *frameworks, int locked);

#endif
