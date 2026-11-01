/*
 * openconnect_bridge.cpp
 *
 * 把 libopenconnect 的核心 API 绑定为 NAPI 模块，供 ArkTS 调用。
 * 交互模式参照官方 Android 移植 (jni.c)：
 *   - openconnect_vpninfo_new() 创建上下文
 *   - 注册 protect_socket / stats / 证书回调
 *   - cmd pipe 用于取消/统计
 *   - openconnect_setup_tun_fd() 注入鸿蒙 VpnManager 提供的隧道 fd
 *
 * 注意：本文件是"可编译的移植起点"。在缺少完整 NDK 标准头文件时，
 * 需先按《移植方案》补齐工具链与第三方库后再编译。
 */
#include "openconnect_bridge.h"
#include "openconnect.h"

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdarg>
#include <unistd.h>
#include <pthread.h>

/* 数据面线程注入的隧道 fd（由 ArkTS 在 onSetupTun 回调中写入） */
int g_injected_tun_fd = -1;

#ifndef LOG_DOMAIN
#define LOG_DOMAIN 0x0000
#endif
#ifndef LOG_TAG
#define LOG_TAG "OCBridge"
#endif

/* 认证凭证缓存：openconnect 无 set_username/set_password API，
 * 认证须在 process_auth_form 回调中把值写入表单字段。 */
static char g_auth_user[256] = {0};
static char g_auth_pass[256] = {0};
static char g_auth_group[256] = {0};
/* 服务器返回的可选用户组列表（逗号分隔），供 UI 下拉选择 */
static char g_auth_groups[16384] = {0};
/* 服务器下发的 Banner（AnyLink 认证阶段 <banner> 或 CSTP X-CSTP-Banner），
 * 连接成功后由界面弹窗展示并要求用户确认。 */
static char g_banner[8192] = {0};

/* 最近一次连接过程的 openconnect 日志缓存（供 ArkTS 读取显示，便于定位） */
#define G_LOG_BUF_SIZE 8192
static char g_log_buf[G_LOG_BUF_SIZE] = {0};
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

