/**
 * OpenConnect 主页面：VPN 连接/断开控制
 *
 * 连接流程（对应 native 层与 VpnManager 的协作）：
 *   1. 输入服务器 URL、账号、密码
 *   2. newSession + parseUrl + obtainCookie（认证）
 *   3. makeCstpConnection 取得 IP 信息
 *   4. 用 ip 信息经 VpnManager 建立隧道，取得 fd
 *   5. injectTunFd(fd) 注入数据面
 *   6. mainloop() 在 worker 线程运行
 */
import { taskpool } from '@kit.ArkTS';
import { OpenConnect } from '../napi/OpenConnect';
import { VpnManager, IpInfo } from '../napi/VpnManager';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import type Want from '@ohos.app.ability.Want';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { runningLock } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';

/** “关于 OpenConnect”弹窗：仿设置页排版展示应用信息、开源/许可与隐私说明 */
@CustomDialog
struct AboutDialog {
  controller?: CustomDialogController;

  private res(id: Resource): string {
    const ctx = this.getUIContext().getHostContext() as common.Context;
    return ctx.resourceManager.getStringSync(id);
  }

  build() {
    Column() {
      // 应用概览
      Column() {
        Text(this.res($r('app.string.app_title')))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_title'))
        Text(this.res($r('app.string.about_app_desc')))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 6 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 24, bottom: 18 })

      Divider().color($r('app.color.divider_light')).strokeWidth(0.5)

      this.sectionTitle(this.res($r('app.string.about_apply_info')))
      this.aboutRow(this.res($r('app.string.about_version')), '1.0.2')
      this.aboutRow(this.res($r('app.string.about_based_on')), 'OpenConnect v9.21')
      this.aboutRow(this.res($r('app.string.about_backend')), 'OpenConnect / AnyConnect')

      Divider().color($r('app.color.divider_light')).strokeWidth(0.5)

      this.sectionTitle(this.res($r('app.string.about_opensource')))
      this.aboutRow('ohos-openconnect', 'GPL-2.0-or-later')
      this.aboutRow('OpenConnect', 'LGPL-2.1-only')

      Divider().color($r('app.color.divider_light')).strokeWidth(0.5)

      this.sectionTitle(this.res($r('app.string.about_privacy')))
      Text(this.res($r('app.string.about_privacy_body')))
        .fontSize(12)
        .fontColor($r('app.color.text_gray8'))
        .width('100%')
        .padding({ left: 2, bottom: 14 })
        .textAlign(TextAlign.Start)

      Button(this.res($r('app.string.got_it')))
        .fontSize(14)
        .height(40)
        .width('100%')
        .margin({ top: 4, bottom: 16 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding({ left: 16, right: 16 })
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor($r('app.color.section'))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ left: 2, top: 12, bottom: 2 })
  }

  @Builder
  aboutRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.text_hint'))
    }
    .width('100%')
    .height(40)
    .padding({ left: 2, right: 2 })
  }
}

/** “添加服务器地址”弹窗：输入并保存新地址 */
@CustomDialog
struct AddServerDialog {
  controller?: CustomDialogController;
  onConfirm?: (addr: string) => void;

  @State input: string = '';

  private res(id: Resource): string {
    const ctx = this.getUIContext().getHostContext() as common.Context;
    return ctx.resourceManager.getStringSync(id);
  }

  build() {
    Column() {
      Text(this.res($r('app.string.add_server_title')))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_title'))
        .margin({ top: 20, bottom: 12 })
      TextInput({ placeholder: this.res($r('app.string.new_server_placeholder')), text: this.input })
        .width('100%')
        .height(44)
        .fontSize(14)
        .onChange((v: string) => this.input = v)
        .onSubmit(() => {
          this.onConfirm?.(this.input);
          this.controller?.close();
        })
      Row({ space: 12 }) {
        Button(this.res($r('app.string.cancel')))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .backgroundColor('#cccccc')
          .onClick(() => this.controller?.close())
        Button(this.res($r('app.string.confirm_btn')))
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .onClick(() => {
            this.onConfirm?.(this.input);
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 16, bottom: 8 })
    }
    .padding({ left: 16, right: 16 })
  }
}

/** “选择服务器地址”弹窗：历史地址列表（可滑动），点击选择、长按删除，末尾添加 */
@CustomDialog
struct ServerSelectDialog {
  controller?: CustomDialogController;
  items: string[] = [];
  current: string = '';
  onSelect?: (addr: string) => void;
  onDelete?: (addr: string) => void;
  onAdd?: () => void;

  @State localItems: string[] = [];
  @State localCurrent: string = '';

  private res(id: Resource): string {
    const ctx = this.getUIContext().getHostContext() as common.Context;
    return ctx.resourceManager.getStringSync(id);
  }

  aboutToAppear(): void {
    this.localItems = this.items.slice();
    this.localCurrent = this.current;
  }

  private confirmDelete(addr: string): void {
    promptAction.showDialog({
      title: this.res($r('app.string.delete_server_title')),
      message: this.res($r('app.string.delete_server_msg')) + '\n' + addr,
      buttons: [
        { text: this.res($r('app.string.cancel')), color: '#666666' },
        { text: this.res($r('app.string.delete')), color: '#cf1322' }
      ]
    }).then((res) => {
      if (res.index === 1) {
        this.localItems = this.localItems.filter((x) => x !== addr);
        this.onDelete?.(addr);
      }
    }).catch(() => {
    });
  }

