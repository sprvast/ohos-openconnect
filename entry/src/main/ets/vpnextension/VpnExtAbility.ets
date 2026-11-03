/**
 * VpnExtAbility —— 鸿蒙三方 VPN 扩展（完整连接宿主）
 *
 * 架构原因：vpnExtension.createVpnConnection() 的参数要求 VpnExtensionContext，
 * 只能在 Vpn 扩展进程（com.openconnect.vpn:vpn）内调用，因此 vNIC 的 fd 只存在于
 * 扩展进程。为了让拿到 fd 的同一进程内能把它注入 openconnect 数据面，本扩展把
 * 「认证 → CSTP 协商 → 建 VPN 拿 fd → injectTunFd → mainloop」整条链路在
 * 扩展进程内完成（同进程，fd 天然可达）。
 *
 * 分两段并行：
 *   A. taskpool worker：后台 openconnect 认证+CSTP 协商（阻塞，避免卡主线程）
 *   B. 主线程：createVpnConnection 创建 vNIC 拿 fd（需用户授权）
 * 两者都完成后，再起一个 worker 把 fd 注入并运行数据面 mainloop。
 *
 * UI(Index.ets) 负责：
 *   - 收集 URL/账号/密码/用户组经 want.parameters 传入
 *   - startVpnExtensionAbility 启动本扩展
 *   - 轮询沙箱状态文件读取进度/结果
 *   - stopVpnExtensionAbility 断开
 */

import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import type Want from '@ohos.app.ability.Want';
import { vpnExtension } from '@kit.NetworkKit';
import { taskpool } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { deviceInfo, runningLock } from '@kit.BasicServicesKit';
import { OpenConnect } from '../napi/OpenConnect';

const TAG = 'VpnExtAbility';
const DOMAIN = 0x0000;

/** UI 轮询读取的状态文件（扩展进程写入，主进程只读） */
const STATUS_FILE_NAME = 'oc_vpn_status.txt';
/** 主进程写、扩展进程读的命令文件（跨进程优雅断开信令） */
const CMD_FILE_NAME = 'oc_vpn_cmd.txt';
/** 主进程写入该内容表示“用户主动断开” */
const CMD_USER_DISCONNECT = 'user_disconnect';

/** openconnect 认证/协商失败返回码(负数) → 中文原因提示。未列入的码才回退显示原始错误码 */
const AUTH_ERR_TEXT: Map<number, string> = new Map([
  [-22, '用户名或密码错误'],
  [-110, '连接服务器超时'],
  [-101, '网络不可达'],
  [-111, '服务器拒绝连接'],
  [-113, '无法连接到服务器'],
  [-104, '连接被服务器重置'],
  [-100, '网络已断开'],
]);

/** 保存 VpnConnection 实例，供断开 destroy 恢复网络 */
let gVpnConn: vpnExtension.VpnConnection | undefined = undefined;

/** 数据面 mainloop 的 taskpool 任务句柄（断开时等待其退出） */
let gDataTask: Promise<number> | undefined = undefined;

/** 当前状态文件绝对路径（onCreate 时由 this.context.filesDir 拼得） */
let gStatusPath: string = '';
/** 当前命令文件绝对路径 */
let gCmdPath: string = '';
/** 命令监听停止标志（数据面结束后置真，退出轮询循环） */
let gCmdWatchStop = false;
/** 数据面心跳停止标志（数据面结束后置真，退出心跳循环） */
let gHeartStop = false;

/** 本次连接实际收到的连接参数（onCreate 解析后保存，供认证失败时诊断打印，避免泄露密码原文） */
let gConnUrl = '';
let gConnUser = '';
let gConnPassLen = 0;
let gConnGroup = '';

/** 本次连接设置项：是否阻止与不受信任的服务器连接（true=严格校验证书） */
let gBlockUntrusted = true;
/** 本次连接设置项：是否启用 DTLS 加速（true=data 面启动 DTLS） */
let gEnableDtls = false;
/** 本次连接设置项：是否调试模式（true=状态文件尽量输出全量原始日志） */
let gDebugMode = false;

