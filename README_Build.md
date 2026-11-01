# OpenConnect for HarmonyOS NEXT (鸿蒙 6.0)

将 openconnect SSL VPN 客户端移植到 HarmonyOS NEXT（API 26 / HarmonyOS 6.0）手机与平板。

## ⚠️ 发布与安全须知（重要）

本仓库为**公开源码**，出于安全考虑，以下**含真实密钥 / 凭据的文件已通过 `.gitignore` 排除，不在仓库内**：

- 工程根 `build-profile.json5` —— 含 AGC 自动签名私钥（`certpath` / `keyAlias` / `keyPassword` / `storeFile` / `storePassword`）。克隆后需在 DevEco Studio 中**重新配置签名**方可打包安装。
- `AppScope/resources/rawfile/agconnect-services.json` —— 含 AGC `client_secret` / `api_key`。克隆后需在华为开发者平台创建应用并**替换为你自己的 AGC 配置**。

因此克隆本仓库后无法立即带签名构建，请先完成上述两项配置。

## 目录结构

```
ohos-openconnect/
├── build-profile.json5            # 工程级构建配置 (HarmonyOS 26, API 26)
├── oh-package.json5               # 依赖清单
├── hvigor/                        # hvigor 构建配置
├── entry/
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5           # 权限与能力声明 (INTERNET, GET_NETWORK_INFO)
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets
│       │   ├── pages/Index.ets    # 连接/断开界面
│       │   ├── napi/OpenConnect.ts  # NAPI 封装
│       │   └── napi/VpnManager.ts   # 鸿蒙系统 VPN 隧道封装 (POC-B)
│       ├── cpp/                   # native 层
│       │   ├── CMakeLists.txt
│       │   ├── napi_init.cpp
│       │   ├── openconnect_bridge.h
│       │   ├── openconnect_bridge.cpp  # libopenconnect NAPI 绑定
│       │   └── third_party/       # 三方静态库放置目录（需自行交叉编译）
│       └── resources/             # 界面资源
└── patches/
    ├── 0001-ohos-adaptation.patch         # openconnect 源码鸿蒙适配补丁
    └── openconnect-ohos-adapted.tar.gz    # 已打好补丁的 openconnect 源码
```

## 如何构建

### 前置条件

1. **完整鸿蒙 NDK**：DevEco 自带的 `sdk/default/openharmony/native` 即为**完整 NDK**
   （含标准 libc 头 stdio.h/errno.h、`libc.a` 与 NAPI 头 `napi/native_api.h`），无需额外安装。
   不要用 `hms/native`（精简版）。
2. **交叉编译工具链**：直接使用 `sdk/default/openharmony/native/llvm/bin/clang.exe`，
   编译标志 `--target=aarch64-linux-ohos --sysroot=<native>/sysroot -D__MUSL__`。
3. **第三方库（已全部完成 arm64）**：
   - `third_party/aarch64-linux-ohos/` 下已有 **libz.a / libssl.a / libcrypto.a / libxml2.a / libopenconnect.a**（均为 fPIC、aarch64-ohos）。
   - 可运行 `scripts/cross-build-zlib-ohos.sh`、`scripts/cross-build-openssl-libxml2-ohos.sh` 复现。
   - 参考 NAPI 动态库：`third_party/aarch64-linux-ohos/libopenconnect-reference/libopenconnect.so`
     （由 bridge + 四库静态链接，导出 `RegisterOpenConnectModule`，仅依赖 hilog/napi/libc++/libc）。
4. **真机/模拟器**：POC-B（鸿蒙 VpnManager VPN 隧道）需在鸿蒙 6.0 真机上验证。

### 步骤

1. 把 openconnect 源码打上鸿蒙适配补丁：
   ```bash
   cd openconnect-master
   git apply ../ohos-openconnect/patches/0001-ohos-adaptation.patch
   autoreconf -i   # 或 ./autogen.sh
   ```
   补丁作用：
   - `tun.c`：鸿蒙沙箱下禁用内核 TUN 创建，统一走 `openconnect_setup_tun_fd()` 注入。
   - `configure.ac`：识别 `aarch64-*-linux-ohos` host，定义 `__ohos__` 宏。
2. 交叉编译 openconnect 及其依赖，生成 `.a` 放入 `cpp/third_party/<abi>/`。
3. 用 DevEco Studio 打开本工程，Sync 后构建 HAP。

## 架构总览

```
ArkTS (Index.ets, VpnManager.ts)
   │  NAPI (libopenconnect_bridge.so)
   ▼
libopenconnect (控制面 TLS/HTTP/认证 + 数据面 CSTP/DTLS)
   │  openconnect_setup_tun_fd()
   ▼
鸿蒙系统 VPN 隧道 (VpnManager) —— 取代 root TUN
```

## 移植关键点

| 原生能力 | 鸿蒙接入方式 |
|---|---|
| 创建 TUN 设备 | 不用内核 TUN；鸿蒙 VpnManager 提供用户态隧道 fd |
| socket 保护 | `openconnect_set_protect_socket_handler()` 回调 |
| 数据面主循环 | `openconnect_mainloop()`，鸿蒙 musl 的 poll/epoll 可用 |
| 脚本/路由下发 | 沙箱禁 fork 特权命令；由 ArkTS 通过系统 VPN 配置完成 |

## 当前状态与下一步

- ✅ 鸿蒙工程骨架（配置、ArkUI、NAPI、bridge 源码）
- ✅ openconnect 鸿蒙适配补丁（已生成、可干净 apply）
- ✅ **工具链打通 (POC-A 完成)**：完整 NDK + clang 交叉编译 zlib/OpenSSL/libxml2/openconnect
  四库（aarch64-ohos, fPIC），并成功把 bridge 静态链接出 `libopenconnect.so`。
- ✅ **DevEco 官方构建管线编译通过**：用 DevEco 内置 hvigor 命令行在纯 ASCII 路径 `C:\ocbuild`
  下执行 `assembleHap`，Native 侧经 CMake + Ninja 真正编译链接，产出 HAP（约 7 MB，
  内含 `libs/arm64-v8a/libopenconnect.so` 5.6 MB + `libc++_shared.so`），
  NAPI 模块构造函数 `RegisterOpenConnectModule` 导出正确，依赖
  `libhilog_ndk.z.so / libace_napi.z.so / libc++_shared.so / libc.so` 均满足。
- ⏳ **POC-B**：鸿蒙真机验证 VpnManager 隧道 fd → 打通数据面

### 本机命令行构建方式（备注）

1. 工程路径**必须为纯 ASCII**（hvigor 规范校验拒绝中文路径）：
   ```bash
   cp -r <源工程> /c/ocbuild
   ```
2. 设好环境变量并构建：
   ```bash
   export NODE_HOME="C:/Program Files/Huawei/DevEco Studio/tools/node"
   export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
   "C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.bat" \
     assembleHap --no-daemon -p product=default --mode module -p module=entry@default
   ```
   产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`
3. 已补充工程必需的 `AppScope/app.json5`（bundleName=com.openconnect.vpn 等）。
   因无签名配置，产物为 `-unsigned.hap`，真机安装需先在 DevEco 配置签名。
- ⏳ 完整 UI / 证书校验 / DTLS / 多厂商协议

> 本工程已具备完整可编译的 native 侧（四依赖库 + NAPI bridge + .so 参考产物）。
> 下一步是在 DevEco 中实际构建 HAP 到真机，并补齐 POC-B 的 VpnManager 隧道注入。