namespace {

/* 把 oc_ip_info / 其它结果回传 JS 的工具（简化实现，可直接扩展） */

/* 简单的会话句柄：NAPI 用 external 传给 ArkTS */
oc_session_t *g_session = nullptr;

pthread_mutex_t g_tun_lock = PTHREAD_MUTEX_INITIALIZER;

/* ------------------------------------------------------------
 * openconnect 回调（由数据面线程调用，通过 NAPI 派发给 JS）
 * 说明：NAPI 不允许跨线程直接调用 JS 函数，需用 napi_create_threadsafe_function
 *      或 uv_queue_work。此处给出线程安全回调骨架。
 * ------------------------------------------------------------ */

static void progress_cb(void *privdata, int level, const char *fmt, ...)
{
    (void)privdata;
    char buf[1024] = {0};
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    /* 缓存到日志缓冲，ArkTS 可经 getProgressLog() 读回 */
    pthread_mutex_lock(&g_log_lock);
    size_t used = strnlen(g_log_buf, G_LOG_BUF_SIZE - 1);
    if (used + strlen(buf) + 1 < G_LOG_BUF_SIZE) {
        memcpy(g_log_buf + used, buf, strlen(buf));
        g_log_buf[used + strlen(buf)] = '\n';
        g_log_buf[used + strlen(buf) + 1] = '\0';
        if (strnlen(g_log_buf, G_LOG_BUF_SIZE) >= G_LOG_BUF_SIZE - 1)
            g_log_buf[0] = '\0'; /* 溢出则清空，避免截断错乱 */
    }
    pthread_mutex_unlock(&g_log_lock);

    /* 输出到系统日志，便于 hdc hilog 抓取诊断 */
    OH_LOG_Print(LOG_APP, level >= PRG_DEBUG ? LOG_INFO : LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                 "%{public}s", buf);
}

/* getProgressLog(): string —— 返回最近一次连接过程的 openconnect 日志缓存 */
napi_value GetProgressLog(napi_env env, napi_callback_info info)
{
    napi_value result;
    pthread_mutex_lock(&g_log_lock);
    napi_create_string_utf8(env, g_log_buf, NAPI_AUTO_LENGTH, &result);
    pthread_mutex_unlock(&g_log_lock);
    return result;
}

/* getBanner(): string —— 返回服务器下发的 Banner（无可弹空串） */
napi_value GetBanner(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_string_utf8(env, g_banner, NAPI_AUTO_LENGTH, &result);
    return result;
}

/* 认证表单回调：openconnect 通过它向应用索取并回填用户名/密码。
 * 该回调在 obtain_cookie 的认证流程中被调用；返回 0 表示表单已填完、
 * 可向服务器发起 POST 提交。 */
static int process_auth_form_cb(void *privdata, struct oc_auth_form *form)
{
    (void)privdata;
    int filled = 0;
    int has_user = 0, has_pass = 0;
    /* 捕获服务器下发的 Banner（AnyLink 在认证 complete 的 <banner> 字段携带） */
    if (form->banner && form->banner[0]) {
        strncpy(g_banner, form->banner, sizeof(g_banner) - 1);
        g_banner[sizeof(g_banner) - 1] = '\0';
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "server banner: %{public}s", g_banner);
        /* 同步写入 UI 可见日志缓冲，便于定位 Banner 是否真正拿到 */
        pthread_mutex_lock(&g_log_lock);
        size_t used_b = strnlen(g_log_buf, G_LOG_BUF_SIZE - 1);
        const char *bline = "[banner] 服务器已下发 Banner";
        if (used_b + strlen(bline) + 1 < G_LOG_BUF_SIZE) {
            memcpy(g_log_buf + used_b, bline, strlen(bline));
            g_log_buf[used_b + strlen(bline)] = '\n';
            g_log_buf[used_b + strlen(bline) + 1] = '\0';
        }
        pthread_mutex_unlock(&g_log_lock);
    }
    /* 把表单信息写入日志缓冲，便于界面复制诊断 */
    char line[512];
    pthread_mutex_lock(&g_log_lock);
    snprintf(line, sizeof(line), "[form] id=%s msg=%s err=%s filled-so-far=%d",
             form->auth_id ? form->auth_id : "(null)",
             form->message ? form->message : "(null)",
             form->error ? form->error : "(null)", 0);
    size_t used0 = strnlen(g_log_buf, G_LOG_BUF_SIZE - 1);
    if (used0 + strlen(line) + 1 < G_LOG_BUF_SIZE) {
        memcpy(g_log_buf + used0, line, strlen(line));
        g_log_buf[used0 + strlen(line)] = '\n';
        g_log_buf[used0 + strlen(line) + 1] = '\0';
    }
    pthread_mutex_unlock(&g_log_lock);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "auth form id=%{public}s message=%{public}s error=%{public}s",
                 form->auth_id ? form->auth_id : "(null)",
                 form->message ? form->message : "(null)",
                 form->error ? form->error : "(null)");
    for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "auth opt name=%{public}s type=%d flags=0x%x user=%d pass=%d",
                     opt->name ? opt->name : "(null)", (int)opt->type,
                     (unsigned)opt->flags,
                     opt->name && !strcmp(opt->name, "username"),
                     opt->name && !strcmp(opt->name, "password"));
        pthread_mutex_lock(&g_log_lock);
        snprintf(line, sizeof(line), "[form] opt name=%s type=%d",
                 opt->name ? opt->name : "(null)", (int)opt->type);
        size_t used1 = strnlen(g_log_buf, G_LOG_BUF_SIZE - 1);
        if (used1 + strlen(line) + 1 < G_LOG_BUF_SIZE) {
            memcpy(g_log_buf + used1, line, strlen(line));
            g_log_buf[used1 + strlen(line)] = '\n';
            g_log_buf[used1 + strlen(line) + 1] = '\0';
        }
        pthread_mutex_unlock(&g_log_lock);
        if (!opt->name)
            continue;
        if (!strcmp(opt->name, "username") && g_auth_user[0]) {
            openconnect_set_option_value(opt, g_auth_user);
            has_user = 1;
            filled++;
        } else if (!strcmp(opt->name, "password") && g_auth_pass[0]) {
            openconnect_set_option_value(opt, g_auth_pass);
            has_pass = 1;
            filled++;
        }
    }

    /* 处理 group_list（用户组下拉）：AnyLink 聚合认证必需，否则服务器报"用户组错误"。
     * 同时把服务器返回的全部可选组收集到 g_auth_groups，供 UI 下拉选择。 */
    if (form->authgroup_opt && form->authgroup_opt->nr_choices > 0) {
        struct oc_form_opt_select *grp = form->authgroup_opt;
        int sel = -1;
        int off = 0;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "authgroup: %d choices, selected=%d, wanted=%s",
                     grp->nr_choices, form->authgroup_selection,
                     g_auth_group[0] ? g_auth_group : "(none)");
        g_auth_groups[0] = '\0';
        for (int i = 0; i < grp->nr_choices; i++) {
            const char *nm = grp->choices[i]->name ? grp->choices[i]->name : "(null)";
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "  authgroup choice[%d] name=%{public}s", i, nm);
            /* 收集列表（逗号分隔） */
            int need = strlen(nm) + (off > 0 ? 1 : 0);
            if (off + need < (int)sizeof(g_auth_groups) - 1) {
                if (off > 0)
                    g_auth_groups[off++] = ',';
                memcpy(g_auth_groups + off, nm, strlen(nm));
                off += (int)strlen(nm);
                g_auth_groups[off] = '\0';
            }
            if (!g_auth_group[0])
                continue;
            if (!strcmp(grp->choices[i]->name, g_auth_group))
                sel = i;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "  server groups: %{public}s", g_auth_groups);
        if (sel < 0)
            sel = form->authgroup_selection; /* 用户未匹配时取服务器默认组 */
        if (sel >= 0 && sel < grp->nr_choices && grp->choices[sel]->name) {
            openconnect_set_option_value(&grp->form, grp->choices[sel]->name);
            filled++;
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "  => selected authgroup=%{public}s", grp->choices[sel]->name);
        }
    }
    pthread_mutex_lock(&g_log_lock);
    snprintf(line, sizeof(line), "[form] handled, opts filled=%d", filled);
    used0 = strnlen(g_log_buf, G_LOG_BUF_SIZE - 1);
    if (used0 + strlen(line) + 1 < G_LOG_BUF_SIZE) {
        memcpy(g_log_buf + used0, line, strlen(line));
        g_log_buf[used0 + strlen(line)] = '\n';
        g_log_buf[used0 + strlen(line) + 1] = '\0';
    }
    pthread_mutex_unlock(&g_log_lock);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "auth form handled, opts filled=%d has_user=%d has_pass=%d",
                 filled, has_user, has_pass);
    /* 只有用户名和密码都已填充才提交；否则取消（避免探测时空表单无限 POST） */
    return (has_user && has_pass) ? 0 : 1;
}

