# ohos-openconnect

基于开源项目 **OpenConnect**（GPL-2.0-or-later）移植到 **HarmonyOS NEXT** 的企业远程办公 **SSL VPN 客户端**。
本项目沿用了 OpenConnect 的开放协议与代码实现，并针对鸿蒙沙箱、三方 VPN 能力做了平台适配。

> ⚠️ **目前仅适配 AnyLink 网关**。项目以企业远程办公场景为目标，现阶段**只支持 AnyLink
> （AnyLinkOpenSource）服务器**，尚未适配 OpenConnect 的其他协议/厂商（如 GlobalProtect、
> Juniper、F5、Fortinet 等）。请在连接前确认你的服务器为 AnyLink 网关。

本项目为**开源学习与二次开发项目**，部分代码与协议实现**源自 OpenConnect 开源项目**
（https://www.infradead.org/openconnect/ ，GPL-2.0-or-later）。若您认为本项目涉及任何版权或侵权问题，
请通过 Gitee Issues 或页面联系方式**联系我们，我们将在核实后第一时间删除相关资源**，感谢理解与支持。

#### 软件架构

```
ArkTS (Index.ets / VpnManager.ts)
   │  NAPI (libopenconnect_bridge.so)
   ▼
libopenconnect（控制面 TLS/HTTP/认证 + 数据面 CSTP/DTLS）
   │  openconnect_setup_tun_fd()
   ▼
鸿蒙系统三方 VPN 隧道（VpnManager）—— 取代 root TUN
```

- **开发语言**：ArkTS + C++（NAPI native 层）
- **能力声明**：`INTERNET`、`GET_NETWORK_INFO`、三方 VPN（VpnExtensionAbility）
- **目标平台**：HarmonyOS NEXT（API 26 / HarmonyOS 6.0+）手机与平板（2in1、折叠屏适配中）
- **依赖**：libopenconnect / OpenSSL / libxml2 / zlib（aarch64-linux-ohos 交叉编译）

#### 安装教程

1.  克隆本仓库后，用 **DevEco Studio** 打开工程，`Sync` 同步依赖。
2.  因含 AGC 自动签名密钥的文件已被 `.gitignore` 排除，请先在工程根
    `build-profile.json5` 中**配置你的签名**，并在 `agconnect-services.json` 中
    **替换为你自己的华为 AGC 配置**（详见 `README_Build.md`）。
3.  连接 HarmonyOS 6.0+ 真机，DevEco 中点击 `Run` 构建安装 HAP。

#### 使用说明

1.  在应用主界面输入**服务器地址**（如企业 AnyLink 网关）、**用户名、密码**。
2.  点击**连接**，应用将自动拉取服务器下发的可选用户组并完成认证；认证成功后建立 VPN 隧道并注入数据面。
3.  连接成功后应用会弹窗展示服务器下发的 Banner 提示；点击**断开** 可优雅退出并恢复系统网络。
4.  密码仅本次连接使用，不会持久化保存在设备上。

> ⚠️ **当前仅适配 AnyLink 网关**（AnyLinkOpenSource）。仅支持 AnyLink 服务器，其他协议/厂商暂未适配：
> 请连接 AnyLink 网关使用，可自动拉取用户组、下发 Banner。

#### 参与贡献

1.  **Fork** 本仓库
2.  新建 `Feat_xxx` 分支
3.  提交代码
4.  新建 Pull Request

#### 开源协议

本项目基于 **OpenConnect**（GPL-2.0-or-later）衍生开发，整体以 **GPL-2.0-or-later** 许可对外发布。
OpenConnect 原始项目版权归其作者所有，请遵守相应的开源许可条款。

#### 侵权声明

本项目代码与资源若引用了第三方受版权保护的内容，或您认为本项目侵犯了您的合法权益，
请通过 Gitee Issues 与我们联系，我们将在核实后及时处理并删除相关内容。

#### 特技

1.  本开源项目使用 Readme\_XXX.md 来支持不同的语言，例如 Readme\_en.md、Readme\_zh.md。
2.  Gitee 官方博客 [blog.gitee.com](https://blog.gitee.com)
3.  你可以 [https://gitee.com/explore](https://gitee.com/explore) 这个地址来了解 Gitee 上的优秀开源项目
4.  [GVP](https://gitee.com/gvp) 全称是 Gitee 最有价值开源项目，是综合评定出的优秀开源项目
5.  Gitee 官方提供的使用手册 [https://gitee.com/help](https://gitee.com/help)
6.  Gitee 封面人物是一档用来展示 Gitee 会员风采的栏目 [https://gitee.com/gitee-stars](https://gitee.com/gitee-stars)