  build() {
    Column() {
      Text(this.res($r('app.string.choose_server')))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_title'))
        .margin({ top: 20, bottom: 8 })

      if (this.localItems.length === 0) {
        Text(this.res($r('app.string.no_saved_server')))
          .fontSize(14)
          .fontColor($r('app.color.text_hint'))
          .height(120)
      } else {
        List() {
          ForEach(this.localItems, (addr: string) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(addr)
                  .fontSize(14)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (addr === this.localCurrent) {
                  Text('✓').fontSize(14).fontColor($r('app.color.text_link'))
                }
                Text(this.res($r('app.string.long_press_delete')))
                  .fontSize(11)
                  .fontColor($r('app.color.text_hint'))
              }
              .width('100%')
              .height(48)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.onSelect?.(addr);
                this.controller?.close();
              })
              .gesture(
                LongPressGesture().onAction(() => this.confirmDelete(addr))
              )
            }
          }, (addr: string) => addr)
        }
        .height(220)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      Divider().color($r('app.color.divider_light')).strokeWidth(0.5).margin({ top: 4 })

      Button(this.res($r('app.string.add_new_server')))
        .fontSize(14)
        .height(40)
        .width('100%')
        .margin({ top: 8, bottom: 6 })
        .onClick(() => {
          this.controller?.close();
          this.onAdd?.();
        })

      Text(this.res($r('app.string.long_press_delete_hint')))
        .fontSize(11)
        .fontColor($r('app.color.text_hint'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
    }
    .padding({ left: 16, right: 16 })
  }
}

/** 后台探测服务器可选用户组：发起一次认证，回调收集 group 列表后返回（忽略最终结果） */
@Concurrent
function ocProbeGroups(url: string): string {
  OpenConnect.newSession();
  OpenConnect.parseUrl(url);
  OpenConnect.obtainCookie(); // 回调会把 group 列表写入 g_auth_groups
  const groups = OpenConnect.getServerAuthGroups();
  OpenConnect.freeSession();
  return groups;
}

/** 后台运行锁：VPN 连接期间持有，防止误清后台/系统休眠导致连接中断 */
let gRunningLock: runningLock.RunningLock | undefined = undefined;

/** 获取后台运行锁（失败不影响连接，仅做保活增强） */
async function acquireRunningLock(): Promise<void> {
  if (gRunningLock) {
    return;
  }
  try {
    if (runningLock.isSupported(runningLock.RunningLockType.BACKGROUND_USER_IDLE)) {
      gRunningLock = await runningLock.create('OpenConnectVPNActive',
        runningLock.RunningLockType.BACKGROUND_USER_IDLE);
      gRunningLock.hold(-1); // -1 = 长期持有，直到手动释放
    } else if (runningLock.isSupported(runningLock.RunningLockType.BACKGROUND)) {
      gRunningLock = await runningLock.create('OpenConnectVPNActive',
        runningLock.RunningLockType.BACKGROUND);
      gRunningLock.hold(-1);
    }
  } catch (e) {
    gRunningLock = undefined;
  }
}

/** 释放后台运行锁 */
function releaseRunningLock(): void {
  try {
    if (gRunningLock) {
      gRunningLock.unhold();
      gRunningLock = undefined;
    }
  } catch (e) {
    gRunningLock = undefined;
  }
}

// ---- 记住连接信息（地址/用户名/用户组/密码）----

/** 偏好存储文件名 */
const PREFS_NAME = 'openconnect_login';

/** 从 preferences 读取字符串，读不到返回默认值 */
async function prefGet(context: common.Context, key: string, def: string): Promise<string> {
  try {
    const p = await preferences.getPreferences(context, PREFS_NAME);
    const v = await p.get(key, def);
    return typeof v === 'string' ? v : def;
  } catch (e) {
    return def;
  }
}

/** 保存字符串到 preferences */
async function prefPut(context: common.Context, key: string, value: string): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, PREFS_NAME);
    await p.put(key, value);
    await p.flush();
  } catch (e) {
    // 忽略：保存失败不影响连接
  }
}

/** 从 preferences 读取字符串数组（JSON 存储），读不到返回空数组 */
async function prefGetList(context: common.Context, key: string): Promise<string[]> {
  try {
    const p = await preferences.getPreferences(context, PREFS_NAME);
    const v = await p.get(key, '[]');
    if (typeof v === 'string') {
      const parsed: object[] = JSON.parse(v);
      const out: string[] = [];
      if (parsed instanceof Array) {
        for (let i = 0; i < parsed.length; i++) {
          const item = parsed[i];
          if (typeof item === 'string') {
            out.push(item);
          }
        }
      }
      return out;
    }
    return [];
  } catch (e) {
    return [];
  }
}

/** 保存字符串数组到 preferences（JSON 存储） */
async function prefPutList(context: common.Context, key: string, value: string[]): Promise<void> {
  try {
    const p = await preferences.getPreferences(context, PREFS_NAME);
    await p.put(key, JSON.stringify(value));
    await p.flush();
  } catch (e) {
    // 忽略：保存失败不影响连接
  }
}

/** 把地址追加进历史列表：去空、去重、新地址排最前，最多保留 MAX 个 */
function pushServerHistory(history: string[], addr: string, max: number): string[] {
  const a = addr.trim();
  if (!a) {
    return history;
  }
  const next = [a, ...history.filter((x) => x !== a)];
  return next.slice(0, max);
}


@Entry
@Component
struct Index {
  @State serverUrl: string = '';
  @State serverHistory: string[] = [];
  /** 是否正在输入新的服务器地址（下拉里选"+新增"时展开） */
  @State addingServer: boolean = false;
  @State newServerInput: string = '';
  @State username: string = '';
  @State password: string = '';
  @State authGroup: string = '';
  @State groupOptions: string[] = [];
  @State statusText: string = '未连接';
  @State isConnecting: boolean = false;
  @State isConnected: boolean = false;
  @State versionText: string = '';
  @State logText: string = '';
  @State tunFdText: string = '';
  @State vpnTestActive: boolean = false;
  /** 已连接时长（显示用，如 "02:35"） */
  @State connectedDuration: string = '';
  /** 当前是否处于"已断开（被服务器终止会话）"状态，用于状态文本展示 */
  @State sessionKicked: boolean = false;
  /** 服务器地址下拉是否展开（自绘下拉，长按单个地址可删除） */
  @State serverDropdownOpen: boolean = false;
  /** “关于 OpenConnect”弹窗控制器 */
  private aboutCtrl: CustomDialogController = new CustomDialogController({
    builder: AboutDialog(),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });
  /** “添加服务器地址”弹窗控制器（选末尾“添加”项时创建并打开） */
  private addCtrl?: CustomDialogController;
  /** “选择服务器地址”弹窗控制器 */
  private selCtrl?: CustomDialogController;