/* 证书校验回调：POC 阶段接受任意证书（否则自签名服务器会被拒）。
 * 生产实现应在此校验指纹或把选择权交给用户。 */
static int validate_peer_cert_cb(void *privdata, const char *reason)
{
    (void)privdata;
    OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                 "accepting peer cert (POC): %{public}s", reason ? reason : "");
    return 0; /* 0 = 接受 */
}

static void stats_cb(void *privdata, const struct oc_stats *stats)
{
    oc_session_t *ctx = (oc_session_t *)privdata;
    (void)ctx; (void)stats;
    /* 统计回调：可经线程安全函数回传 ArkTS */
}

static void setup_tun_cb(void *privdata)
{
    oc_session_t *ctx = (oc_session_t *)privdata;
    (void)ctx;
    /* 该回调表示 openconnect 进入数据面、正在等待隧道 fd。
     * 在鸿蒙场景下，由 ArkTS 层通过 VpnManager 建立隧道并回调
     * injectTunFd()。这里需要把事件派发给 JS 层。*/
}

static void reconnected_cb(void *privdata)
{
    (void)privdata;
}

/* ------------------------------------------------------------
 * NAPI 模块方法
 * ------------------------------------------------------------ */

/* getVersion(): string —— 返回 openconnect 版本 */
napi_value GetVersion(napi_env env, napi_callback_info info)
{
    napi_value result;
    const char *v = openconnect_get_version();
    napi_create_string_utf8(env, v ? v : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

/* initSsl(): void —— 初始化 SSL 库 */ 
napi_value InitSsl(napi_env env, napi_callback_info info)
{
    openconnect_init_ssl();
    return nullptr;
}

/* newSession(): number —— 创建会话，返回句柄(此处用 cmd_fd) */
napi_value NewSession(napi_env env, napi_callback_info info)
{
    /* 每次新连接清空上次残留的 Banner，避免显示上一台服务器的旧公告 */
    g_banner[0] = '\0';

    if (g_session) {
        openconnect_vpninfo_free(g_session->vpninfo);
        delete g_session;
        g_session = nullptr;
    }

    oc_session_t *ctx = new oc_session_t();
    memset(ctx, 0, sizeof(*ctx));
    ctx->env = env;

    ctx->vpninfo = openconnect_vpninfo_new(
        "OpenConnect-HarmonyOS", /* UA 按实际系统上报，由服务器匹配（AnyLink 无鸿蒙词则显示 Unknown） */
        validate_peer_cert_cb,  /* validate_peer_cert: POC 阶段接受任意证书 */
        nullptr,                /* write_new_config */
        process_auth_form_cb,   /* process_auth_form: 自动填充用户名/密码 */
        progress_cb,
        ctx);

    openconnect_set_protect_socket_handler(ctx->vpninfo, nullptr);
    openconnect_set_stats_handler(ctx->vpninfo, stats_cb);

    /* 命令管道：mainloop 通过它接收 CANCEL/STATS 等命令 */
    ctx->cmd_fd = openconnect_setup_cmd_pipe(ctx->vpninfo);
    g_session = ctx;

    napi_value result;
    napi_create_int32(env, ctx->cmd_fd, &result);
    return result;
}

/* parseUrl(url: string): int —— 解析服务器 URL */
napi_value ParseUrl(napi_env env, napi_callback_info info)
{
    if (!g_session) {
        napi_value r; napi_create_int32(env, -1, &r); return r;
    }
    size_t argc1 = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc1, argv, nullptr, nullptr);
    char url[1024] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], url, sizeof(url), &len);

    int ret = openconnect_parse_url(g_session->vpninfo, url);
    napi_value r; napi_create_int32(env, ret, &r);
    return r;
}

