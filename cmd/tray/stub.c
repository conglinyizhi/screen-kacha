// 托盘是同步的 D-Bus 循环，里面跑不了 MoonBit 的异步任务。
// 所以这里补两个最小的 C 入口：起一个 shell 命令，或者同步抓一段输出。
#include <moonbit.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
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
