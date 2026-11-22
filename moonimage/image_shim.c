/*
 * moonimage 的 C 部分：把 BGRA 原始帧缩放并编码成 JPEG / WebP。
 *
 * 只依赖 libjpeg（BSD/IJG）和 libwebp（BSD-3），两者都不传染，
 * 和本项目的 Apache-2.0 兼容。
 *
 * 缩放是自己写的双线性：libswscale 属于 ffmpeg，在部分发行版里是 GPL，
 * 不能碰。这点像素算术没必要为它引入许可证风险。
 */
#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <jpeglib.h>
#include <png.h>
#include <setjmp.h>
#include <webp/encode.h>

/* 建一个只有本用户能读的输出文件。
 *
 * 直接用 fopen(path,"wb") 会用 0666 & ~umask，常态就是 0644：同一台机器上
 * 别的用户能读到刚落盘的截图。而且 fopen 会跟随符号链接，本地用户可以在
 * 已知路径上预置一个链接，把写入引到他想要的任意文件。
 *
 * 这里做三件事：把父目录建成 0700、用 O_NOFOLLOW 拒绝符号链接、文件 0600。
 * 目录建好之后，别的用户既进不来也没法在里面放东西，路径可预测就不再是问题。
 */
static FILE *create_private(const char *path) {
  if (path == NULL || *path == '\0') return NULL;
  char dir[4096];
  size_t n = strlen(path);
  if (n >= sizeof(dir)) return NULL;
  memcpy(dir, path, n + 1);
  char *slash = strrchr(dir, '/');
  if (slash != NULL) {
    *slash = '\0';
    if (dir[0] != '\0') {
      /* 已存在时 mkdir 返回 EEXIST，不动内容 */
      if (mkdir(dir, 0700) == 0) {
        chmod(dir, 0700);
      }
    }
  }
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (fd < 0) return NULL;
  /* open 的 mode 只对新建的文件生效，路径上已经有旧文件（老版本按 0644 建的）
   * 就保持原权限。主动收一次，免得升级之后旧文件继续对别人可读。
   * 只对普通文件动手：写 /dev/full 这类设备时不该去改别人的权限。 */
  struct stat st;
  if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode)) {
    fchmod(fd, 0600);
  }
  FILE *f = fdopen(fd, "wb");
  if (f == NULL) {
    close(fd);
    return NULL;
  }
  return f;
}

/* 读整个文件到堆上。调用方负责 free。失败返回 NULL。 */
static uint8_t *read_file(const char *path, size_t expect) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) return NULL;
  uint8_t *buf = (uint8_t *)malloc(expect);
  if (buf == NULL) {
    fclose(f);
    return NULL;
  }
  size_t got = fread(buf, 1, expect, f);
  fclose(f);
  if (got != expect) {
    free(buf);
    return NULL;
  }
  return buf;
}

/*
 * 一维面积平均的权重表。
 *
 * 把「目标像素 i 由哪些源像素按什么比例合成」预先算好，
 * 后面每个像素只做乘加，不必反复算比例和边界。
 */
typedef struct {
  int *idx;     /* 源下标，长度 = m * max_taps */
  double *w;    /* 权重，同长度 */
  int *count;   /* 每个目标像素用几个源像素 */
  int max_taps;
} box_tab;

static void box_tab_free(box_tab *t) {
  if (t == NULL) return;
  free(t->idx);
  free(t->w);
  free(t->count);
  free(t);
}