/* setAuth(username, password) */
napi_value SetAuth(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char user[256] = {0}, pass[256] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], user, sizeof(user), &len);
    napi_get_value_string_utf8(env, argv[1], pass, sizeof(pass), &len);
    /* 保存凭证，供 process_auth_form 回调在认证时填写 */
    strncpy(g_auth_user, user, sizeof(g_auth_user) - 1);
    strncpy(g_auth_pass, pass, sizeof(g_auth_pass) - 1);
    napi_value r; napi_create_int32(env, 0, &r);
    return r;
}

/* setAuthGroup(group: string) —— 设置 AnyLink 用户组 */
napi_value SetAuthGroup(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char group[256] = {0};
    if (argc >= 1 && argv[0]) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], group, sizeof(group), &len);
    }
    strncpy(g_auth_group, group, sizeof(g_auth_group) - 1);
    napi_value r; napi_create_int32(env, 0, &r);
    return r;
}

/* setMobileInfo(platform, deviceType, uniqueId) —— 把操作系统与终端型号上报给服务器
 * 通过 openconnect_set_reported_os("android") + openconnect_set_mobile_info()
 * 写入 AnyConnect 的 X-AnyConnect-Mobile-* 认证头，让服务器看到设备信息。 */
napi_value SetMobileInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char platform[128] = {0}, dtype[128] = {0}, uid[256] = {0};
    if (argc >= 1 && argv[0]) {
        size_t l = 0;
        napi_get_value_string_utf8(env, argv[0], platform, sizeof(platform), &l);
    }
    if (argc >= 2 && argv[1]) {
        size_t l = 0;
        napi_get_value_string_utf8(env, argv[1], dtype, sizeof(dtype), &l);
    }
    if (argc >= 3 && argv[2]) {
        size_t l = 0;
        napi_get_value_string_utf8(env, argv[2], uid, sizeof(uid), &l);
    }

    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }

    /* 以移动端身份上报，触发 AnyConnect 移动设备相关认证头；OS 按实际系统上报，由服务器匹配 */
    openconnect_set_reported_os(g_session->vpninfo, "HarmonyOS");
    openconnect_set_mobile_info(g_session->vpninfo,
                                platform[0] ? platform : "HarmonyOS",
                                dtype[0] ? dtype : "unknown-device",
                                uid[0] ? uid : "0000000000000000");
    napi_value r; napi_create_int32(env, 0, &r);
    return r;
}

