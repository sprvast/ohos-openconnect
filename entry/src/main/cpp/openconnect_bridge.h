/*
 * openconnect_bridge.h
 *
 * NAPI 桥接层公共头文件：把 libopenconnect 的 C 对象句柄映射为
 * 可在 NAPI 回调与线程间传递的上下文。
 *
 * 该层逻辑参照 openconnect 官方 Android 移植 (jni.c) 的交互模式，
 * 将 JNI 语义翻译为 HarmonyOS NAPI 语义。C 侧行为与 Android 一致。
 */
#ifndef OPENCONNECT_BRIDGE_H
#define OPENCONNECT_BRIDGE_H

#include <napi/native_api.h>

#ifdef __cplusplus
extern "C" {
#endif

/* OpenConnect 会话上下文。
 * 通过一条 cmd pipe (openconnect_setup_cmd_pipe) 由主线程向数据面线程
 * 下发 取消/暂停/统计 等命令；与 jni.c 中的 ctx 结构对应。 */
typedef struct oc_session {
    struct openconnect_info *vpninfo; /* 原始 openconnect 上下文 */
    int cmd_fd;                       /* 命令管道写端 (mainloop 读端) */
    napi_env env;                     /* 创建会话时的 env(用于事件回调) */
    napi_ref js_this;                 /* 关联的宿主对象引用 */
    napi_ref on_event;                /* 事件回调(JS 函数) */
    int connected;                    /* 是否已进入数据面 */
} oc_session_t;

/* 由 ArkTS 线程建立 VPN 隧道后注入的 fd，通过 TLS 事件回调交给数据面。 */
extern int g_injected_tun_fd;

#ifdef __cplusplus
}
#endif

#endif /* OPENCONNECT_BRIDGE_H */