/* n 个源像素 → m 个目标像素的权重表。失败返回 NULL。 */
static box_tab *box_tab_build(int n, int m) {
  if (n <= 0 || m <= 0) return NULL;
  box_tab *t = (box_tab *)calloc(1, sizeof(box_tab));
  if (t == NULL) return NULL;
  /* 缩小时一个目标像素最多覆盖 ceil(n/m)+1 个源像素 */
  int taps = (n + m - 1) / m + 1;
  t->max_taps = taps;
  t->idx = (int *)calloc((size_t)m * taps, sizeof(int));
  t->w = (double *)calloc((size_t)m * taps, sizeof(double));
  t->count = (int *)calloc((size_t)m, sizeof(int));
  if (t->idx == NULL || t->w == NULL || t->count == NULL) {
    box_tab_free(t);
    return NULL;
  }
  double ratio = (double)n / (double)m;
  for (int i = 0; i < m; i++) {
    double start = i * ratio;
    double end = (i + 1) * ratio;
    int s0 = (int)start;
    int s1 = (int)(end + 0.9999);
    if (s1 > n) s1 = n;
    if (s0 >= n) s0 = n - 1;
    int k = 0;
    for (int sx = s0; sx < s1 && k < taps; sx++) {
      double a = start > sx ? start : sx;
      double b = end < sx + 1 ? end : sx + 1;
      double w = b - a;
      if (w <= 0) continue;
      t->idx[i * taps + k] = sx;
      t->w[i * taps + k] = w;
      k++;
    }
    t->count[i] = k;
  }
  return t;
}

/*
 * BGRA → RGB，顺带缩放。
 *
 * 缩小用分离式面积平均（先横后竖），放大用双线性。
 * 输出前把 BGRA 换成 RGB，JPEG 要的是 RGB 顺序。
 *
 * 竖 pass 按行累加而不是按列：一列一列读会让 CPU 缓存完全失效，
 * 实测慢三倍。这里先把一整个目标行累加到 int32 缓冲，再统一除权重。
 */
