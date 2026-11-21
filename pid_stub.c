#include <moonbit.h>

#include <stdio.h>
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
