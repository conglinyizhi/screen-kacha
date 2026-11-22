#include <moonbit.h>

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

/* 当前进程号。文件名里带上它，跨进程就不会撞。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_current_pid(void) {
  return (int32_t)getpid();
}

/* 删文件。失败返回 -1；调用方不关心具体原因。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_tmp_remove(const char *path) {
  if (path == NULL || *path == 0) return -1;
  return remove(path) == 0 ? 0 : -1;
}

/* 以指定退出码结束进程。
 *
 * 用在「监听已经不可用、只能靠 systemd 重启」这类地方。之前的写法是从
 * accept 循环里 break 出来，进程以 0 正常收工，而单元写的是 Restart=on-failure，
 * 于是服务静默消失，日志里只有启动那两行。 */
MOONBIT_FFI_EXPORT
void moonbit_screenstream_exit(int32_t code) {
  exit((int)code);
}

/* 删掉帧目录里上次运行留下的原始帧。
 *
 * 文件名是 `<shot 的 basename>.<序号>.bgra`，序号每个进程都从 1 重新开始，
 * 所以上个进程跑到几千号的那些文件再也不会被覆盖，一直躺在 tmpfs 里。
 * 每帧 8MB，重启几次就是几十兆，`/run` 是内存盘。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_clean_stale_frames(const char *dir, const char *prefix) {
  if (dir == NULL || prefix == NULL) return -1;
  DIR *d = opendir(dir);
  if (d == NULL) return -1;
  size_t plen = strlen(prefix);
  size_t slen = strlen(".bgra");
  int32_t n = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    size_t len = strlen(e->d_name);
    if (len <= plen + slen) continue;
    if (strncmp(e->d_name, prefix, plen) != 0) continue;
    if (strcmp(e->d_name + len - slen, ".bgra") != 0) continue;
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