static void bgra_to_rgb_scaled(const uint8_t *src, int sw, int sh, uint8_t *dst,
                               int dw, int dh) {
  const uint8_t *base = src;
  uint8_t *owned = NULL;

  if (dw != sw || dh != sh) {
    /* 中间结果：先竖向缩到 dh 行，宽度仍是 sw */
    uint8_t *mid = NULL;
    if (dh != sh) {
      mid = (uint8_t *)malloc((size_t)sw * dh * 4);
      if (mid == NULL) return;
      box_tab *vt = box_tab_build(sh, dh);
      if (vt == NULL) { free(mid); return; }
      int32_t *acc = (int32_t *)malloc((size_t)sw * 4 * sizeof(int32_t));
      if (acc == NULL) { free(mid); box_tab_free(vt); return; }
      for (int y = 0; y < dh; y++) {
        size_t n4 = (size_t)sw * 4;
        memset(acc, 0, n4 * sizeof(int32_t));
        double wsum = 0;
        for (int k = 0; k < vt->count[y]; k++) {
          int sy = vt->idx[y * vt->max_taps + k];
          double w = vt->w[y * vt->max_taps + k];
          /* 权重放大成整数参与累加，避免浮点累加的开销 */
          int32_t iw = (int32_t)(w * 1024.0 + 0.5);
          const uint8_t *row = src + (size_t)sy * sw * 4;
          for (size_t i = 0; i < n4; i++) acc[i] += row[i] * iw;
          wsum += w;
        }
        /* 除法很贵（每像素一次会吃掉几十毫秒），改成乘倒数 */
        double inv = wsum > 0 ? 1.0 / (wsum * 1024.0) : 0.0;
        uint8_t *orow = mid + (size_t)y * sw * 4;
        for (size_t i = 0; i < n4; i++) {
          int v = (int)(acc[i] * inv + 0.5);
          orow[i] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
      }
      free(acc);
      box_tab_free(vt);
    }

    const uint8_t *hsrc = mid != NULL ? mid : src;
    int hh = mid != NULL ? dh : sh;

    if (dw != sw) {
      uint8_t *out = (uint8_t *)malloc((size_t)dw * hh * 4);
      if (out == NULL) { free(mid); return; }
      box_tab *ht = box_tab_build(sw, dw);
      if (ht == NULL) { free(mid); free(out); return; }
      /* 权重一次性转成定点整数，内层循环就不用碰浮点了 */
      int32_t *iw_tab = (int32_t *)malloc((size_t)dw * ht->max_taps * sizeof(int32_t));
      int32_t *iw_sum = (int32_t *)malloc((size_t)dw * sizeof(int32_t));
      double *iw_inv = (double *)malloc((size_t)dw * sizeof(double));
      if (iw_tab == NULL || iw_sum == NULL || iw_inv == NULL) {
        free(iw_tab); free(iw_sum); free(iw_inv);
        box_tab_free(ht); free(mid); free(out); return;
      }
      for (int x = 0; x < dw; x++) {
        int32_t sum = 0;
        for (int k = 0; k < ht->count[x]; k++) {
          int32_t iw = (int32_t)(ht->w[x * ht->max_taps + k] * 1024.0 + 0.5);
          iw_tab[x * ht->max_taps + k] = iw;
          sum += iw;
        }
        iw_sum[x] = sum > 0 ? sum : 1;
        iw_inv[x] = sum > 0 ? 1.0 / (double)sum : 0.0;
      }
      for (int y = 0; y < hh; y++) {
        const uint8_t *srow = hsrc + (size_t)y * sw * 4;
        uint8_t *orow = out + (size_t)y * dw * 4;
        for (int x = 0; x < dw; x++) {
          int32_t r = 0, g = 0, b = 0, a = 0;
          int nk = ht->count[x];
          const int *ix = ht->idx + x * ht->max_taps;
          const int32_t *iw = iw_tab + x * ht->max_taps;
          for (int k = 0; k < nk; k++) {
            const uint8_t *p = srow + (size_t)ix[k] * 4;
            int32_t w = iw[k];
            b += p[0] * w;
            g += p[1] * w;
            r += p[2] * w;
            a += p[3] * w;
          }
          double inv = iw_inv[x];
          uint8_t *o = orow + (size_t)x * 4;
          o[0] = (uint8_t)(b * inv + 0.5);
          o[1] = (uint8_t)(g * inv + 0.5);
          o[2] = (uint8_t)(r * inv + 0.5);
          o[3] = (uint8_t)(a * inv + 0.5);
        }
      }
      free(iw_tab);
      free(iw_sum);
      free(iw_inv);
      box_tab_free(ht);
      free(mid);
      owned = out;
      base = out;
    } else {
      owned = mid;
      base = hsrc;
    }
  }

  /* BGRA → RGB */
  int n = dw * dh;
  for (int i = 0; i < n; i++) {
    dst[i * 3 + 0] = base[i * 4 + 2];
    dst[i * 3 + 1] = base[i * 4 + 1];
    dst[i * 3 + 2] = base[i * 4 + 0];
  }
  free(owned);
}

/*
 * BGRA 内存缓冲 → JPEG 或 WebP 文件。缩放也在里面做。
 *
 * 原来的两个导出函数各自写了一遍「算高度、缩放、编码」，加光标合成时
 * 会有第三份。抽出来一份，谁要编码都走这里。
 *
 *   bgra    输入像素，宽*高*4
 *   dst_w   目标宽度；<=0 或 >= w 表示不缩放
 *   webp    0 编 JPEG，1 编 WebP
 *
 * 返回 0 成功，非 0 失败。
 */
/* libjpeg 默认的 error_exit 会直接 exit(EXIT_FAILURE)。
 *
 * 解码方向：服务读到一张坏图就被拖死。
 * 编码方向：写盘失败（磁盘满、配额打满）同样会把整个服务带走，而不是让
 * 这一次请求返回 500。
 * 两边都换成 longjmp 跳回来，按失败返回。 */
typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jb;
} jpeg_jmp;

static void jpeg_fail(j_common_ptr cinfo) {
  jpeg_jmp *e = (jpeg_jmp *)cinfo->err;
  longjmp(e->jb, 1);
}

static void jpeg_quiet(j_common_ptr cinfo) { (void)cinfo; }

