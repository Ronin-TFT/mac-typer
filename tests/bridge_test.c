// 用 C 调用 Go 静态库导出的引擎接口（不发送真实按键）。
// 构建：
//   go build -buildmode=c-archive -o build/libmactyper.a .
//   cc -I build -I . tests/bridge_test.c build/libmactyper.a -lpthread -o build/bridge-test
//   build/bridge-test
// macOS 还需加 -framework CoreFoundation -framework ApplicationServices
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "libmactyper.h"

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static long long lastDone = -1, lastTotal = -1, countdowns = 0, readies = 0;
static int finished = -1;
static char message[256];

static void callback(void *ctx, int kind, long long a, long long b, const char *msg) {
    assert(ctx == (void *)&mu);
    pthread_mutex_lock(&mu);
    if (kind == MT_EVENT_COUNTDOWN) countdowns++;
    if (kind == MT_EVENT_READY) readies++;
    if (kind == MT_EVENT_PROGRESS) { lastDone = a; lastTotal = b; }
    if (kind == MT_EVENT_FINISHED) {
        finished = (int)a;
        snprintf(message, sizeof message, "%s", msg ? msg : "");
    }
    pthread_mutex_unlock(&mu);
}

static void reset(void) {
    pthread_mutex_lock(&mu);
    lastDone = lastTotal = -1; countdowns = 0; readies = 0; finished = -1; message[0] = 0;
    pthread_mutex_unlock(&mu);
}

static int waitFinished(int ms) {
    for (int i = 0; i < ms; i++) {
        pthread_mutex_lock(&mu);
        int f = finished;
        pthread_mutex_unlock(&mu);
        if (f >= 0) return f;
        usleep(1000);
    }
    return -1;
}

int main(void) {
    MTConfig cfg = {0};
    cfg.dry_run = 1;
    cfg.typo_rate = 1;
    cfg.slip_rate = 0.3;
    cfg.natural = 1;

    char *err = MTStart("hello 你好", NULL, cfg, callback, &mu);
    assert(err == NULL);
    assert(waitFinished(2000) == MT_FINISH_DONE);
    assert(lastDone == 8 && lastTotal == 8);

    reset();
    MTConfig bad = cfg;
    bad.typo_rate = 2;
    err = MTStart("hello", NULL, bad, callback, &mu);
    assert(err && strstr(err, "错词概率"));
    MTFreeString(err);
    err = MTStart("hello", "/nonexistent/typos.txt", cfg, callback, &mu);
    assert(err);
    MTFreeString(err);
    assert(finished == -1);

    reset();
    cfg.countdown = 2;
    assert(MTStart("abc", NULL, cfg, callback, &mu) == NULL);
    err = MTStart("abc", NULL, cfg, callback, &mu);
    assert(err && strstr(err, "已有任务"));
    MTFreeString(err);
    usleep(100000);
    assert(MTSetPaused(1) == 1);
    assert(MTSetPaused(0) == 1);
    assert(MTStop() == 1);
    assert(waitFinished(1000) == MT_FINISH_STOPPED);
    assert(countdowns >= 1 && lastDone == -1);
    usleep(10000);
    assert(MTStop() == 0 && MTSetPaused(1) == 0);

    reset();
    MTConfig gated = cfg;
    gated.countdown = 0;
    gated.wait_ready = 1;
    assert(MTStart("gate", NULL, gated, callback, &mu) == NULL);
    usleep(100000);
    pthread_mutex_lock(&mu);
    assert(readies == 1 && lastDone == -1 && finished == -1);
    pthread_mutex_unlock(&mu);
    assert(MTSetPaused(0) == 1);
    assert(waitFinished(2000) == MT_FINISH_DONE && lastDone == 4);

    puts("bridge start, ready gate, validation, single-job guard, pause and stop passed");
    return 0;
}
