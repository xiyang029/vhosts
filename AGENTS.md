# vhosts 项目开发说明

## 项目概览

- 这是一个 Flutter 多平台工程，包名为 `vhosts`。
- 自定义 hosts、DNS 和 VPN 数据面目前只在 Android 实现；Flutter、iOS、macOS、Windows、Linux、Web 共享界面，但非 Android 平台不会真正建立 DNS VPN。
- Android 原生实现使用 Kotlin，入口位于 `android/app/src/main/kotlin/com/xiyang/vhosts/`。
- Dart 代码按 `app`、`core`、`features`、`shared` 分层，优先沿用现有结构，不要为了小改动引入新的状态管理或网络库。

## 常用命令

在仓库根目录执行：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

修改 Android 原生代码后，至少运行 `flutter analyze` 和相关 Android 构建；修改 DNS 数据面时还应在 Android 设备或模拟器上做实际 DNS 查询验证。

## 自定义 hosts / DNS 链路

1. `lib/features/hosts` 和 `lib/features/dns` 提供编辑、启停和导入 UI。
2. `lib/app/app_state.dart` 保存 `HostRule`、`DnsProfile`，通过 `vhosts/app` 在 Android SharedPreferences 中持久化。
3. `AppState.startVpn()` 通过 `lib/core/platform/dns_vpn_platform_service.dart` 的 `vhosts/dns` MethodChannel 传递 profile JSON 和 hosts JSON。
4. `android/.../MainActivity.kt` 接收 MethodChannel，申请 `VpnService` 权限，并启动 `DnsVpnService`；状态通过 `vhosts/dns/events` EventChannel 回传 Flutter。
5. `DnsVpnService` 建立 TUN 接口，仅添加本地 IPv4/IPv6 DNS 地址和对应的 `/32`、`/128` 路由，读取 UDP/53 数据包并回写 DNS 响应。
6. `DnsTransport.resolve()` 先按 exact/suffix 规则匹配 hosts；匹配成功且查询类型与目标 IP 家族一致时直接合成响应，否则按配置访问 Plain DNS、DoH 或 DoT 上游。

## hosts 规则约定

- `exact` 只匹配完整域名。
- `suffix` 由 `*.example.com` 表示，只匹配其子域，不匹配根域本身。
- 目标地址必须是数字 IPv4 或 IPv6 地址。
- A 查询只接受 IPv4 目标，AAAA 查询只接受 IPv6 目标；不匹配时会继续访问上游。
- 规则按列表顺序使用第一条命中的启用规则。

## IPv6 支持边界

- 已实现 IPv6 DNS 入口：VPN 配置 `fd00:7654:6e73::1/128`，并解析 IPv6 UDP/53 查询。
- 已实现 hosts 的 AAAA 静态响应，使用 `Inet6Address` 和 DNS 类型 `28`。
- 上游地址解析可返回 IPv6 地址，Plain DNS 使用 UDP，DoH/DoT 使用 TCP/TLS。
- 这不是完整的 IPv6 全流量 VPN 或 IPv6 代理：当前只路由两个本地 DNS 地址，不转发普通 IPv4/IPv6 流量。
- IPv6 包处理按固定基础头解析，只接受 `Next Header == UDP`；带 IPv6 扩展头的 DNS 包、TCP DNS、DNS 分片和普通业务流量目前不在实现范围内。

## 修改注意事项

- 保持 Dart/Kotlin 的 JSON 字段名同步，尤其是 `matchType`、`targetIp`、`secondaryServer`、`dotHostname`、`timeoutMs` 和 `retryCount`。
- 上游 DNS socket 在 VPN 内运行时必须调用 `VpnService.protect()`，否则可能形成回环；Plain UDP 和 DoH/DoT TCP 都要保持这一约束。
- 不要把 `addRoute()` 改成默认路由，除非同时实现完整 IP 转发，否则会丢弃非 DNS 流量。
- 新增 DNS 包逻辑时补充 DNS 报文、A/AAAA、hosts 优先级和 IPv4/IPv6 UDP 回包校验；当前测试目录覆盖有限，不能替代设备验证。
- 工作区可能存在用户生成的锁文件或平台生成文件变更。除非任务明确要求，不要回滚与当前任务无关的变更。