static int encode_bgra(const uint8_t *bgra, int w, int h, int dst_w,
                       int quality, int webp, const char *out_path) {
  if (w <= 0 || h <= 0 || quality < 1 || quality > 100) return 1;

  int dw = (dst_w <= 0 || dst_w > w) ? w : dst_w;
  /* 高度按比例算，四舍五入而不是截断：
   * 截断会让 40x30 → 13 宽算出 9 高（应为 9.75），画面轻微压扁。
   * 至少给 1 行，否则 37x23 → 1 宽会算出 0 高，整个渲染直接失败。 */
  int dh = (int)(((int64_t)h * dw + w / 2) / w);
  if (dh < 1) dh = 1;

  uint8_t *rgb = (uint8_t *)malloc((size_t)dw * dh * 3);
  if (rgb == NULL) return 3;
  bgra_to_rgb_scaled(bgra, w, h, rgb, dw, dh);

  if (webp) {
    uint8_t *out = NULL;
    size_t out_len = WebPEncodeRGB(rgb, dw, dh, dw * 3, (float)quality, &out);
    free(rgb);
    if (out_len == 0 || out == NULL) return 5;
    FILE *fp = create_private(out_path);
    if (fp == NULL) {
      WebPFree(out);
      return 4;
    }
    size_t written = fwrite(out, 1, out_len, fp);
    fclose(fp);
    WebPFree(out);
    return written == out_len ? 0 : 6;
  }

  struct jpeg_compress_struct cinfo;
  jpeg_jmp jerr;
  cinfo.err = jpeg_std_error(&jerr.pub);
  /* 编码这一侧同样不能用默认的 error_exit。
   *
   * 写盘失败（磁盘满、/dev/full、配额打满）时 libjpeg 会调 error_exit，
   * 默认实现直接 exit(EXIT_FAILURE)：一次写失败就把整个服务带走，
   * 而不是让这次请求返回 500。 */
  jerr.pub.error_exit = jpeg_fail;
  jerr.pub.output_message = jpeg_quiet;
  FILE *fp = NULL;
  int failed = 0;
  if (setjmp(jerr.jb)) {
    failed = 1;
  } else {
    jpeg_create_compress(&cinfo);
    fp = create_private(out_path);
    if (fp == NULL) {
      jpeg_destroy_compress(&cinfo);
      free(rgb);
      return 4;
    }
    jpeg_stdio_dest(&cinfo, fp);
    cinfo.image_width = (JDIMENSION)dw;
    cinfo.image_height = (JDIMENSION)dh;
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);
    /* 打开 Huffman 优化：体积能小 5% 左右，代价是编码稍慢 */
    cinfo.optimize_coding = TRUE;
    jpeg_start_compress(&cinfo, TRUE);

    while (cinfo.next_scanline < cinfo.image_height) {
      JSAMPROW row = rgb + (size_t)cinfo.next_scanline * dw * 3;
      jpeg_write_scanlines(&cinfo, &row, 1);
    }

    jpeg_finish_compress(&cinfo);
  }
  if (fp != NULL) fclose(fp);
  jpeg_destroy_compress(&cinfo);
  free(rgb);
  return failed ? 7 : 0;
}

/*
 * BGRA 文件 → JPEG 文件。
 *
 *   bgra_path  输入：原始帧，宽*高*4 字节
 *   w, h       输入尺寸
 *   dst_w      目标宽度；<=0 或 >= w 表示不缩放
 *   quality    JPEG 质量 1-100
 *   out_path   输出文件
 *
 * 返回 0 成功，非 0 失败（调用方只看非零）。
 */
int32_t moonbit_image_bgra_to_jpeg(const char *bgra_path, int32_t w, int32_t h,
                                   int32_t dst_w, int32_t quality,
                                   const char *out_path) {
  if (w <= 0 || h <= 0) return 1;
  size_t need = (size_t)w * h * 4;
  uint8_t *bgra = read_file(bgra_path, need);
  if (bgra == NULL) return 2;
  int rc = encode_bgra(bgra, w, h, dst_w, quality, 0, out_path);
  free(bgra);
  return rc;
}

/*
 * BGRA 文件 → WebP 文件。参数含义同上。
 *
 * WebP 有损压缩比 JPEG 慢一些，但体积能小两三成。
 */
int32_t moonbit_image_bgra_to_webp(const char *bgra_path, int32_t w, int32_t h,
                                   int32_t dst_w, int32_t quality,
                                   const char *out_path) {
  if (w <= 0 || h <= 0) return 1;
  size_t need = (size_t)w * h * 4;
  uint8_t *bgra = read_file(bgra_path, need);
  if (bgra == NULL) return 2;
  int rc = encode_bgra(bgra, w, h, dst_w, quality, 1, out_path);
  free(bgra);
  return rc;
}

/* ==================================================================
 * 光标合成，以及「文件 → 缩放 → 编码」这一条
 *
 * 这两块原来都走 ImageMagick 命令行。贴图用 over，负片用「裁剪 + 反色 +
 * CopyOpacity 再用 over 贴回去」，加起来不到一百行，自己做掉就不依赖
 * 外部程序了。像素语义严格照 magick 那版对齐。
 * ================================================================== */

