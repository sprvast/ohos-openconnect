/**
 * VpnManager 封装 —— 鸿蒙系统 VPN 隧道能力
 *
 * 鸿蒙 NEXT（API 26，HarmonyOS 6.0）使用系统 VPN 管理能力建立用户态隧道，
 * 取代 openconnect 传统所需的 root TUN 设备。本模块负责：
 *   1. 依据 openconnect 协商出的 IP/DNS/路由信息建立 VPN 隧道
 *   2. 取回隧道 fd 注入 openconnect 数据面 (openconnect_setup_tun_fd)
 *
 * ⚠️ 重要：鸿蒙 VPN 三方应用的开放程度（是否需要系统能力/受限 ACL）取决于
 * 具体版本与渠道授权。以下代码给出可编译的接入骨架，真实 API 名与调用方式
 * 需以真机 + API 26 实际 SDK 为准，并先完成《移植方案》第 9.2 节 POC-B 验证。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

/** openconnect 协商出的隧道网络参数（由 native 层 ip_info 填充） */
export interface IpInfo {
  addr: string;        // 本端地址
  netmask: string;     // 掩码
  addr6?: string;      // IPv6 地址
  dns: string[];       // DNS 服务器
  domain?: string;
  mtu: number;
  routes: string[];    // 通过隧道路由的网段
}

const TAG = 'VpnManager';

/**
 * 建立鸿蒙系统 VPN 隧道，返回可用于读写 IP 包的 fd。
 * 这是 POC-B 的关键接口 —— 需在真机上确认鸿蒙 VPN 能力的具体调用方式。
 */
async function startVpnTunnel(info: IpInfo): Promise<number> {
  hilog.info(0x0000, TAG, 'startVpnTunnel addr=%{public}s mtu=%{public}d',
    info.addr, info.mtu);
  // TODO(POC-B): 使用 @ohos.net.vpn / VpnManager 建立用户态隧道
  //   1. 创建 VPN 配置（本端地址、掩码、DNS、路由）
  //   2. 启动隧道
  //   3. 返回可读写的隧道 fd
  //
  // 占位实现：暂时返回 -1，等待鸿蒙 VPN 能力接入验证。
  return -1;
}

/** 停止 VPN 隧道 */
async function stopVpnTunnel(): Promise<void> {
  hilog.info(0x0000, TAG, 'stopVpnTunnel');
  // TODO(POC-B): 调用系统 VPN 停止接口
}

/** VpnManager 能力对象 */
export const VpnManager: {
  startVpnTunnel(info: IpInfo): Promise<number>;
  stopVpnTunnel(): Promise<void>;
} = {
  startVpnTunnel: startVpnTunnel,
  stopVpnTunnel: stopVpnTunnel
};