/* getServerAuthGroups(): string —— 返回服务器可选用户组列表（逗号分隔） */
napi_value GetServerAuthGroups(napi_env env, napi_callback_info info)
{
    napi_value r;
    napi_create_string_utf8(env, g_auth_groups, NAPI_AUTO_LENGTH, &r);
    return r;
}

/* obtainCookie(): int —— 阻塞执行认证，需在独立线程调用 */
napi_value ObtainCookie(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }
    int ret = openconnect_obtain_cookie(g_session->vpninfo);
    napi_value r; napi_create_int32(env, ret, &r);
    return r;
}

/* makeCstpConnection(): int */
napi_value MakeCstpConnection(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }
    int ret = openconnect_make_cstp_connection(g_session->vpninfo);
    napi_value r; napi_create_int32(env, ret, &r);
    return r;
}

/* IPv4 点分掩码转前缀长度：如 "255.255.0.0" -> 16 */
static int netmask_to_prefix(const char *mask)
{
    if (!mask || !mask[0])
        return 24;
    unsigned a, b, c, d;
    if (sscanf(mask, "%u.%u.%u.%u", &a, &b, &c, &d) != 4)
        return 24;
    uint32_t m = (a << 24) | (b << 16) | (c << 8) | d;
    int p = 0;
    while (p < 32 && (m & (0x80000000U >> p)))
        p++;
    return p;
}

/* getNetworkConfig(): string —— CSTP 协商成功后读取服务器的地址/路由/DNS，
 * 返回 JSON 字符串，供 ArkTS 组建 VpnConfig 实现真实路由下发。 */
napi_value GetNetworkConfig(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &r); return r; }

    const struct oc_ip_info *ip = nullptr;
    const struct oc_vpn_option *cstp = nullptr;
    const struct oc_vpn_option *dtls = nullptr;
    if (openconnect_get_ip_info(g_session->vpninfo, &ip, &cstp, &dtls) < 0 || !ip) {
        napi_value r; napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &r);
        return r;
    }

    /* 拼接 JSON：{"addr":..,"prefix":..,"mtu":..,"dns":[...],"routes":[...]} */
    char buf[4096];
    size_t off = 0;
    int n = snprintf(buf + off, sizeof(buf) - off,
                     "{\"addr\":\"%s\",\"prefix\":%d,\"mtu\":%d,\"dns\":[",
                     ip->addr ? ip->addr : "", netmask_to_prefix(ip->netmask), ip->mtu);
    if (n > 0)
        off += (size_t)n;
    int wrote_dns = 0;
    for (int i = 0; i < 3 && ip->dns[i]; i++) {
        int k = snprintf(buf + off, sizeof(buf) - off, "%s\"%s\"", wrote_dns ? "," : "", ip->dns[i]);
        if (k > 0)
            off += (size_t)k;
        wrote_dns = 1;
    }
    n = snprintf(buf + off, sizeof(buf) - off, "],\"routes\":[");
    if (n > 0)
        off += (size_t)n;
    int wrote_route = 0;
    /* 服务器 split-include 路由可能是 "dest/掩码"（如 192.168.1.1/255.255.255.255），
     * 统一转成 "dest/前缀长度" 的标准 CIDR 输出，供 ArkTS 直接使用。 */
    for (const struct oc_split_include *inc = ip->split_includes; inc; inc = inc->next) {
        const char *route = inc->route ? inc->route : "";
        char dest[64] = {0};
        int plen = 24;
        const char *slash = strchr(route, '/');
        if (slash) {
            size_t dlen = (size_t)(slash - route);
            if (dlen >= sizeof(dest))
                dlen = sizeof(dest) - 1;
            memcpy(dest, route, dlen);
            dest[dlen] = '\0';
            /* 看 '/' 后面是掩码（含 '.'）还是前缀数字 */
            const char *tail = slash + 1;
            if (strchr(tail, '.')) {
                plen = netmask_to_prefix(tail);
            } else {
                char *endp = nullptr;
                long v = strtol(tail, &endp, 10);
                plen = (endp && endp != tail) ? (int)v : 24;
            }
        } else {
            snprintf(dest, sizeof(dest), "%s", route);
        }
        if (dest[0] == '\0')
            strcpy(dest, "0.0.0.0");
        if (plen < 0)
            plen = 0;
        if (plen > 32)
            plen = 32;
        int k = snprintf(buf + off, sizeof(buf) - off, "%s\"%s/%d\"", wrote_route ? "," : "",
                         dest, plen);
        if (k > 0)
            off += (size_t)k;
        wrote_route = 1;
    }
    n = snprintf(buf + off, sizeof(buf) - off, "]}");
    if (n > 0)
        off += (size_t)n;

    napi_value r; napi_create_string_utf8(env, buf, NAPI_AUTO_LENGTH, &r);
    return r;
}