/* JPEG 文件 → BGRA。返回 malloc 的缓冲；失败返回 NULL。 */
static uint8_t *decode_jpeg_bgra(const char *path, int *out_w, int *out_h) {
  FILE *fp = fopen(path, "rb");
  if (fp == NULL) return NULL;

  struct jpeg_decompress_struct cinfo;
  jpeg_jmp jerr;
  uint8_t *bgra = NULL;
  uint8_t *row = NULL;

  cinfo.err = jpeg_std_error(&jerr.pub);
  jerr.pub.error_exit = jpeg_fail;
  jerr.pub.output_message = jpeg_quiet;

  if (setjmp(jerr.jb)) {
    jpeg_destroy_decompress(&cinfo);
    free(bgra);
    free(row);
    fclose(fp);
    return NULL;
  }

  jpeg_create_decompress(&cinfo);
  jpeg_stdio_src(&cinfo, fp);
  jpeg_read_header(&cinfo, TRUE);
  cinfo.out_color_space = JCS_RGB;
  jpeg_start_decompress(&cinfo);

  int w = (int)cinfo.output_width;
  int h = (int)cinfo.output_height;
  if (w <= 0 || h <= 0) {
    jpeg_destroy_decompress(&cinfo);
    fclose(fp);
    return NULL;
  }

  bgra = (uint8_t *)malloc((size_t)w * h * 4);
  row = (uint8_t *)malloc((size_t)w * 3);
  if (bgra == NULL || row == NULL) {
    jpeg_destroy_decompress(&cinfo);
    free(bgra);
    free(row);
    fclose(fp);
    return NULL;
  }

  while (cinfo.output_scanline < cinfo.image_height) {
    int y = (int)cinfo.output_scanline;
    JSAMPROW r = row;
    jpeg_read_scanlines(&cinfo, &r, 1);
    uint8_t *d = bgra + (size_t)y * w * 4;
    for (int x = 0; x < w; x++) {
      d[x * 4 + 0] = row[x * 3 + 2]; /* B */
      d[x * 4 + 1] = row[x * 3 + 1]; /* G */
      d[x * 4 + 2] = row[x * 3 + 0]; /* R */
      d[x * 4 + 3] = 255;
    }
  }

  jpeg_finish_decompress(&cinfo);
  jpeg_destroy_decompress(&cinfo);
  fclose(fp);
  free(row);
  *out_w = w;
  *out_h = h;
  return bgra;
}

/* PNG 文件 → RGBA，灰度图和灰度+alpha 都统一展开成 RGBA。
 *
 * 这里用完整接口而不是 `png_image_*` 简化接口：简化接口读出来会做 gamma
 * 转换，实测 128 变成 186，整张图亮一档，而且 PNG_IMAGE_FLAG_COLORSPACE_NOT_sRGB
 * 也关不掉。完整接口只要不调用 png_set_gamma，值就和文件里写的一致。
 */
static uint8_t *decode_png_rgba(const char *path, int *out_w, int *out_h) {
  FILE *fp = fopen(path, "rb");
  if (fp == NULL) return NULL;

  png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL,
                                           NULL);
  if (png == NULL) {
    fclose(fp);
    return NULL;
  }
  png_infop info = png_create_info_struct(png);
  if (info == NULL) {
    png_destroy_read_struct(&png, NULL, NULL);
    fclose(fp);
    return NULL;
  }

  uint8_t *buf = NULL;
  png_bytep *rows = NULL;
  if (setjmp(png_jmpbuf(png))) {
    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);
    free(buf);
    free(rows);
    return NULL;
  }

  png_init_io(png, fp);
  png_read_info(png, info);

  png_uint_32 w = 0;
  png_uint_32 h = 0;
  int depth = 0;
  int ctype = 0;
  png_get_IHDR(png, info, &w, &h, &depth, &ctype, NULL, NULL, NULL);

  /* 统一成 8 位 RGBA：调色板展开、低位深补齐、灰度转 RGB、没有 alpha 就补一个 */
  png_set_expand(png);
  png_set_strip_16(png);
  png_set_gray_to_rgb(png);
  png_set_add_alpha(png, 0xFF, PNG_FILLER_AFTER);
  png_read_update_info(png, info);

  size_t rowbytes = png_get_rowbytes(png, info);
  buf = (uint8_t *)malloc(rowbytes * h);
  rows = (png_bytep *)malloc(sizeof(png_bytep) * h);
  if (buf == NULL || rows == NULL) {
    png_destroy_read_struct(&png, &info, NULL);
    fclose(fp);
    free(buf);
    free(rows);
    return NULL;
  }
  for (png_uint_32 y = 0; y < h; y++) {
    rows[y] = buf + (size_t)y * rowbytes;
  }
  png_read_image(png, rows);
  png_read_end(png, NULL);
  png_destroy_read_struct(&png, &info, NULL);
  fclose(fp);
  free(rows);

  *out_w = (int)w;
  *out_h = (int)h;
  return buf;
}

