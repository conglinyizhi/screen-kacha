/* PipeWire 抓帧 shim：常驻一条流，把最新一帧留给 MoonBit 侧按需取走。
 *
 * 设计要点：
 * - 自己起线程跑 pw_main_loop，MoonBit 的事件循环不受影响
 * - 生产端只更新「最新帧指针」，不做 memcpy；消费端取帧时才拷贝
 * - 同一时刻只持有一个 pw_buffer，下一帧到来时把旧的还回去，避免堆栈
 *
 * 对 MoonBit 暴露 4 个入口：start / latest / 宽高 / 序号。
 */
#include <moonbit.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct pwshim {
    struct pw_main_loop *loop;
    struct pw_stream *stream;
    pthread_t thread;
    int running;
    int started;

    pthread_mutex_t lock;
    struct pw_buffer *held;   /* 当前持有的最新帧缓冲 */
    int width;
    int height;
    int stride;
    uint64_t seq;
    int64_t ts_ms;
    char err[256];
};

static struct pwshim g;

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void on_process(void *userdata) {
    struct pwshim *s = userdata;
    struct pw_buffer *b = pw_stream_dequeue_buffer(s->stream);
    if (b == NULL) {
        return;
    }
    struct spa_buffer *buf = b->buffer;
    if (buf->datas[0].data == NULL || buf->datas[0].chunk->size == 0) {
        pw_stream_queue_buffer(s->stream, b);
        return;
    }

    pthread_mutex_lock(&s->lock);
    struct pw_buffer *old = s->held;
    s->held = b;
    s->seq++;
    s->ts_ms = now_ms();
    pthread_mutex_unlock(&s->lock);

    /* 旧缓冲还给 PipeWire，让它继续复用 */
    if (old != NULL) {
        pw_stream_queue_buffer(s->stream, old);
    }
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
    struct pwshim *s = userdata;
    if (param == NULL || id != SPA_PARAM_Format) {
        return;
    }
    struct spa_video_info info;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) {
        return;
    }
    if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) {
        return;
    }
    if (spa_format_video_raw_parse(param, &info.info.raw) < 0) {
        return;
    }
    pthread_mutex_lock(&s->lock);
    s->width = info.info.raw.size.width;
    s->height = info.info.raw.size.height;
    pthread_mutex_unlock(&s->lock);
}

