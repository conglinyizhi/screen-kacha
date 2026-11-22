#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* 逐级建目录，然后原子地写一个小文本文件。
 * 先写 .tmp 再 rename：主服务随时可能在读，不能让它读到写了一半的内容。
 * 返回 0 成功，-1 失败。 */
int moonbit_cursor_write(const char *path, const char *data) {
  char tmp[1024];
  char dir[1024];
  size_t n = strlen(path);
  if (n >= sizeof(tmp) - 8) return -1;

  /* 建父目录 */
  memcpy(dir, path, n + 1);
  for (size_t i = 1; i < n; i++) {
    if (dir[i] == '/') {
      dir[i] = 0;
      mkdir(dir, 0755);
      dir[i] = '/';
    }
  }

  snprintf(tmp, sizeof(tmp), "%s.tmp", path);
  FILE *f = fopen(tmp, "w");
  if (f == NULL) return -1;
  fputs(data, f);
  fclose(f);

  if (rename(tmp, path) != 0) {
    unlink(tmp);
    return -1;
  }
  return 0;
}

/* 删掉坐标文件。KWin 脚本没了以后留着会画出一个停住的光标。 */
int moonbit_cursor_remove(const char *path) {
  return unlink(path);
}

/* 以指定退出码结束。写坐标失败时用：让托盘那边的校验看到 helper 没了，
 * 而不是留一个永远不写坐标的进程假装在跟踪。 */
void moonbit_cursor_exit(int32_t code) {
  exit((int)code);
}