/* 帧文件 → BGRA。正常路径这里永远是 JPEG（自己编的），但假帧源
 * 直接把测试图的原始字节塞给 shot，可能是 PNG。看文件头认一下，
 * 免得测试和演示时悄悄画不出光标。 */
static uint8_t *decode_frame_bgra(const char *path, int *w, int *h) {
  FILE *fp = fopen(path, "rb");
  if (fp == NULL) return NULL;
  unsigned char head[8];
  size_t n = fread(head, 1, 8, fp);
  fclose(fp);
  int is_png = n >= 8 && head[0] == 0x89 && head[1] == 'P' && head[2] == 'N' &&
               head[3] == 'G';
  if (!is_png) return decode_jpeg_bgra(path, w, h);

  int pw = 0;
  int ph = 0;
  uint8_t *rgba = decode_png_rgba(path, &pw, &ph);
  if (rgba == NULL) return NULL;
  uint8_t *bgra = (uint8_t *)malloc((size_t)pw * ph * 4);
  if (bgra == NULL) {
    free(rgba);
    return NULL;
  }
  int n_px = pw * ph;
  for (int i = 0; i < n_px; i++) {
    bgra[i * 4 + 0] = rgba[i * 4 + 2];
    bgra[i * 4 + 1] = rgba[i * 4 + 1];
    bgra[i * 4 + 2] = rgba[i * 4 + 0];
    bgra[i * 4 + 3] = 255;
  }
  free(rgba);
  *w = pw;
  *h = ph;
  return bgra;
}

/* 半透明箭头贴在帧上。等价于 magick 的 -compose over -composite。
 * 帧本身不透明，alpha 通道不用管。 */
static void composite_soft(uint8_t *dst, int dw, int dh,
                           const uint8_t *arrow, int aw, int ah, int x, int y) {
  for (int j = 0; j < ah; j++) {
    int dy = y + j;
    if (dy < 0 || dy >= dh) continue;
    const uint8_t *srow = arrow + (size_t)j * aw * 4;
    uint8_t *drow = dst + (size_t)dy * dw * 4;
    for (int i = 0; i < aw; i++) {
      int dx = x + i;
      if (dx < 0 || dx >= dw) continue;
      const uint8_t *s = srow + (size_t)i * 4; /* RGBA */
      int a = s[3];
      if (a == 0) continue;
      uint8_t *d = drow + (size_t)dx * 4; /* BGRA */
      int ia = 255 - a;
      d[0] = (uint8_t)((s[2] * a + d[0] * ia + 127) / 255);
      d[1] = (uint8_t)((s[1] * a + d[1] * ia + 127) / 255);
      d[2] = (uint8_t)((s[0] * a + d[2] * ia + 127) / 255);
    }
  }
}

/* 负片：把蒙版当 alpha，混合「反色后的原像素」和原像素。
 *
 * magick 那版是「裁剪 + -negate + CopyOpacity + over」，等价于
 * dst = 反色后 * a + 原像素 * (1 - a)，a 取蒙版的灰度值。
 * 蒙版是灰度 PNG，展开成 RGBA 后灰度在 r 通道。 */
