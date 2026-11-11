package main

/*
#include <stdlib.h>
#include "engine_bridge.h"
*/
import "C"

import (
	"errors"
	"sync"
	"time"
	"unsafe"
)

// 图形界面同一时间只运行一个任务。
var (
	bridgeMu  sync.Mutex
	bridgeJob *job
)

// MTStart 校验参数并在后台开始任务。成功返回 NULL；失败返回错误信息，
// 调用方需用 MTFreeString 释放。
//
//export MTStart
func MTStart(text, typoPath *C.char, cfg C.MTConfig, cb C.MTCallback, ctx unsafe.Pointer) *C.char {
	conf := config{
		delay:     time.Duration(cfg.delay_ns),
		jitter:    time.Duration(cfg.jitter_ns),
		countdown: int(cfg.countdown),
		typoRate:  float64(cfg.typo_rate),
		slipRate:  float64(cfg.slip_rate),
		natural:   cfg.natural != 0,
		gateStart: cfg.wait_ready != 0,
	}
	var sink keySink = nativeSink{}
	if cfg.dry_run != 0 {
		sink = nopSink{}
	}
	path := ""
	if typoPath != nil {
		path = C.GoString(typoPath)
	}

	bridgeMu.Lock()
	defer bridgeMu.Unlock()
	if bridgeJob != nil {
		return C.CString("已有任务在执行")
	}
	j, input, err := prepare(conf, C.GoString(text), path, sink)
	if err != nil {
		return C.CString(err.Error())
	}
	j.onCountdown = func(n int) {
		C.mtNotify(cb, ctx, C.MT_EVENT_COUNTDOWN, C.longlong(n), 0, nil)
	}
	j.onReady = func() {
		C.mtNotify(cb, ctx, C.MT_EVENT_READY, 0, 0, nil)
	}
	j.onProgress = func(done, total int) {
		C.mtNotify(cb, ctx, C.MT_EVENT_PROGRESS, C.longlong(done), C.longlong(total), nil)
	}
	bridgeJob = j

	go func() {
		err := j.Run(input)
		bridgeMu.Lock()
		if bridgeJob == j {
			bridgeJob = nil
		}
		bridgeMu.Unlock()

		reason := C.MT_FINISH_DONE
		var msg *C.char
		switch {
		case errors.Is(err, errStopped):
			reason = C.MT_FINISH_STOPPED
		case err != nil:
			reason = C.MT_FINISH_ERROR
			msg = C.CString(err.Error())
			defer C.free(unsafe.Pointer(msg))
		}
		C.mtNotify(cb, ctx, C.MT_EVENT_FINISHED, C.longlong(reason), 0, msg)
	}()
	return nil
}

// MTSetPaused 暂停或继续当前任务，没有任务时返回 0。
//
//export MTSetPaused
func MTSetPaused(paused C.int) C.int {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()
	if bridgeJob == nil {
		return 0
	}
	bridgeJob.SetPaused(paused != 0)
	return 1
}

// MTStop 结束当前任务。任务结束后会收到 MT_EVENT_FINISHED。
//
//export MTStop
func MTStop() C.int {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()
	if bridgeJob == nil {
		return 0
	}
	bridgeJob.Stop()
	return 1
}

//export MTFreeString
func MTFreeString(s *C.char) {
	C.free(unsafe.Pointer(s))
}
