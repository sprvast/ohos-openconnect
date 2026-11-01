/*
 * napi_init.cpp
 *
 * NAPI 模块附加入口（可选）。当前 openconnect_bridge.cpp 已包含模块
 * 注册 (openconnect_module) 与 Init()。本文件保留作为初始化入口的
 * 组织位置，便于后续扩展日志、生命周期钩子。
 */
#include "openconnect_bridge.h"

/* 生命周期初始化：SDK 环境注入入口，供将来做全局初始化。 */
// napi_value globalInit(napi_env env, napi_callback_info info);