static void composite_neg(uint8_t *dst, int dw, int dh,
                          const uint8_t *mask, int mw, int mh, int x, int y) {
  for (int j = 0; j < mh; j++) {
    int dy = y + j;
    if (dy < 0 || dy >= dh) continue;
    const uint8_t *srow = mask + (size_t)j * mw * 4;
    uint8_t *drow = dst + (size_t)dy * dw * 4;
    for (int i = 0; i < mw; i++) {
      int dx = x + i;
      if (dx < 0 || dx >= dw) continue;
      int a = srow[(size_t)i * 4 + 0];
      if (a == 0) continue;
      uint8_t *d = drow + (size_t)dx * 4;
      int ia = 255 - a;
      d[0] = (uint8_t)(((255 - d[0]) * a + d[0] * ia + 127) / 255);
      d[1] = (uint8_t)(((255 - d[1]) * a + d[1] * ia + 127) / 255);
      d[2] = (uint8_t)(((255 - d[2]) * a + d[2] * ia + 127) / 255);
    }
  }
}

/*
 * 帧 → 画光标 → 缩放 → 编码。取代原来那条 magick 命令。
 *
 *   src_path      源：BGRA 原始帧，或已经抓好的 JPEG
 *   src_is_bgra   1 表示 src 是 BGRA 文件，用 src_w/src_h；0 表示 JPEG
 *   overlay_png   半透明模式传箭头素材，负片传空串
 *   mask_png      负片模式传蒙版，半透明传空串
 *
 * 注意「没传」是用空串表示而不是 NULL：MoonBit 那边不好表达空指针，
 * 一律转成 C 字符串，空串转出来就是一个指向 \0 的合法指针。
 *   x, y          光标位置，可以超出画面，越界的部分会被裁掉
 *   dst_w         目标宽度，<=0 表示不缩放
 *   webp          0 编 JPEG，1 编 WebP
 *
 * 返回 0 成功，非 0 失败。
 */
int32_t moonbit_image_cursor(const char *src_path, int32_t src_is_bgra,
                             int32_t src_w, int32_t src_h,
                             const char *overlay_png, const char *mask_png,
                             int32_t x, int32_t y, int32_t dst_w,
                             int32_t quality, int32_t webp,
                             const char *out_path) {
  int w = 0;
  int h = 0;
  uint8_t *frame = NULL;

  if (src_is_bgra) {
    w = (int)src_w;
    h = (int)src_h;
    if (w <= 0 || h <= 0) return 1;
    frame = read_file(src_path, (size_t)w * h * 4);
  } else {
    frame = decode_frame_bgra(src_path, &w, &h);
  }
  if (frame == NULL) return 2;

  if (overlay_png != NULL && overlay_png[0] != '\0') {
    int aw = 0;
    int ah = 0;
    uint8_t *ov = decode_png_rgba(overlay_png, &aw, &ah);
    if (ov == NULL) {
      free(frame);
      return 7;
    }
    composite_soft(frame, w, h, ov, aw, ah, (int)x, (int)y);
    free(ov);
  }

  if (mask_png != NULL && mask_png[0] != '\0') {
    int mw = 0;
    int mh = 0;
    uint8_t *mk = decode_png_rgba(mask_png, &mw, &mh);
    if (mk == NULL) {
      free(frame);
      return 7;
    }
    composite_neg(frame, w, h, mk, mw, mh, (int)x, (int)y);
    free(mk);
  }

  int rc = encode_bgra(frame, w, h, (int)dst_w, (int)quality, (int)webp,
                       out_path);
  free(frame);
  return rc;
}

/*
 * JPEG 文件 → 缩放 → JPEG 或 WebP 文件。取代 magick 那条纯缩放路径。
 *
 * 走 PipeWire 时用不到它：那条路直接从原始 BGRA 重编码。只有退回
 * spectacle 或假帧源、手上只有 JPEG 时才需要先解码。
 */
int32_t moonbit_image_jpeg_to_file(const char *src_path, int32_t dst_w,
                                   int32_t quality, int32_t webp,
                                   const char *out_path) {
  int w = 0;
  int h = 0;
  uint8_t *frame = decode_frame_bgra(src_path, &w, &h);
  if (frame == NULL) return 2;
  int rc = encode_bgra(frame, w, h, (int)dst_w, (int)quality, (int)webp,
                       out_path);
  free(frame);
  return rc;
}
