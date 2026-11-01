/**
 * OpenConnect NAPI 封装层
 *
 * 通过 import 系统原生模块 'libopenconnect.so'（entry/src/main/cpp 编译产物，
 * 即 openconnect_bridge 模块）向 ArkTS 暴露 libopenconnect 的能力。
 * 导入名对应 CMake OUTPUT_NAME = "openconnect" → 产物 libopenconnect.so。
 */

interface OpenConnectNative {
  getVersion(): string;
  initSsl(): void;
  newSession(): number;
  parseUrl(url: string): number;
  setAuth(username: string, password: string): number;
  setAuthGroup(group: string): number;
  setMobileInfo(platform: string, deviceType: string, uniqueId: string): number;
  getServerAuthGroups(): string;
  obtainCookie(): number;
  makeCstpConnection(): number;
  getNetworkConfig(): string;
  injectTunFd(fd: number): number;
  setupDtls(): number;
  mainloop(): number;
  cancel(): void;
  requestStats(): void;
  freeSession(): void;
  getProgressLog(): string;
  getBanner(): string;
}

// 声明原生 so 模块类型（CMake 产出 libopenconnect.so，由 NAPI nm_modname 注册）
declare module 'libopenconnect.so' {
  const mod: OpenConnectNative;
  export default mod;
}

import oc from 'libopenconnect.so';

function getNative(): OpenConnectNative {
  return oc;
}

/** OpenConnect 原生能力对象，供页面调用。 */
export const OpenConnect: {
  initOpenConnect(): void;
  version(): string;
  newSession(): number;
  parseUrl(url: string): number;
  setAuth(user: string, pass: string): number;
  setAuthGroup(group: string): number;
  setMobileInfo(platform: string, deviceType: string, uniqueId: string): number;
  getServerAuthGroups(): string;
  obtainCookie(): number;
  makeCstpConnection(): number;
  getNetworkConfig(): string;
  injectTunFd(fd: number): number;
  setupDtls(): number;
  mainloop(): number;
  cancel(): void;
  requestStats(): void;
  freeSession(): void;
  getProgressLog(): string;
  getBanner(): string;
} = {
  // 初始化：主动调用 SSL 初始化，确保原生模块已加载
  initOpenConnect(): void {
    getNative().initSsl();
  },
  version(): string {
    return getNative().getVersion();
  },
  newSession(): number {
    return getNative().newSession();
  },
  parseUrl(url: string): number {
    return getNative().parseUrl(url);
  },
  setAuth(user: string, pass: string): number {
    return getNative().setAuth(user, pass);
  },
  setAuthGroup(group: string): number {
    return getNative().setAuthGroup(group);
  },
  setMobileInfo(platform: string, deviceType: string, uniqueId: string): number {
    return getNative().setMobileInfo(platform, deviceType, uniqueId);
  },
  getServerAuthGroups(): string {
    return getNative().getServerAuthGroups();
  },
  obtainCookie(): number {
    return getNative().obtainCookie();
  },
  makeCstpConnection(): number {
    return getNative().makeCstpConnection();
  },
  getNetworkConfig(): string {
    return getNative().getNetworkConfig();
  },
  injectTunFd(fd: number): number {
    return getNative().injectTunFd(fd);
  },
  setupDtls(): number {
    return getNative().setupDtls();
  },
  mainloop(): number {
    return getNative().mainloop();
  },
  cancel(): void {
    getNative().cancel();
  },
  requestStats(): void {
    getNative().requestStats();
  },
  freeSession(): void {
    getNative().freeSession();
  },
  getProgressLog(): string {
    return getNative().getProgressLog();
  },
  getBanner(): string {
    return getNative().getBanner();
  }
};