static void on_state_changed(void *userdata, enum pw_stream_state old,
                             enum pw_stream_state state, const char *error) {
    struct pwshim *s = userdata;
    (void)old;
    if (error != NULL) {
        snprintf(s->err, sizeof(s->err), "%s: %s", pw_stream_state_as_string(state), error);
    }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

static void *thread_main(void *arg) {
    struct pwshim *s = arg;
    pw_main_loop_run(s->loop);
    return NULL;
}

/* 启动抓帧流。返回 0 成功，负数是 -errno 或自定义错误码。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_pw_shim_start(int32_t node_id, const char *app_name) {
    if (g.started) {
        return 0;
    }
    memset(&g, 0, sizeof(g));
    pthread_mutex_init(&g.lock, NULL);

    pw_init(NULL, NULL);
    g.loop = pw_main_loop_new(NULL);
    if (g.loop == NULL) {
        return -1;
    }
    struct pw_context *ctx = pw_context_new(pw_main_loop_get_loop(g.loop), NULL, 0);
    if (ctx == NULL) {
        return -2;
    }
    if (pw_context_connect(ctx, NULL, 0) == NULL) {
        return -3;
    }

    char node[16];
    snprintf(node, sizeof(node), "%d", (int)node_id);
    // 应用名只影响这条流在 pw-dump / pavucontrol 里怎么显示，不影响权限
    const char *app = (app_name && *app_name) ? app_name : "moonpipewire";
    char stream_name[128];
    snprintf(stream_name, sizeof(stream_name), "%s-capture", app);
    g.stream = pw_stream_new_simple(
        pw_main_loop_get_loop(g.loop), stream_name,
        pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                          PW_KEY_MEDIA_ROLE, "Screen", PW_KEY_TARGET_OBJECT, node,
                          PW_KEY_APP_NAME, app, NULL),
        &stream_events, &g);
    if (g.stream == NULL) {
        return -4;
    }

    uint8_t params_buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(params_buf, sizeof(params_buf));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(
        &b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format,
        SPA_POD_CHOICE_ENUM_Id(3, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx,
                               SPA_VIDEO_FORMAT_RGBx),
        0);

    if (pw_stream_connect(g.stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                          PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params,
                          1) < 0) {
        return -5;
    }

    g.started = 1;
    g.running = 1;
    if (pthread_create(&g.thread, NULL, thread_main, &g) != 0) {
        g.started = 0;
        return -6;
    }
    return 0;
}

/* 把最新一帧拷进调用方缓冲区，返回写入字节数；没有帧返回 0。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_pw_shim_latest(uint8_t *dst, int32_t cap) {
    if (!g.started || dst == NULL || cap <= 0) {
        return 0;
    }
    int32_t n = 0;
    pthread_mutex_lock(&g.lock);
    if (g.held != NULL) {
        struct spa_buffer *buf = g.held->buffer;
        uint32_t size = buf->datas[0].chunk->size;
        if (size > 0 && (int32_t)size <= cap) {
            memcpy(dst, buf->datas[0].data, size);
            n = (int32_t)size;
        }
    }
    pthread_mutex_unlock(&g.lock);
    return n;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_pw_shim_width(void) {
    int32_t v;
    pthread_mutex_lock(&g.lock);
    v = g.width;
    pthread_mutex_unlock(&g.lock);
    return v;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_pw_shim_height(void) {
    int32_t v;
    pthread_mutex_lock(&g.lock);
    v = g.height;
    pthread_mutex_unlock(&g.lock);
    return v;
}

MOONBIT_FFI_EXPORT
int64_t moonbit_pw_shim_seq(void) {
    int64_t v;
    pthread_mutex_lock(&g.lock);
    v = (int64_t)g.seq;
    pthread_mutex_unlock(&g.lock);
    return v;
}

MOONBIT_FFI_EXPORT
int64_t moonbit_pw_shim_ts_ms(void) {
    int64_t v;
    pthread_mutex_lock(&g.lock);
    v = g.ts_ms;
    pthread_mutex_unlock(&g.lock);
    return v;
}

/* 最近一次错误信息（空字符串表示没有）。 */
MOONBIT_FFI_EXPORT
const char *moonbit_pw_shim_error(void) {
    return g.err;
}

/* 把最新一帧原始字节写到固定路径，交给 magick 转码用。
 * 返回写入字节数，没有帧返回 0。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_pw_save_raw(const char *path) {
    int32_t n = 0;
    pthread_mutex_lock(&g.lock);
    if (g.held != NULL) {
        struct spa_buffer *buf = g.held->buffer;
        uint32_t size = buf->datas[0].chunk->size;
        if (size > 0) {
            FILE *f = (path && *path) ? fopen(path, "wb") : NULL;
            if (f != NULL) {
                if (fwrite(buf->datas[0].data, 1, size, f) == size) {
                    n = (int32_t)size;
                }
                fclose(f);
            }
        }
    }
    pthread_mutex_unlock(&g.lock);
    return n;
}

/* 结束一个残留的 portal 助手进程。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_pw_kill(int32_t pid) {
    if (pid <= 0) return -1;
    return (int32_t)kill((pid_t)pid, SIGTERM);
}

/* 停掉抓帧流：先断流，再退出 main loop 并回收线程。 */
MOONBIT_FFI_EXPORT
int32_t moonbit_pw_shim_stop(void) {
    if (!g.started) return 0;
    pthread_mutex_lock(&g.lock);
    struct pw_buffer *held = g.held;
    g.held = NULL;
    pthread_mutex_unlock(&g.lock);
    if (held != NULL) {
        pw_stream_queue_buffer(g.stream, held);
    }
    if (g.stream != NULL) {
        pw_stream_disconnect(g.stream);
        pw_stream_destroy(g.stream);
        g.stream = NULL;
    }
    if (g.loop != NULL) {
        pw_main_loop_quit(g.loop);
    }
    if (g.running) {
        pthread_join(g.thread, NULL);
        g.running = 0;
    }
    if (g.loop != NULL) {
        pw_main_loop_destroy(g.loop);
        g.loop = NULL;
    }
    g.started = 0;
    return 0;
}