  /** 连接建立成功的时间戳（毫秒），用于计算并显示连接时长 */
  private _connectStartTime: number = 0;
  /** 本次连接是否曾成功进入数据面（曾为 true，则后续中断视为网络/会话中断） */
  private _hadDataPlane: boolean = false;
  /** 本次连接的会话令牌（UI 写入配置、扩展回写 SESSION_START，用于确认全新实例） */
  private _sessionId: string = '';

  aboutToAppear(): void {
    try {
      OpenConnect.initOpenConnect();
      this.versionText = 'libopenconnect ' + OpenConnect.version();
    } catch (e) {
      this.logText = '原生模块加载失败: ' + JSON.stringify(e);
      hilog.error(0x0000, 'Index', 'init failed: %{public}s', JSON.stringify(e));
    }
    // 恢复记住的服务器地址/用户名/用户组/密码
    this.restoreLogin();
  }

  /** 启动时恢复上次记住的连接信息：地址/用户名/用户组/密码（preferences 自动回填） */
  private async restoreLogin(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      // 历史服务器地址列表
      const savedHistory = await prefGetList(context, 'serverHistory');
      if (savedHistory.length > 0) {
        this.serverHistory = savedHistory;
        this.serverUrl = savedHistory[0]; // 默认回填最近使用的地址
      }
      const savedUser = await prefGet(context, 'username', '');
      if (savedUser) {
        this.username = savedUser;
      }
      // 恢复上次选择的用户组（拉取用户组后作为默认选中项）
      const savedGroup = await prefGet(context, 'authGroup', '');
      if (savedGroup) {
        this.authGroup = savedGroup;
      }
      // 密码不做持久化，每次连接前由用户手动填写
      if (savedHistory.length > 0) {
        this.appendLog('已恢复历史服务器地址');
      }
      // 恢复出默认服务器地址后，自动拉取一次用户组（失败不阻断其余恢复流程）
      if (this.serverUrl.length > 0) {
        await this.fetchServerGroups();
      }
    } catch (e) {
      // 恢复失败不阻断
    }
  }

  /** 连接成功后记住地址/用户名/用户组（密码不持久化，每次手动填写） */
  private async saveLogin(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      // 将当前地址加入历史列表并持久化（去重，最多保留 10 个）
      const next = pushServerHistory(this.serverHistory, this.serverUrl, 10);
      this.serverHistory = next;
      await prefPutList(context, 'serverHistory', next);
      await prefPut(context, 'username', this.username);
      if (this.authGroup) {
        await prefPut(context, 'authGroup', this.authGroup);
      }
      this.appendLog('已记住连接信息（地址/用户名）');
    } catch (e) {
      this.appendLog('保存连接信息失败: ' + JSON.stringify(e));
    }
  }

  /** 记住用户选择的用户组，下次启动默认选中 */
  private async saveAuthGroup(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      await prefPut(context, 'authGroup', this.authGroup);
    } catch (e) {
      // 忽略保存失败
    }
  }

  /** 弹出“关于 OpenConnect”弹窗（仿设置页排版：应用信息/开源许可/隐私说明） */
  private showAboutDialog(): void {
    this.aboutCtrl.open();
  }

  /** 服务器下拉选项：已保存历史地址 + 末尾“+ 添加服务器地址” */
  private serverSelectOptions(): Array<SelectOption> {
    const opts: Array<SelectOption> = [];
    for (const a of this.serverHistory) {
      opts.push({ value: a });
    }
    opts.push({ value: this.res($r('app.string.add_new_server')) });
    return opts;
  }

  /** 下拉选择：选历史地址回填并拉用户组；选末尾“添加”项弹出新增弹窗 */
  private onServerSelect(index: number): void {
    if (index >= 0 && index < this.serverHistory.length) {
      this.useServerHistory(this.serverHistory[index]);
    } else if (index >= 0 && index === this.serverHistory.length) {
      this.openAddServerDialog();
    }
  }

  /** 打开“选择服务器地址”弹窗（历史地址列表，可滑动选择/删除） */
  private openServerSelectDialog(): void {
    this.selCtrl = new CustomDialogController({
      builder: ServerSelectDialog({
        items: this.serverHistory.slice(),
        current: this.serverUrl,
        onSelect: (addr: string) => this.useServerHistory(addr),
        onDelete: (addr: string) => this.deleteServer(addr),
        onAdd: () => this.openAddServerDialog()
      }),
      autoCancel: true
    });
    this.selCtrl.open();
  }

  /** 打开“添加服务器地址”弹窗 */
  private openAddServerDialog(): void {
    this.addCtrl = new CustomDialogController({
      builder: AddServerDialog({ onConfirm: (addr: string) => this.addServerConfirmed(addr) }),
      autoCancel: true
    });
    this.addCtrl.open();
  }

  /** 弹窗确认新增：去空、去重、置顶保存并持久化，回填并拉取用户组 */
  private addServerConfirmed(addrRaw: string): void {
    const addr = addrRaw.trim();
    if (!addr) {
      return;
    }
    const next = pushServerHistory(this.serverHistory, addr, 10);
    this.serverHistory = next;
    this.serverUrl = addr;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      prefPutList(context, 'serverHistory', next);
    } catch (e) {
      // 忽略持久化失败
    }
    this.appendLog('已新增服务器地址：' + addr);
    this.fetchServerGroups();
  }

  /** 长按历史地址：弹出删除确认，确认后从历史与持久化中删除 */
  private confirmDeleteServer(addr: string): void {
    promptAction.showDialog({
      title: this.res($r('app.string.delete_server_title')),
      message: this.res($r('app.string.delete_server_msg')) + '\n' + addr,
      buttons: [
        { text: this.res($r('app.string.cancel')), color: '#666666' },
        { text: this.res($r('app.string.delete')), color: '#cf1322' }
      ]
    }).then((res) => {
      if (res.index === 1) {
        this.deleteServer(addr);
      }
    }).catch(() => {
    });
  }

  /** 执行删除历史服务器地址（更新界面并持久化） */
  private async deleteServer(addr: string): Promise<void> {
    const next = this.serverHistory.filter((x) => x !== addr);
    this.serverHistory = next;
    if (this.serverUrl === addr) {
      this.serverUrl = next.length > 0 ? next[0] : '';
    }
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      await prefPutList(context, 'serverHistory', next);
    } catch (e) {
      // 忽略持久化失败
    }
    this.appendLog('已删除服务器地址：' + addr);
  }

  /** 按当前系统语言读取字符串资源（用于 build 之外的运行时文案） */
  private res(id: Resource): string {
    const ctx = this.getUIContext().getHostContext() as common.Context;
    return ctx.resourceManager.getStringSync(id);
  }

  /** 把运行时状态文本翻译为当前系统语言（日志仍保留中文，界面显示本地化） */
  private statusLocale(): string {
    const s = this.statusText;
    if (s === '未连接') return this.res($r('app.string.st_not_connected'));
    if (s === '连接中') return this.res($r('app.string.st_connecting'));
    if (s === '已连接') return this.res($r('app.string.st_connected'));
    if (s === '连接失败') return this.res($r('app.string.st_connect_fail'));
    if (s === '已断开') return this.res($r('app.string.st_disconnected'));
    if (s === '已断开（会话被服务器终止）') return this.res($r('app.string.st_kicked'));
    return s;
  }

  private appendLog(msg: string): void {
    const d = new Date();
    const hh = (d.getHours() < 10 ? '0' : '') + d.getHours();
    const mm = (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
    const ss = (d.getSeconds() < 10 ? '0' : '') + d.getSeconds();
    const line = '[' + hh + ':' + mm + ':' + ss + '] ' + msg;
    this.logText = line + '\n' + this.logText;
    hilog.info(0x0000, 'Index', '%{public}s', msg);
  }

  async connect(): Promise<void> {
    if (this.isConnecting || this.isConnected) {
      return;
    }
    // 本次新连接：重置数据面状态
    this._hadDataPlane = false;
    this.connectedDuration = '';
    this.sessionKicked = false;
    // 每次连接都重新允许 Banner 弹窗（而不是只在首次连接弹一次）
    this._bannerShown = false;
    // 重置用户主动断开标志：否则断开后立即重连时，会话握手循环会因该标志为真被整个
    // 跳过（不会重启扩展），监控读到的是上一次连接的残留状态，造成“假连接→假断开”。
    this._disconnectRequested = false;
    this.isConnecting = true;
    // 兜底：若尚未拉取用户组则先自动获取
    if (this.groupOptions.length === 0) {
      await this.fetchServerGroups();
    }
    // —— 每次连接都从输入框/下拉的当前实时值快照本次连接参数，不使用历史恢复/缓存的旧值 ——
    // 之后校验、写配置文件、传入 want 全部用这份快照，确保不会因后续异步流程被改写。
    const sUrl = this.serverUrl;
    const sUser = this.username;
    const sPass = this.password;
    const sGroup = this.authGroup;
    // 启动扩展前校验必填参数，避免缺失时扩展进程报“参数缺失”这种隐晦失败
    if (!sUrl || sUrl.trim().length === 0) {
      this.appendLog('请填写服务器地址');
      this.isConnecting = false;
      return;
    }
    if (!sUser || sUser.trim().length === 0) {
      this.appendLog('请填写用户名');
      this.isConnecting = false;
      return;
    }
    if (!sPass || sPass.length === 0) {
      this.appendLog('请填写密码');
      this.isConnecting = false;
      return;
    }
    this.appendLog('正在连接 ' + sUrl + ' ...');
    this.appendLog('本次连接使用：地址=' + sUrl + ' 用户=' + sUser + ' 组=' + (sGroup || '（未指定）')
      + ' 密码长度=' + sPass.length);

    try {
      this.statusText = '连接中';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 通过 want.parameters 把连接参数传入 Vpn 扩展进程
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'VpnExtAbility',
        parameters: {
          'serverUrl': sUrl,
          'username': sUser,
          'password': sPass,
          'authGroup': sGroup
        }
      };
      // 连接参数经沙箱配置文件传给扩展进程（与状态文件 oc_vpn_status.txt 同目录同机制，跨进程可靠）。
      // UI 写、扩展读，扩展读取后立即删除该文件，密码不持久化。
      // session 为本次连接的会话令牌：扩展 onCreate 读到后回写 SESSION_START=<id> 到状态文件，
      // UI 据此验证扩展确实以全新实例、本次配置启动（防止复用旧实例导致地址/账号不切换）。
      const sessionId = String(Date.now());
      this._sessionId = sessionId;
      try {
        const cfgPath = context.filesDir + '/oc_vpn_cfg.txt';
        const cfg = 'session=' + sessionId + '\n' +
          'serverUrl=' + sUrl + '\n' +
          'username=' + sUser + '\n' +
          'password=' + sPass + '\n' +
          'authGroup=' + sGroup + '\n';
        // CREATE|TRUNC：文件不存在则创建，已存在则清空重写，一步完成旧值覆盖
        const file = fileIo.openSync(cfgPath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, cfg);
        fileIo.closeSync(file);
        this.appendLog('连接参数已写入配置文件');
      } catch (e) {
        this.appendLog('连接参数写入文件失败: ' + JSON.stringify(e));
      }
      this.appendLog('启动 VPN 扩展（会话握手确认全新实例）...');
      // —— 会话握手：确认扩展为“读取了本次配置的全新实例”，防止复用旧实例导致地址/账号不切换 ——
      // UI 把 session=id 写入配置文件，扩展 onCreate 读到后回写 SESSION_START=id。若在超时内
      // 没看到本次 id 的回复，说明旧实例被系统复用（onCreate 未执行），需 stop 后重试。
      const statusPath = context.filesDir + '/oc_vpn_status.txt';
      const sessionMark = 'SESSION_START=' + this._sessionId;
      let handshakeOk = false;
      for (let attempt = 0; attempt < 4 && !handshakeOk && !this._disconnectRequested; attempt++) {
        // 每次 start 前都先 stop，确保干净启动（避免残留旧实例被复用导致连到上一台服务器）
        if (attempt > 0) {
          this.appendLog('检测到扩展可能复用旧实例，重新 stop+start（第 ' + attempt + ' 次）...');
        }
        try {
          const stopWant: Want = { bundleName: context.abilityInfo.bundleName, abilityName: 'VpnExtAbility' };
          await vpnExtension.stopVpnExtensionAbility(stopWant);
        } catch (e) {
          // 无残留实例时停止会抛错，忽略
        }
        // 给系统留出回收旧实例的时间，降低复用概率
        await new Promise<void>((res) => setTimeout(res, 400));
        try {
          await vpnExtension.startVpnExtensionAbility(want);
        } catch (e) {
          this.appendLog('启动 VPN 扩展失败: ' + JSON.stringify(e));
          break;
        }
        // 等待本次会话令牌回写（首启冷启动+系统授权可能偏慢，放宽到 10s/次）
        const hDeadline = Date.now() + 10000;
        while (Date.now() < hDeadline) {
          const c: string = await this.readStatusFile(statusPath);
          if (c.includes(sessionMark)) {
            handshakeOk = true;
            this.appendLog('扩展已就绪（会话令牌已确认）');
            break;
          }
          // 期间若出现“参数缺失”/连接失败标志，直接结束握手（交由下方监控处理）
          if (c.includes('参数缺失')) {
            break;
          }
          await new Promise<void>((res) => setTimeout(res, 250));
        }
      }
      if (!handshakeOk) {
        this.appendLog('扩展会话握手超时，可能在等待系统授权，继续等待连接结果...');
      }
      this._disconnectRequested = false;

      // 轮询扩展进程写入的沙箱状态文件：先等待连接成功；成功后持续监控数据面，
      // 任一阶段出现结束/失败标志、或心跳超时，都把 UI 刷新为“未连接”。
      const connectDeadline = Date.now() + 120000; // 连接阶段最长等 120s（含用户授权+认证+数据面建立）
      this._disconnectRequested = false;
      for (;;) {
        // 用户已手动断开（disconnect 置位），不再由监控循环改写状态
        if (this._disconnectRequested) {
          break;
        }
        const content: string = await this.readStatusFile(statusPath);
        if (content.length > 0) {
          // 记录最近几行进度
          this.showLatestLines(content);
        }
        if (this.isConnected) {
          // 已进入数据面：实时刷新连接时长
          this.connectedDuration = this.formatDuration(Date.now() - this._connectStartTime);
          // Banner 兜底轮询（幂等）：无论上一轮快照是否已含 BANNER_START，
          // 进入数据面后持续尝试直至弹出，避免竞态导致公告永不显示
          this.checkBanner(content);
          // 检测是否被服务器/网络断开或数据面结束
          if (content.includes('数据面主循环结束') || content.includes('VPN 已关闭')
            || content.includes('VPN 连接已结束')) {
            this.isConnected = false;
            this.isConnecting = false;
            this.connectedDuration = '';
            this.afterDataPlaneClosed(content);
            break;
          }
          if (content.includes('认证/协商失败') || content.includes('创建 VPN 失败')
            || content.includes('create() 异常')) {
            this.isConnected = false;
            this.isConnecting = false;
            this.connectedDuration = '';
            this.afterDataPlaneClosed(content);
            break;
          }
          // 心跳超时兜底：扩展进程疑似被系统回收，数据面实际上已不可用
          if (await this.statusFileStale(statusPath)) {
            this.isConnected = false;
            this.isConnecting = false;
            this.connectedDuration = '';
            this.appendLog('VPN 连接已断开（未收到数据面心跳，进程可能被系统回收）');
            releaseRunningLock();
            break;
          }
        } else {
          // 连接阶段：检测成功/失败
          if (content.includes('认证成功，取得 fd=')) {
            this.isConnected = true;
            this.isConnecting = false;
            this.statusText = '已连接';
            this.vpnTestActive = true;
            this._hadDataPlane = true;
            this._connectStartTime = Date.now();
            this.sessionKicked = false;
            this.appendLog('VPN 已连接，数据面运行中');
            // 连接期间持有后台运行锁，防止误清后台/休眠中断
            await acquireRunningLock();
            // Banner 在连接计时开始（成功进入数据面）时提示，避免认证阶段过早弹出
            this.checkBanner(content);
            // 连接成功后记住服务器地址/用户名/用户组/密码，供下次自动回填
            this.saveLogin();
          } else if (content.includes('数据面主循环结束') || content.includes('VPN 已关闭')) {
            this.isConnected = false;
            this.statusText = '未连接';
            this.appendLog('VPN 连接已结束');
            releaseRunningLock();
            break;
          } else if (content.includes('连接失败') || content.includes('参数缺失')
            || content.includes('未取得 vNIC') || content.includes('认证/协商失败')
            || content.includes('创建 VPN 失败') || content.includes('create() 异常')) {
            this.isConnected = false;
            this.isConnecting = false;
            this.statusText = '连接失败';
            const reason = this.classifyAuthError(content);
            this.appendLog(reason.length > 0 ? reason : 'VPN 连接失败（认证未通过），请检查账号、密码、用户组及服务器地址');
            // 服务器短时风控提示（不禁用按钮，仅引导等待，避免连续快速重试延长限制）
            if (reason.indexOf('账号或密码') >= 0 || content.indexOf('用户名或密码错误') >= 0) {
              this.appendLog('提示：如账号密码确认无误仍频繁失败，多为服务器暂时性限制，请等待 1~2 分钟后再试，不要连续快速重试。');
            }
            releaseRunningLock(); // 立即释放后台运行锁，停止后续动作
            break;
          } else if (Date.now() > connectDeadline) {
            this.isConnected = false;
            this.statusText = '连接失败';
            this.appendLog('VPN 连接超时（120s）');
            break;
          }
        }
        await new Promise<void>((res) => setTimeout(res, 800));
      }
    } catch (e) {
      this.appendLog('启动 VPN 扩展异常: ' + (e as Error).message);
      this.statusText = '连接失败';
    } finally {
      this.isConnecting = false;
    }
    // 连接未建立成功（认证失败/超时/数据面未进入）时，主动停止 VPN 扩展。
    // 否则扩展会常驻，下次 startVpnExtensionAbility 复用旧实例、onCreate 不再触发，
    // 即使改对密码也仍读到本次失败状态报错（需退出 App 才恢复正常）。
    // 连接成功时保持扩展在后台运行数据面，不在此处停止。
    if (!this.isConnected) {
      try {
        const stopCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const stopWant: Want = {
          bundleName: stopCtx.abilityInfo.bundleName,
          abilityName: 'VpnExtAbility'
        };
        await vpnExtension.stopVpnExtensionAbility(stopWant);
      } catch (e) {
        // 停止失败不阻断：下次连接若仍异常再排查
      }
    }
    // connect() 结束：不再自动重连（已取消自动重连功能，失败后由用户手动重新连接）
  }

  /** 读取扩展进程写入的状态文件全部内容 */
  private async readStatusFile(path: string): Promise<string> {
    try {
      return await fileIo.readText(path);
    } catch (e) {
      return '';
    }
  }

  /** 在日志区显示状态文件全部新增行（逐行显示，不丢中间行） */
  private showLatestLines(content: string): void {
    const lines = content.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
    for (const line of lines) {
      // openconnect 内部的 [oc] 日志每次连接总是显示：各次失败原因可能不同，避免被去重遮蔽
      if (line.indexOf('[oc]') === 0) {
        this.appendLog(line);
        continue;
      }
      if (this._seenStatusLines.has(line)) {
        continue;
      }
      this._seenStatusLines.add(line);
      if (line !== this._lastStatusLine) {
        this.appendLog(line);
        this._lastStatusLine = line;
      }
    }
  }

  /** 将毫秒时长格式化为 MM:SS / HH:MM:SS */
  private formatDuration(ms: number): string {
    const totalSec = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const mm = (m < 10 ? '0' : '') + m;
    const ss = (s < 10 ? '0' : '') + s;
    return (h > 0) ? (h + ':' + mm + ':' + ss) : (mm + ':' + ss);
  }

  /** 从 openconnect 日志/状态内容中识别“会话被服务器终止（过期/被踢下线）” */
  private isKickedByServer(content: string): boolean {
    return /forced our session to close|session.*(expired|terminated)|server.*(kick|terminat|disconnect)/i.test(content);
  }

  /** 根据 openconnect 认证/协商日志，识别具体的登录失败原因，返回给用户的中文提示（无法识别返回空串） */
  private classifyAuthError(content: string): string {
    if (/参数缺失/i.test(content)) {
      return '连接失败：连接参数不完整（服务器地址/用户名/密码有缺失），请填全后重试';
    }
    // 服务器限流（AnyLink 对短时间多次登录尝试会返回 429）：此时无论密码对否都会失败，需等待
    if (/429 too many requests|too many requests|rate limit/i.test(content)) {
      return '连接被服务器限流（429 Too Many Requests）：尝试过于频繁，请等待几分钟后再试';
    }
    // 服务器明确返回“账号或密码错误”（含 AnyLink 中文报错）
    if (/用户名或密码错误|账号或密码|login.*(fail|incorrect|error|invalid)|invalid.*(username|password|credential)|authentication failed|bad.*credential/i.test(content)) {
      return '登录失败：账号或密码错误，请核对用户名与密码后重试（服务器返回“用户名或密码错误”）';
    }
    if (/incorrect.*password|wrong.*password|invalid.*password|password.*(incorrect|invalid|mismatch)/i.test(content)) {
      return '登录失败：账号或密码错误，请检查后重试';
    }
    if (/user.*(not exist|not found|no such|unknown)|no such user|user name.*(invalid|incorrect)|account.*(not exist|invalid|disabled|locked)|user disabled/i.test(content)) {
      return '登录失败：账号不存在或已被禁用';
    }
    if (/group.*(not|error|fail|invalid|denied|reject)|authgroup.*(invalid|not)|group.*denied/i.test(content)) {
      return '登录失败：用户组错误或无权访问，请检查所选用户组';
    }
    if (/connection (reset|closed|refused|aborted)|server.*(closed|disconnect|refused)|peer.*closed|network.*(unreachable|error)/i.test(content)) {
      return '连接失败：服务器断开连接或网络异常';
    }
    // 兜底：识别到认证相关错误时，摘取 openconnect 原始错误行原文，便于定位真实原因
    if (/authentication|login|password|token|authorization|error|fail/i.test(content)) {
      const m = /\[oc\]\s*([^\n]*(?:authentication|login|password|token|error|fail)[^\n]*)/i.exec(content);
      const detail = (m && m[1]) ? (' （原日志: ' + m[1].trim() + '）') : '';
      return '登录失败：认证被拒绝（请检查账号、密码、用户组及服务器地址）' + detail;
    }
    return '';
  }

  /** 数据面结束后统一收尾：识别被踢原因并刷新状态 */
  private afterDataPlaneClosed(content: string): void {
    if (this.isKickedByServer(content)) {
      this.sessionKicked = true;
      this.statusText = '已断开（会话被服务器终止）';
      this.appendLog('会话被服务器终止（Session 过期或被踢下线）');
    } else {
      this.sessionKicked = false;
      this.statusText = '已断开';
      this.appendLog('VPN 连接已断开');
    }
    releaseRunningLock();
  }

  /** 记录最近一次显示过的状态行，避免重复刷屏 */
  private _lastStatusLine: string = '';
  /** 已显示过的状态行集合，保证每一行都完整出现一次 */
  private _seenStatusLines: Set<string> = new Set<string>();
  /** 是否已弹出过 Banner 确认框（每次连接只弹一次） */
  private _bannerShown = false;
  /** 用户是否已发起手动断开（断开后监控循环不再改写状态，交由 disconnect 收尾） */
  private _disconnectRequested = false;

  /** 判断状态文件是否超过 15s 无更新（扩展进程心跳停止，疑似进程被系统回收）。
   *  Stat.mtime 单位是秒（Date.now() 为毫秒），需先换算。 */
  private async statusFileStale(path: string): Promise<boolean> {
    try {
      const st = fileIo.statSync(path);
      return (Date.now() - st.mtime * 1000) > 15000;
    } catch (e) {
      return false;
    }
  }

  /** 从状态文件内容中解析服务器下发的 Banner，存在则弹确认框，用户确认后关闭 */
  private checkBanner(content: string): void {
    if (this._bannerShown) {
      return;
    }
    const m = /BANNER_START=([\s\S]*?)=BANNER_END/.exec(content);
    if (!m || !m[1]) {
      return;
    }
    this._bannerShown = true;
    const bannerText = m[1].trim();
    this.appendLog('服务器下发 Banner，等待确认...');
    // 弹窗要求用户确认；确认后关闭
    promptAction.showDialog({
      title: this.res($r('app.string.server_announce')),
      message: bannerText,
      buttons: [
        { text: this.res($r('app.string.got_it')), color: '#0a59f7', primary: true }
      ]
    }).then(() => {
      this.appendLog('用户已确认 Banner');
    }).catch(() => {
      this.appendLog('Banner 弹窗被关闭');
    });
  }

  /** 点击历史地址标签：回填输入框并自动拉取用户组 */
  private useServerHistory(addr: string): void {
    this.serverUrl = addr;
    this.appendLog('使用历史服务器：' + addr);
    this.fetchServerGroups();
  }

  /** 新增地址确定：加入历史并回填、拉取用户组 */
  private async confirmNewServer(): Promise<void> {
    const addr = this.newServerInput.trim();
    if (!addr) {
      this.addingServer = false;
      return;
    }
    const next = pushServerHistory(this.serverHistory, addr, 10);
    this.serverHistory = next;
    this.serverUrl = addr;
    try {
      const context = this.getUIContext().getHostContext() as common.Context;
      await prefPutList(context, 'serverHistory', next);
    } catch (e) {
      // 忽略
    }
    this.newServerInput = '';
    this.addingServer = false;
    this.appendLog('已新增服务器地址：' + addr);
    this.fetchServerGroups();
  }

  /** 从服务器拉取可选用户组，供下拉选择 */
  async fetchServerGroups(): Promise<void> {
    if (!this.serverUrl) {
      this.appendLog('请先填写服务器地址');
      return;
    }
    this.appendLog('正在从服务器拉取用户组...');
    try {
      const task = new taskpool.Task(ocProbeGroups, this.serverUrl);
      const groups: string = await taskpool.execute(task) as string;
      const list = groups.split(',').map((g) => g.trim()).filter((g) => g.length > 0);
      this.groupOptions = list;
      if (list.length > 0) {
        // 默认选中上次保存的用户组；不在列表中则回退到第一个
        const preferredIdx = this.groupOptions.indexOf(this.authGroup);
        this.authGroup = preferredIdx >= 0 ? this.groupOptions[preferredIdx] : list[0];
        this.appendLog('获取到用户组：' + list.join(' / ') + '，默认选中 ' + this.authGroup);
      } else {
        this.appendLog('服务器未返回用户组');
      }
    } catch (e) {
      this.appendLog('拉取用户组失败: ' + JSON.stringify(e));
    }
  }

  async disconnect(): Promise<void> {
    this._disconnectRequested = true; // 让 connect() 的持续监控循环退出，避免其再改写状态
    this.sessionKicked = false;
    this.appendLog('正在断开，通知 VPN 扩展优雅退出...');
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 1) 写命令文件，触发扩展进程内 openconnect 发送 BYE(logout) 给服务器
      const cmdPath = context.filesDir + '/oc_vpn_cmd.txt';
      try {
        const f = fileIo.openSync(cmdPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, 'user_disconnect');
        fileIo.closeSync(f.fd);
        this.appendLog('已发送断开指令，等待服务器确认(BYE)...');
      } catch (e) {
        this.appendLog('写入断开指令失败: ' + (e as Error).message);
      }
      // 2) 等待扩展进程完成数据面退出 + VPN 关闭（最多 8s）
      const statusPath = context.filesDir + '/oc_vpn_status.txt';
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        const content: string = await this.readStatusFile(statusPath);
        if (content.includes('VPN 已关闭') || content.includes('数据面主循环结束')) {
          this.appendLog('扩展进程已完成优雅关闭');
          break;
        }
        await new Promise<void>((res) => setTimeout(res, 300));
      }
      // 3) 最终停止扩展（兜底，确保进程退出、网络恢复）
      const want: Want = {
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'VpnExtAbility'
      };
      await vpnExtension.stopVpnExtensionAbility(want);
      this.appendLog('已停止 VPN 扩展');
    } catch (e) {
      this.appendLog('断开过程异常: ' + (e as Error).message);
    }
    this.isConnected = false;
    this.isConnecting = false;
    this.statusText = '未连接';
    this.vpnTestActive = false;
    this.connectedDuration = '';
    releaseRunningLock();
    this.appendLog('已断开');
  }

  /** 数据面自然结束后自动关闭隧道、恢复网络（避免残留 vNIC 占用） */
  private async autoCloseTunnel(): Promise<void> {
    this.appendLog('数据面已结束，自动关闭隧道...');
    this.isConnected = false;
    this.statusText = '未连接';
    this.vpnTestActive = false;
    releaseRunningLock();
  }

  /** 页面销毁时释放后台运行锁，避免占用电源资源 */
  aboutToDisappear(): void {
    releaseRunningLock();
  }

  /** 复制日志全文到系统剪贴板，方便粘贴给开发者定位 */
  copyLog(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logText);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.appendLog('日志已复制到剪贴板');
    }).catch((e: Error) => {
      this.appendLog('复制日志失败: ' + JSON.stringify(e));
    });
  }

  build() {
    // 响应式适配：手机/折叠屏竖屏为 12 列全宽；折叠屏展开/平板竖屏为 md（8 列居中）；
    // 平板横屏/鸿蒙 PC 为 lg（6 列居中），避免宽屏下拉得太宽。
    GridRow({ columns: 12, gutter: 16 }) {
      GridCol({ span: { xs: 12, sm: 12, md: 8, lg: 6 }, offset: { xs: 0, sm: 0, md: 2, lg: 3 } }) {
      Column({ space: 12 }) {
      Text($r('app.string.app_title')).fontSize(24).fontWeight(FontWeight.Bold).margin({ top: 24 })

      // 服务器地址：点击弹出选择弹窗（历史地址可滑动选择/删除，末尾添加）
      Row() {
        Text(this.serverUrl || this.res($r('app.string.choose_server')))
          .fontSize(15)
          .fontColor(this.serverUrl ? $r('app.color.text_title') : $r('app.color.text_hint'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })
      .borderRadius(8)
      .backgroundColor($r('app.color.textinput_bg'))
      .margin({ top: 16 })
      .onClick(() => this.openServerSelectDialog())
      Select(this.groupOptions.length > 0
        ? this.groupOptions.map((g: string): SelectOption => ({ value: g }))
        : [{ value: this.res($r('app.string.no_group_hint')) }])
        .selected(this.groupOptions.indexOf(this.authGroup) >= 0 ? this.groupOptions.indexOf(this.authGroup) : 0)
        .value(this.serverUrl
          ? (this.authGroup || this.res($r('app.string.group')))
          : this.res($r('app.string.group')))
        .font({ size: 15 })
        .width('100%')
        .height(48)
        .borderRadius(8)
        .backgroundColor($r('app.color.textinput_bg'))
        .onSelect((index: number) => {
          if (index >= 0 && index < this.groupOptions.length) {
            this.authGroup = this.groupOptions[index];
            this.appendLog('已选择用户组：' + this.authGroup);
            this.saveAuthGroup(); // 记住本次选择，下次启动默认选中
          }
        })
      TextInput({ placeholder: $r('app.string.username'), text: this.username })
        .fontSize(15)
        .maxLength(256)
        .height(48)
        .borderRadius(8)
        .backgroundColor($r('app.color.textinput_bg'))
        .onChange((v: string) => this.username = v)
      TextInput({ placeholder: $r('app.string.password'), text: this.password })
        .type(InputType.Password)
        .fontSize(15)
        .maxLength(256)
        .height(48)
        .borderRadius(8)
        .backgroundColor($r('app.color.textinput_bg'))
        .onChange((v: string) => this.password = v)

      Row({ space: 16 }) {
        Button(this.isConnected || this.isConnecting
          ? this.res($r('app.string.disconnect')) : this.res($r('app.string.connect')))
          .fontSize(14)
          .height(40)
          .onClick(() => {
            if (this.isConnected || this.isConnecting) {
              this.disconnect();
            } else {
              this.connect();
            }
          })
      }.margin({ top: 8 })

      Button(this.res($r('app.string.copy_logs')))
        .onClick(() => this.copyLog())
        .margin({ top: 4 })
        .fontSize(14)
        .height(40)

      // 状态与连接时长合并为一行显示
      Text(this.res($r('app.string.status')) + this.statusLocale()
        + (this.isConnected && this.connectedDuration.length > 0 ? ' · ' + this.connectedDuration : ''))
        .fontSize(16)
        .fontColor(this.isConnected ? $r('app.color.connected') : $r('app.color.disconnected'))

      Scroll() {
        Text(this.logText)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .backgroundColor($r('app.color.log_bg'))
      .borderRadius(8)
      .padding(8)
      .margin({ top: 8, bottom: 8 })
      // 页面最底部：进入“关于 OpenConnect”弹窗
      Text(this.res($r('app.string.about_title')))
        .fontSize(12)
        .fontColor($r('app.color.text_link'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
        .onClick(() => this.showAboutDialog())
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .height('100%')
  }
}
