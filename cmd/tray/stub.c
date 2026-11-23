// 托盘是同步的 D-Bus 循环，里面跑不了 MoonBit 的异步任务。
// 所以这里补两个最小的 C 入口：起一个 shell 命令，或者同步抓一段输出。
#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// 起一条 shell 命令，双 fork 后立刻返回，不等待子进程。
MOONBIT_FFI_EXPORT
int moonbit_screen_kacha_run(const char *cmd) {
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
int moonbit_screen_kacha_capture(const char *cmd, uint8_t *buf, int32_t len) {
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
void moonbit_screen_kacha_exit(int32_t code) {
  _exit(code);
}

// 本进程 pid。挂 KWin 脚本时用它拼脚本名：两个托盘实例各用各的名字，
// 否则后加载的顶掉前一个，一方卸载会连带摘掉另一方的脚本。
MOONBIT_FFI_EXPORT
int32_t moonbit_screen_kacha_pid(void) {
  return (int32_t)getpid();
}

/* 同步跑一条命令并返回退出码（-1 表示根本起不来）。 */
int moonbit_screen_kacha_run_status(const char *cmd) {
  int rc = system(cmd);
  if (rc == -1) return -1;
  if (WIFEXITED(rc)) return WEXITSTATUS(rc);
  return -2;
}

// ---------------------------------------------------------------------------
// 收到 SIGTERM 时别当场死掉，留一口气把光标跟踪收干净
//
// systemd 重启托盘服务时发的是 SIGTERM。原来进程直接没了，KWin 那边
// 脚本还挂着、helper 还活着占着 D-Bus 名字，每重启一次就多留一份。
// 信号处理函数里能安全做的事很少，所以这里只置一个标志，
// 让 MoonBit 侧每一拍去检查，检查到了再走正常的收摊流程。
// ---------------------------------------------------------------------------
static volatile sig_atomic_t g_stop = 0;

static void on_stop_signal(int sig) {
  (void)sig;
  g_stop = 1;
}

MOONBIT_FFI_EXPORT
void moonbit_screen_kacha_watch_stop(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_stop_signal;
  sigemptyset(&sa.sa_mask);
  // 不设 SA_RESTART：让阻塞中的系统调用被打断，循环能早点回到 MoonBit 侧
  sa.sa_flags = 0;
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_screen_kacha_should_stop(void) { return g_stop ? 1 : 0; }