/**
 * 扩展进程后台运行锁。
 * runningLock 是 per-process 的 CPU 锁：主进程(Index.ets)持有的锁保护不了本扩展进程。
 * VPN 数据面跑在本扩展进程内，若不在此进程单独持锁，app 退到后台一段时间后系统会
 * 冻结/回收扩展进程，openconnect 心跳(keepalive/DPD)停止，服务器判定 Session 过期后踢下线。
 */
let gExtLock: runningLock.RunningLock | undefined = undefined;

/** 扩展进程持有后台运行锁（连接全程，防止系统在后台冻结/回收数据面进程） */
async function acquireExtLock(): Promise<void> {
  if (gExtLock) {
    return;
  }
  try {
    const type = runningLock.isSupported(runningLock.RunningLockType.BACKGROUND_USER_IDLE)
      ? runningLock.RunningLockType.BACKGROUND_USER_IDLE
      : runningLock.RunningLockType.BACKGROUND;
    if (runningLock.isSupported(type)) {
      gExtLock = await runningLock.create('OpenConnectVPNDataPlane', type);
      gExtLock.hold(-1); // -1 = 长期持有，直到连接结束手动释放
    }
  } catch (e) {
    gExtLock = undefined;
  }
}

/** 释放扩展进程后台运行锁 */
function releaseExtLock(): void {
  if (gExtLock) {
    try {
      gExtLock.unhold();
    } catch (e) {
      // 忽略释放异常
    }
    gExtLock = undefined;
  }
}

/** 写状态：追加到沙箱状态文件 + hilog */
function appendStatus(msg: string, path: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
  try {
    if (!path) {
      return;
    }
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
    fileIo.writeSync(f.fd, msg + '\n');
    fileIo.closeSync(f.fd);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'appendStatus failed: %{public}s', JSON.stringify(e));
  }
}

/** 阶段 A：后台认证 + CSTP 协商（阻塞，taskpool worker）
 *  blockUntrusted=true（默认）→ 校验证书，失败即拒绝；false → 接受任意证书 */
@Concurrent
function ocAuth(url: string, user: string, pass: string, group: string,
                platform: string, deviceType: string, uniqueId: string,
                blockUntrusted: boolean): number {
  OpenConnect.setTrustUntrustedServer(blockUntrusted);
  OpenConnect.newSession();
  const prc = OpenConnect.parseUrl(url);
  if (prc !== 0) {
    return prc; // <0 URL 失败
  }
  OpenConnect.setAuth(user, pass);
  OpenConnect.setAuthGroup(group);
  // 把操作系统与终端型号上报给服务器（AnyConnect 移动设备头）
  OpenConnect.setMobileInfo(platform, deviceType, uniqueId);
  const cookie = OpenConnect.obtainCookie();
  if (cookie !== 0) {
    return cookie; // <0 认证失败
  }
  const conn = OpenConnect.makeCstpConnection();
  if (conn !== 0) {
    return -1000 + conn; // CSTP 失败
  }
  return 0;
}

/** 阶段 C：注入 fd 并运行数据面 mainloop（阻塞，taskpool worker） */
@Concurrent
function ocTunnelRun(fd: number, enableDtls: boolean): number {
  OpenConnect.injectTunFd(fd);
  if (enableDtls) {
    OpenConnect.setupDtls();
  }
  OpenConnect.mainloop();
  return 0;
}

