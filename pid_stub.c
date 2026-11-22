#include <moonbit.h>

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>

/* 当前进程号。文件名里带上它，跨进程就不会撞。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_current_pid(void) {
  return (int32_t)getpid();
}

/* 以指定退出码结束进程。
 *
 * 用在「监听已经不可用、只能靠 systemd 重启」这类地方。之前的写法是从
 * accept 循环里 break 出来，进程以 0 正常收工，而单元写的是 Restart=on-failure，
 * 于是服务静默消失，日志里只有启动那两行。 */
MOONBIT_FFI_EXPORT
void moonbit_screen_kacha_exit(int32_t code) {
  exit((int)code);
}

/* 删掉目录里匹配「前缀 + 后缀」的文件，返回删掉的个数。
 *
 * 两处用途：上次运行留下的原始帧（`<shot 的 basename>.<序号>.bgra`，序号每
 * 进程从 1 重来，跑过几千号的那些再也不会被覆盖），以及被 kill 时没来得及删
 * 的临时输出（`out-*`）。帧每张 8MB，而 `/run` 是内存盘。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_clean_stale_frames(const char *dir, const char *prefix,
                                    const char *suffix) {
  if (dir == NULL || prefix == NULL || suffix == NULL) return -1;
  DIR *d = opendir(dir);
  if (d == NULL) return -1;
  size_t plen = strlen(prefix);
  size_t slen = strlen(suffix);
  int32_t n = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    size_t len = strlen(e->d_name);
    if (len < plen + slen) continue;
    if (strncmp(e->d_name, prefix, plen) != 0) continue;
    if (slen > 0 && strcmp(e->d_name + len - slen, suffix) != 0) continue;
    char full[4096];
    if ((size_t)snprintf(full, sizeof(full), "%s/%s", dir, e->d_name) >=
        sizeof(full)) {
      continue;
    }
    if (remove(full) == 0) n++;
  }
  closedir(d);
  return n;
}

/* 帧目录上的实例锁。
 *
 * 返回 1 = 拿到了锁（本机没有别的实例），0 = 锁在别人手里，-1 = 出错。
 * fd 故意不关：进程活着锁就在，退出时内核自动释放，不会留下需要清理的锁文件。
 *
 * 为什么需要它：端口被占时服务会往上找空口，如果占着端口的是「自己」——
 * 比如手滑起了第二份、或者 unit 和手动启动同时存在——第二份会绑到隔壁端口，
 * 然后两个进程抢同一份帧目录和同一份临时文件。先加锁就杜绝了这条路径，
 * 拿到锁之后端口还被占，那一定是外人占的，换口才是对的。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_instance_lock(const char *dir) {
  char path[4096];
  int n = snprintf(path, sizeof(path), "%s/.instance-lock", dir);
  if (n < 0 || (size_t)n >= sizeof(path)) return -1;
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return 0;
  }
  /* 拿到就揣着，进程结束时内核回收 */
  return 1;
}
