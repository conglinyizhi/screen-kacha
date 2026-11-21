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

#include <jpeglib.h>
#include <webp/encode.h>

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
 * 输出前把 BGRA 换成 RGB —— JPEG 要的是 RGB 顺序。
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
  if (w <= 0 || h <= 0 || quality < 1 || quality > 100) return 1;

  int dw = (dst_w <= 0 || dst_w > w) ? w : dst_w;
  /* 高度按比例算，四舍五入而不是截断：
   * 截断会让 40x30 → 13 宽算出 9 高（应为 9.75），画面轻微压扁。
   * 至少给 1 行，否则 37x23 → 1 宽会算出 0 高，整个渲染直接失败。 */
  int dh = (int)(((int64_t)h * dw + w / 2) / w);
  if (dh < 1) dh = 1;

  size_t need = (size_t)w * h * 4;
  uint8_t *bgra = read_file(bgra_path, need);
  if (bgra == NULL) return 2;

  uint8_t *rgb = (uint8_t *)malloc((size_t)dw * dh * 3);
  if (rgb == NULL) {
    free(bgra);
    return 3;
  }
  bgra_to_rgb_scaled(bgra, w, h, rgb, dw, dh);
  free(bgra);

  struct jpeg_compress_struct cinfo;
  struct jpeg_error_mgr jerr;
  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_compress(&cinfo);

  FILE *fp = fopen(out_path, "wb");
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
  fclose(fp);
  jpeg_destroy_compress(&cinfo);
  free(rgb);
  return 0;
}

/*
 * BGRA 文件 → WebP 文件。参数含义同上。
 *
 * WebP 有损压缩比 JPEG 慢一些，但体积能小两三成。
 */
int32_t moonbit_image_bgra_to_webp(const char *bgra_path, int32_t w, int32_t h,
                                   int32_t dst_w, int32_t quality,
                                   const char *out_path) {
  if (w <= 0 || h <= 0 || quality < 1 || quality > 100) return 1;

  int dw = (dst_w <= 0 || dst_w > w) ? w : dst_w;
  /* 高度按比例算，四舍五入而不是截断：
   * 截断会让 40x30 → 13 宽算出 9 高（应为 9.75），画面轻微压扁。
   * 至少给 1 行，否则 37x23 → 1 宽会算出 0 高，整个渲染直接失败。 */
  int dh = (int)(((int64_t)h * dw + w / 2) / w);
  if (dh < 1) dh = 1;

  size_t need = (size_t)w * h * 4;
  uint8_t *bgra = read_file(bgra_path, need);
  if (bgra == NULL) return 2;

  uint8_t *rgb = (uint8_t *)malloc((size_t)dw * dh * 3);
  if (rgb == NULL) {
    free(bgra);
    return 3;
  }
  bgra_to_rgb_scaled(bgra, w, h, rgb, dw, dh);
  free(bgra);

  uint8_t *out = NULL;
  size_t out_len = WebPEncodeRGB(rgb, dw, dh, dw * 3,
                                 (float)quality, &out);
  free(rgb);
  if (out_len == 0 || out == NULL) return 5;

  FILE *fp = fopen(out_path, "wb");
  if (fp == NULL) {
    WebPFree(out);
    return 4;
  }
  size_t written = fwrite(out, 1, out_len, fp);
  fclose(fp);
  WebPFree(out);
  return written == out_len ? 0 : 6;
}