/* injectTunFd(fd: number): int —— ArkTS 建立 VPN 隧道后注入 fd */
napi_value InjectTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd;
    napi_get_value_int32(env, argv[0], &fd);

    pthread_mutex_lock(&g_tun_lock);
    g_injected_tun_fd = fd;
    pthread_mutex_unlock(&g_tun_lock);

    int ret = -1;
    if (g_session && fd >= 0) {
        ret = openconnect_setup_tun_fd(g_session->vpninfo, fd);
    }
    napi_value r; napi_create_int32(env, ret, &r);
    return r;
}

/* setupDtls(): int */
napi_value SetupDtls(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }
    int ret = openconnect_setup_dtls(g_session->vpninfo, 0);
    napi_value r; napi_create_int32(env, ret, &r);
    return r;
}

/* mainloop(dtls: bool): int —— 阻塞；须在 worker 线程调用 */
napi_value Mainloop(napi_env env, napi_callback_info info)
{
    if (!g_session) { napi_value r; napi_create_int32(env, -1, &r); return r; }
    openconnect_mainloop(g_session->vpninfo, -1, -1);
    g_session->connected = 0;
    napi_value r; napi_create_int32(env, 0, &r);
    return r;
}

/* cancel(): void —— 向 cmd pipe 写取消命令 */
napi_value Cancel(napi_env env, napi_callback_info info)
{
    if (g_session && g_session->cmd_fd >= 0) {
        const char cmd = OC_CMD_CANCEL;
        (void)write(g_session->cmd_fd, &cmd, 1);
    }
    return nullptr;
}

/* requestStats() */
napi_value RequestStats(napi_env env, napi_callback_info info)
{
    if (g_session && g_session->cmd_fd >= 0) {
        const char cmd = OC_CMD_STATS;
        (void)write(g_session->cmd_fd, &cmd, 1);
    }
    return nullptr;
}

/* freeSession() */
napi_value FreeSession(napi_env env, napi_callback_info info)
{
    if (g_session) {
        openconnect_vpninfo_free(g_session->vpninfo);
        delete g_session;
        g_session = nullptr;
    }
    return nullptr;
}

/* ------------------------------------------------------------
 * NAPI 注册
 * ------------------------------------------------------------ */
napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"getVersion", nullptr, GetVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initSsl", nullptr, InitSsl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"newSession", nullptr, NewSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseUrl", nullptr, ParseUrl, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAuth", nullptr, SetAuth, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setAuthGroup", nullptr, SetAuthGroup, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMobileInfo", nullptr, SetMobileInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getServerAuthGroups", nullptr, GetServerAuthGroups, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"obtainCookie", nullptr, ObtainCookie, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"makeCstpConnection", nullptr, MakeCstpConnection, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getNetworkConfig", nullptr, GetNetworkConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"injectTunFd", nullptr, InjectTunFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setupDtls", nullptr, SetupDtls, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mainloop", nullptr, Mainloop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestStats", nullptr, RequestStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"freeSession", nullptr, FreeSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getProgressLog", nullptr, GetProgressLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBanner", nullptr, GetBanner, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} /* anonymous namespace */

static napi_module openconnect_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "openconnect",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterOpenConnectModule(void)
{
    napi_module_register(&openconnect_module);
}
