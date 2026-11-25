// 原子写小文件：临时文件（带 pid 和序号）→ fsync → rename。
//
// 为什么在 C 里而不是 MoonBit：托盘是同步的单线程 D-Bus 循环，MoonBit 的
// @fs 全是 async，那边调不进来；而端口文件、portal.node、access.conf 三处
// 必须用同一份实现，不然「原子写」这件事要维护三遍，改一处漏两处。
#include <moonbit.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

MOONBIT_FFI_EXPORT
int32_t moonbit_util_current_uid(void) { return (int32_t)getuid(); }

// 把 path 里各级父目录逐级建出来（0700）。文件只有自己能读，目录也照这个来。
// 已经存在就跳过：调用方可能已经建过，也可能是系统目录。
static void mkdir_parents(const char *path) {
  char buf[4096];
  size_t n = strlen(path);
  if (n >= sizeof(buf)) return;
  memcpy(buf, path, n + 1);
  for (size_t i = 1; i < n; i++) {
    if (buf[i] != '/') continue;
    buf[i] = 0;
    mkdir(buf, 0700);
    buf[i] = '/';
  }
}

// 进程内序号：同一个进程连着写两次，临时文件名不能一样。
// 用 __atomic 而不是普通自增：C 侧理论上可能被多个线程调进来
// （MoonBit 目前是单线程事件循环，但这个假设不该由这一行代码承担）。
static int32_t g_seq = 0;

MOONBIT_FFI_EXPORT
int32_t moonbit_util_write_atomic(const char *path, uint8_t *data,
                                  int32_t len) {
  if (path == NULL || *path == '\0') return -EINVAL;
  if (len < 0) return -EINVAL;
  if (len > 0 && data == NULL) return -EINVAL;

  mkdir_parents(path);

  /* 临时文件必须带 pid 和序号。
   *
   * 原来托盘那份实现用的是固定的「<path>.tmp」：两个写方（两个托盘实例、
   * 托盘和主服务）会互相截断对方的临时文件，再把半截内容 rename 成正式
   * 文件 —— 比不原子还糟。 */
  int32_t seq = __atomic_add_fetch(&g_seq, 1, __ATOMIC_RELAXED);
  char tmp[4200];
  int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%d.%d", path, (int)getpid(),
                   (int)seq);
  if (n < 0 || (size_t)n >= sizeof(tmp)) return -ENAMETOOLONG;

  // O_NOFOLLOW：临时文件是我们自己建的，不给别人预置软链接把写入引走。
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                0600);
  if (fd < 0) return -errno;

  int32_t rc = 0;
  int32_t off = 0;
  while (off < len) {
    ssize_t w = write(fd, data + off, (size_t)(len - off));
    if (w < 0) {
      if (errno == EINTR) continue;
      rc = -errno;
      break;
    }
    off += (int32_t)w;
  }
  // 先落盘再 rename：否则断电时可能 rename 出一个内容还在页缓存里的空文件。
  // 目录项本身没有 fsync，最坏结果是这次写入丢掉（留下旧内容），
  // 不会出现半截文件 —— 那正是要防的东西。
  if (rc == 0 && fsync(fd) != 0) rc = -errno;
  if (close(fd) != 0 && rc == 0) rc = -errno;
  if (rc == 0 && rename(tmp, path) != 0) rc = -errno;
  if (rc != 0) unlink(tmp);
  return rc;
}
