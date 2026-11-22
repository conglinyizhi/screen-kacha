#include <moonbit.h>

#include <stdio.h>
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
