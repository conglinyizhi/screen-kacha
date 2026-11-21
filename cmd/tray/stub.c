// 托盘是同步的 D-Bus 循环，里面跑不了 MoonBit 的异步任务。
// 所以这里补两个最小的 C 入口：起一个 shell 命令，或者同步抓一段输出。
#include <moonbit.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// 起一条 shell 命令，双 fork 后立刻返回，不等待子进程。
MOONBIT_FFI_EXPORT
int moonbit_screenstream_run(const char *cmd) {
  if (!cmd) return -EINVAL;
  pid_t pid = fork();
  if (pid < 0) return -errno;
  if (pid == 0) {
    setsid();
    pid_t inner = fork();
    if (inner != 0) _exit(0);
    // 关键：子进程不能继承托盘的 D-Bus socket。
    // 像 wl-copy 这种常驻命令会一直握着它，导致托盘退出后
    // 连接不断开，桌面上留下幽灵图标。
    long max_fd = sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 4096) max_fd = 4096;
    for (int fd = 3; fd < max_fd; fd++) close(fd);
    execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
    _exit(127);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return 0;
}

// 同步执行命令并把 stdout 读进 buf，返回字节数，失败返回 -errno。
MOONBIT_FFI_EXPORT
int moonbit_screenstream_capture(const char *cmd, uint8_t *buf, int32_t len) {
  if (!cmd || !buf || len <= 0) return -EINVAL;
  FILE *fp = popen(cmd, "r");
  if (!fp) return -errno;
  size_t n = fread(buf, 1, (size_t)len - 1, fp);
  pclose(fp);
  buf[n] = 0;
  return (int)n;
}

// 直接退出托盘进程；D-Bus 连接随进程结束由内核关闭。
MOONBIT_FFI_EXPORT
void moonbit_screenstream_exit(int32_t code) {
  _exit(code);
}

/* 写一个小文本文件（配置文件用）。成功返回 0。 */
int moonbit_screenstream_write_file(const char *path, const char *data) {
  // 先把父目录逐级建好：调用方可能在目录还不存在时就写
  char buf[1024];
  size_t n = strlen(path);
  if (n >= sizeof(buf)) return -1;
  memcpy(buf, path, n + 1);
  for (size_t i = 1; i < n; i++) {
    if (buf[i] == '/') {
      buf[i] = 0;
      mkdir(buf, 0700);
      buf[i] = '/';
    }
  }
  FILE *f = fopen(path, "w");
  if (f == NULL) return -1;
  fputs(data, f);
  fclose(f);
  return 0;
}