export default class VpnExtAbility extends VpnExtensionAbility {
  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'onCreate start');
    try {
      gStatusPath = this.context.filesDir + '/' + STATUS_FILE_NAME;
      gCmdPath = this.context.filesDir + '/' + CMD_FILE_NAME;
      gCmdWatchStop = false;
      gHeartStop = false;
      fileIo.truncateSync(gStatusPath);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'status init failed: %{public}s', JSON.stringify(e));
    }
    appendStatus('扩展已启动，读取连接参数...', gStatusPath);
    // 立即申请后台运行锁，防止连接/数据面期间扩展进程被系统冻结回收
    acquireExtLock().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'acquireExtLock failed: %{public}s', e.message);
    });

    // 从 UI 写入的沙箱配置文件读取连接参数（鸿蒙 Vpn 扩展拿不到 want.parameters，
    // Preferences 跨扩展进程不同步，改用与状态文件同机制的文件传参，跨进程可靠）
    let url = '';
    let user = '';
    let pass = '';
    let group = '';
    let session = '';
    // 本次连接的设置项（默认与 UI 一致的出厂值）
    let blockUntrusted = '1';
    let enableDtls = '0';
    let debugMode = '0';
    const cfgPath = this.context.filesDir + '/oc_vpn_cfg.txt';
    try {
      const text = fileIo.readTextSync(cfgPath);
      const lines = text.split('\n');
      for (const line of lines) {
        const idx = line.indexOf('=');
        if (idx < 0) {
          continue;
        }
        const key = line.substring(0, idx).trim();
        const value = line.substring(idx + 1).trim();
        if (key === 'session') {
          session = value;
        } else if (key === 'serverUrl') {
          url = value;
        } else if (key === 'username') {
          user = value;
        } else if (key === 'password') {
          pass = value;
        } else if (key === 'authGroup') {
          group = value;
        } else if (key === 'blockUntrusted') {
          blockUntrusted = value;
        } else if (key === 'enableDtls') {
          enableDtls = value;
        } else if (key === 'debugMode') {
          debugMode = value;
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read cfg failed: %{public}s', JSON.stringify(e));
    }
    // 保存设置项（数据面阶段按此决定是否启用 DTLS）
    gBlockUntrusted = (blockUntrusted === '1');
    gEnableDtls = (enableDtls === '1');
    gDebugMode = (debugMode === '1');
    appendStatus('设置项: 证书校验=' + (gBlockUntrusted ? '开' : '关') +
      ' DTLS=' + (gEnableDtls ? '开' : '关') +
      ' 调试模式=' + (gDebugMode ? '开' : '关'), gStatusPath);
    // 回写会话令牌，供 UI 确认这是读取了本次配置的全新实例（防止复用旧实例导致地址不切换）
    if (session) {
      appendStatus('SESSION_START=' + session, gStatusPath);
    }
    // 密码仅本次连接使用，读取后立即删除配置文件，避免密码持久化在设备上
    try {
      fileIo.unlinkSync(cfgPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'unlink cfg warn: %{public}s', JSON.stringify(e));
    }
    gConnUrl = url;
    gConnUser = user;
    gConnPassLen = pass.length;
    gConnGroup = group;
    if (!url || !user || !pass) {
      appendStatus('参数缺失（serverUrl=' + (url ? '有' : '无') + '/username=' +
        (user ? '有' : '无') + '/password=' + (pass ? '有' : '无') + '）', gStatusPath);
      return;
    }
    appendStatus('已取得连接参数（文件传参）', gStatusPath);
    appendStatus('参数已就绪，开始连接 ' + url, gStatusPath);

    // 收集设备信息：发行版 OS 名称+完整版本(含 Build 号，如 "HarmonyOS 7.0.0.111") + 终端型号，认证时上报给服务器
    const distName: string = (deviceInfo.distributionOSName && deviceInfo.distributionOSName.length > 0)
      ? deviceInfo.distributionOSName : 'HarmonyOS';
    const distVersion: string = (deviceInfo.distributionOSVersion && deviceInfo.distributionOSVersion.length > 0)
      ? deviceInfo.distributionOSVersion : deviceInfo.displayVersion;
    const buildVer: string = String(deviceInfo.buildVersion);
    const detailVer: string = (buildVer && buildVer.length > 0 && distVersion.indexOf(buildVer) < 0)
      ? distVersion + '.' + buildVer : distVersion;
    const platformVer: string = distName + ' ' + detailVer;
    // 优先使用营销名称（如 "Mate 70 Pro+"），无营销名时回退机型代码（如 PLA-AL10）
    const devModel: string = (deviceInfo.marketName && deviceInfo.marketName.length > 0)
      ? deviceInfo.marketName : deviceInfo.productModel;
    const devUid: string = (deviceInfo.serial && deviceInfo.serial.length > 0)
      ? deviceInfo.serial : '0000000000000000';
    appendStatus('设备信息: OS=' + platformVer + ', 型号=' + devModel, gStatusPath);

    // 阶段 A 与 B 并行启动
    const authTask = new taskpool.Task(ocAuth, url, user, pass, group, platformVer, devModel, devUid,
      gBlockUntrusted);
    const authP: Promise<number> = taskpool.execute(authTask) as Promise<number>;

    this.run(authP);
  }

  /** 并行执行认证（A）与建 VPN（B），成功后注入数据面（C） */
  private async run(authP: Promise<number>): Promise<void> {
    let authCode = 0;
    try {
      authCode = await authP;
    } catch (e) {
      appendStatus('认证任务异常: ' + JSON.stringify(e), gStatusPath);
    }

    if (authCode !== 0) {
      // 若证书校验被拒绝（严格模式开启时），读回 native 拒绝原因写状态文件，
      // 供 UI 检测后按原因弹窗提醒（名称不匹配/已过期/来源不受信任等）。
      try {
        const cReject: string = OpenConnect.getCertRejectReason();
        if (cReject && cReject.trim().length > 0) {
          appendStatus('CERT_REJECT=' + cReject.trim(), gStatusPath);
        }
      } catch (e) {
        // 读取失败不影响后续
      }
      // 追加 openconnect 本次认证的原始进度日志，供 UI 按真实报错分类弹窗
      // （组错误/账号不存在等未列入 AUTH_ERR_TEXT 的码，其原始原因都在这份日志里）。
      try {
        const ocLog: string = OpenConnect.getProgressLog();
        if (ocLog && ocLog.trim().length > 0) {
          const lines = ocLog.trim().split('\n').filter((l) => l.trim().length > 0);
          for (const ln of lines.slice(-12)) {
            appendStatus('AUTHLOG=' + ln.trim(), gStatusPath);
          }
        }
      } catch (e) {
        // 读取失败不影响后续
      }
      const reason: string | undefined = AUTH_ERR_TEXT.get(authCode);
      // 有对应中文提示则显示文字，否则回退显示原始错误码
      appendStatus(reason
        ? '认证/协商失败（' + reason + '）'
        : '认证/协商失败（code=' + authCode + '）', gStatusPath);
      appendStatus('关闭 VPN', gStatusPath);
      await this.destroyConn();
      return;
    }

    // 先取网络配置（getNetworkConfig 会发起/完成 CSTP 协商，并顺带捕获服务器
    // 下发的 X-CSTP-Banner 头到 native g_banner），再读 Banner 保证拿到实时文案。
    const netJson: string = OpenConnect.getNetworkConfig();
    appendStatus('服务器网络配置: ' + netJson, gStatusPath);

    // 读取服务器实时下发的 Banner（认证 success 响应 <banner> 提供）
    const banner: string = OpenConnect.getBanner();
    const bannerText: string = (banner && banner.trim().length > 0) ? banner.trim() : '';
    // 服务器未下发公告时（空）不发标记，UI 侧不弹窗提示
    if (bannerText.length > 0) {
      appendStatus('BANNER_START=' + bannerText + '=BANNER_END', gStatusPath);
    }

    // 阶段 B：本扩展进程创建 vNIC 拿 fd（需系统授权弹窗）
    const fd = await this.createVpnGetFd(netJson);
    if (fd < 0) {
      appendStatus('未取得 vNIC fd（' + fd + '），连接失败', gStatusPath);
      await this.destroyConn();
      return;
    }

    appendStatus('认证成功，取得 fd=' + fd + '，进入数据面...', gStatusPath);
    // 阶段 C：注入 fd + 数据面 mainloop（按设置启用 / 跳过 DTLS）
    try {
      const dataTask = new taskpool.Task(ocTunnelRun, fd, gEnableDtls);
      const dataP: Promise<number> = taskpool.execute(dataTask) as Promise<number>;
      gDataTask = dataP;
      // 数据面运行期间监听“用户主动断开”命令，优雅向服务器发送 BYE(logout)
      const watchP: Promise<void> = this.watchUserDisconnect();
      // 数据面运行期间周期写心跳（空行 touch 状态文件），供主进程识别进程被回收导致的异常断开
      const hbP: Promise<void> = this.runHeartbeat();
      const rc = await dataP;
      appendStatus('数据面主循环结束（rc=' + rc + '）', gStatusPath);
      gCmdWatchStop = true; // 数据面已结束，停止命令监听
      gHeartStop = true;   // 停止心跳
      await watchP;
      await hbP;
      // 回读 openconnect 内部日志（quit_reason / CSTP / SSL 等），定位退出原因
      const ocLog: string = OpenConnect.getProgressLog();
      if (ocLog && ocLog.trim().length > 0) {
        const lines = ocLog.trim().split('\n').filter((l) => l.trim().length > 0);
        // 调试模式：尽量输出全量原始日志，供用户诊断；非调试模式仅保留末尾 15 行，避免刷屏
        const shown = gDebugMode ? lines : lines.slice(-15);
        for (const ln of shown) {
          appendStatus('[oc] ' + ln, gStatusPath);
        }
      }
    } catch (e) {
      appendStatus('数据面异常: ' + JSON.stringify(e), gStatusPath);
    } finally {
      gDataTask = undefined;
      await this.destroyConn();
    }
  }

  /** 解析服务器网络配置 JSON，返回 VpnConfig */
  private buildVpnConfig(netJson: string): vpnExtension.VpnConfig {
    interface NetCfg {
      addr?: string;
      prefix?: number;
      mtu?: number;
      dns?: string[];
      routes?: string[];
    }
    let cfg: NetCfg = {};
    try {
      if (netJson && netJson.length > 0) {
        cfg = JSON.parse(netJson) as NetCfg;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'parse net config failed: %{public}s', JSON.stringify(e));
      cfg = {};
    }

    const addresses: vpnExtension.LinkAddress[] = [];
    if (cfg.addr && cfg.addr.length > 0) {
      addresses.push({
        address: { address: cfg.addr },
        prefixLength: (cfg.prefix && cfg.prefix > 0) ? cfg.prefix : 24
      });
    } else {
      addresses.push({ address: { address: '10.8.0.2' }, prefixLength: 24 });
    }

    // 路由：优先用服务器 split-includes（CIDR），为空时回退最小网段，绝不接管默认路由
    const routes: vpnExtension.RouteInfo[] = [];
    const routeList: string[] = (cfg.routes && cfg.routes.length > 0) ? cfg.routes : ['10.8.0.0/24'];
    const gateAddr: string = cfg.addr || '10.8.0.1';
    for (const r of routeList) {
      if (!r || r.length === 0 || r === '0.0.0.0/0' || r === '::/0') {
        continue; // 过滤默认路由，避免劫持手机全场流量
      }
      const slash = r.indexOf('/');
      const dest = slash > 0 ? r.substring(0, slash) : r;
      const plen = slash > 0 ? Number(r.substring(slash + 1)) : 24;
      routes.push({
        interface: 'eth0',
        destination: { address: { address: dest }, prefixLength: isNaN(plen) ? 24 : plen },
        gateway: { address: gateAddr },
        hasGateway: true,
        isDefaultRoute: false
      });
    }

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      mtu: (cfg.mtu && cfg.mtu > 0) ? cfg.mtu : 1400,
      isIPv4Accepted: true
    };
    // 服务器下发的 DNS（可选）
    if (cfg.dns && cfg.dns.length > 0) {
      const dnsList: string[] = cfg.dns.filter((d) => d && d.length > 0);
      if (dnsList.length > 0) {
        vpnConfig.dnsAddresses = dnsList;
      }
    }
    return vpnConfig;
  }

  /** 在本扩展进程创建 VPN 虚拟网卡，返回 vNIC fd（>0） */
  private async createVpnGetFd(netJson: string): Promise<number> {
    const vpnConnection = vpnExtension.createVpnConnection(this.context);
    gVpnConn = vpnConnection;
    appendStatus('VpnConnection created，请求系统授权创建虚拟网卡...', gStatusPath);

    const vpnConfig: vpnExtension.VpnConfig = this.buildVpnConfig(netJson);

    appendStatus('调用 vpnConnection.create(config)，等待授权...', gStatusPath);
    try {
      const fd: number = await vpnConnection.create(vpnConfig);
      appendStatus('create() 返回 vNIC fd=' + fd, gStatusPath);
      return fd;
    } catch (e) {
      appendStatus('create() 异常: ' + (e as Error).message, gStatusPath);
      return -1;
    }
  }

  /** 数据面运行期间周期写心跳（每 5s 追加一个空行并 touch 状态文件）。
   *  主进程据此判断本扩展进程是否存活：若状态文件超时无更新，则判定进程被系统回收。 */
  private async runHeartbeat(): Promise<void> {
    while (!gHeartStop) {
      await new Promise<void>((res) => setTimeout(res, 5000));
      if (gHeartStop) {
        break;
      }
      try {
        appendStatus('', gStatusPath); // 空行：刷新 mtime，不干扰日志显示
      } catch (e) {
        // 忽略心跳写入异常
      }
    }
  }

  /**
   * 轮询命令文件，监听“用户主动断开”：检测到后调用进程内有效的 cancel()
   * 让 openconnect 向服务器发送 BYE(logout) 帧，服务器据此记录“用户主动断开”。
   * 在数据面运行期间启动，数据面结束后退出。
   */
  private async watchUserDisconnect(): Promise<void> {
    while (!gCmdWatchStop) {
      try {
        const cmd = fileIo.readTextSync(gCmdPath);
        if (cmd && cmd.indexOf(CMD_USER_DISCONNECT) >= 0) {
          appendStatus('检测到用户断开请求，发送 BYE 给服务器(logout)...', gStatusPath);
          OpenConnect.cancel(); // 进程内有效：openconnect 发送 AC_PKT_DISCONN(BYE) 帧
          // 删除命令文件，避免重复触发
          try {
            fileIo.unlinkSync(gCmdPath);
          } catch (e) {
            // 忽略
          }
        }
      } catch (e) {
        // 文件尚不存在，忽略
      }
      await new Promise<void>((res) => setTimeout(res, 500));
    }
  }

  /** 关闭 VPN 恢复网络 */
  private async destroyConn(): Promise<void> {
    gCmdWatchStop = true;
    gHeartStop = true;
    OpenConnect.cancel();
    try {
      if (gDataTask) {
        await Promise.race([gDataTask, new Promise<void>((res) => setTimeout(res, 2500))]);
        gDataTask = undefined;
      }
      if (gVpnConn) {
        await gVpnConn.destroy();
        gVpnConn = undefined;
        appendStatus('VPN 已关闭，网络已恢复', gStatusPath);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'destroyConn failed: %{public}s', JSON.stringify(e));
    }
    OpenConnect.freeSession();
    releaseExtLock();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    OpenConnect.cancel();
    OpenConnect.freeSession();
    releaseExtLock();
    this.destroyConn().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'async destroy onDestroy failed: %{public}s', e.message);
    });
  }
}
