// 图形界面与 Go 打字引擎之间的 C 接口类型。
#ifndef MAC_TYPER_ENGINE_BRIDGE_H
#define MAC_TYPER_ENGINE_BRIDGE_H

typedef struct {
    long long delay_ns;
    long long jitter_ns;
    int countdown;
    double typo_rate;
    double slip_rate;
    int natural;
    int dry_run; // 非 0 时不发送任何按键，仅用于测试
} MTConfig;

enum {
    MT_EVENT_COUNTDOWN = 1, // a = 剩余秒数
    MT_EVENT_PROGRESS = 2,  // a = 已输入字符数，b = 总字符数
    MT_EVENT_FINISHED = 3   // a = MT_FINISH_*，message 为错误信息
};

enum {
    MT_FINISH_DONE = 0,
    MT_FINISH_STOPPED = 1,
    MT_FINISH_ERROR = 2
};

// 回调在引擎线程上调用；message 只在回调期间有效。
typedef void (*MTCallback)(void *ctx, int kind, long long a, long long b, const char *message);

static inline void mtNotify(MTCallback cb, void *ctx, int kind, long long a, long long b, const char *message) {
    if (cb) cb(ctx, kind, a, b, message);
}

#endif
