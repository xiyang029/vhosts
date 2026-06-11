import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/platform/vpn_platform_service.dart';
import '../core/platform/vpn_status.dart';
import '../features/dns/domain/dns_profile.dart';
import '../features/hosts/domain/host_rule.dart';
import '../shared/utils/app_utils.dart';

const String _systemDnsProfileId = 'dp_fallback';
const String aliyunDefaultDnsProfileId = 'dp_default_alidns';
const String googleDefaultDnsProfileId = 'preset_google_public_dns';
const String cloudflareDefaultDnsProfileId = 'preset_cloudflare_public_dns';
const Set<String> quickSwitchDnsProfileIds = {
  aliyunDefaultDnsProfileId,
  googleDefaultDnsProfileId,
  cloudflareDefaultDnsProfileId,
};

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({
    super.key,
    required AppState super.notifier,
    required super.child,
  });

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!.notifier!;
  }
}

List<DnsProfile> _defaultDnsProfiles() => [
  _aliyunDefaultDnsProfile,
  _systemDnsProfile.copyWith(enabled: false),
];

String? _activeDnsProfileId(Iterable<DnsProfile> profiles) {
  for (final profile in profiles) {
    if (profile.enabled) {
      return profile.id;
    }
  }
  return null;
}

List<T> _replaceOrPrepend<T>(
  List<T> items,
  bool Function(T item) matches,
  T value,
) {
  final index = items.indexWhere(matches);
  if (index < 0) {
    return [value, ...items];
  }

  final next = [...items];
  next[index] = value;
  return next;
}

class AppState extends ChangeNotifier {
  AppState()
    : _vpnStatus = VpnStatus.idle,
      _hostRules = const <HostRule>[],
      _dnsProfiles = _defaultDnsProfiles() {
    _vpnStateSubscription = VpnPlatformService.stateEvents().listen(
      _applyVpnState,
      onError: (_) {},
    );
  }

  VpnStatus _vpnStatus;
  bool _vpnAuthorized = false;
  bool _allowIpv6 = true;
  List<HostRule> _hostRules;
  List<DnsProfile> _dnsProfiles;
  StreamSubscription<VpnPlatformState>? _vpnStateSubscription;
  bool _disposed = false;

  VpnStatus get vpnStatus => _vpnStatus;
  bool get vpnAuthorized => _vpnAuthorized;
  bool get allowIpv6 => _allowIpv6;
  UnmodifiableListView<HostRule> get hostRules =>
      UnmodifiableListView(_hostRules);
  UnmodifiableListView<DnsProfile> get dnsProfiles =>
      UnmodifiableListView(_dnsProfiles);
  UnmodifiableListView<DnsProfile> get visibleDnsProfiles =>
      UnmodifiableListView(
        _dnsProfiles.where((profile) => profile.id != _systemDnsProfileId),
      );

  bool isProtectedDnsProfile(String id) {
    return id == _systemDnsProfileId || id == aliyunDefaultDnsProfileId;
  }

  DnsProfile get activeDnsProfile {
    if (_dnsProfiles.isEmpty) {
      throw StateError('No DNS profiles available');
    }

    return _dnsProfiles.firstWhere(
      (profile) => profile.enabled,
      orElse: () => _dnsProfiles.first,
    );
  }

  Future<void> toggleVpn() async {
    if (_vpnStatus.isTransitioning) {
      return;
    }

    if (_vpnStatus == VpnStatus.running) {
      await stopVpn();
      return;
    }

    if (!_vpnAuthorized) {
      final granted = await requestVpnPermission();
      if (!granted) {
        _vpnStatus = VpnStatus.unauthorized;
        notifyListeners();
        return;
      }
    }

    await startVpn();
  }

  Future<void> hydrate() async {
    final raw = await VpnPlatformService.loadAppState();
    if (raw == null || raw.trim().isEmpty) {
      _resetToDefaultConfiguration();
      unawaited(syncNativeVpnConfiguration());
      notifyListeners();
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid root payload');
      }

      final root = Map<String, dynamic>.from(decoded);
      final hostRulesJson = root['hostRules'];
      final dnsProfilesJson = root['dnsProfiles'];
      final allowIpv6 = root['allowIpv6'];
      final activeDnsProfileId = stringValue(root['activeDnsProfileId']);

      if (hostRulesJson is List) {
        _hostRules = hostRulesJson
            .whereType<Map>()
            .map((item) => HostRule.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false);
      }

      _dnsProfiles = dnsProfilesJson is List
          ? [
              _aliyunDefaultDnsProfile,
              ...dnsProfilesJson
                  .whereType<Map>()
                  .map(
                    (item) =>
                        DnsProfile.fromJson(Map<String, dynamic>.from(item)),
                  )
                  .where((profile) => !isProtectedDnsProfile(profile.id)),
              _systemDnsProfile.copyWith(enabled: false),
            ]
          : _defaultDnsProfiles();

      if (allowIpv6 is bool) {
        _allowIpv6 = allowIpv6;
      }

      _normalizeActiveDnsProfiles(
        preferredId: activeDnsProfileId.isEmpty ? null : activeDnsProfileId,
      );
    } catch (_) {
      _resetToDefaultConfiguration();
    }

    unawaited(syncNativeVpnConfiguration());
    notifyListeners();
  }

  Future<bool> requestVpnPermission() async {
    final granted = await VpnPlatformService.requestPermission();
    _vpnAuthorized = granted;
    if (granted && _vpnStatus == VpnStatus.unauthorized) {
      _vpnStatus = VpnStatus.idle;
    } else if (!granted) {
      _vpnStatus = VpnStatus.unauthorized;
    }
    notifyListeners();
    return granted;
  }

  Future<void> startVpn() async {
    if (!_vpnAuthorized) {
      _vpnStatus = VpnStatus.unauthorized;
      notifyListeners();
      return;
    }

    _setVpnStatus(VpnStatus.starting);
    final started = await VpnPlatformService.startVpn(
      _buildConfigurationJson(),
    );
    if (!started) {
      _vpnAuthorized = false;
      _setVpnStatus(VpnStatus.unauthorized);
    }
  }

  Future<void> stopVpn() async {
    _setVpnStatus(VpnStatus.stopping);
    final stopped = await VpnPlatformService.stopVpn();
    if (!stopped) {
      _setVpnStatus(VpnStatus.error);
    }
  }

  void setAllowIpv6(bool value) {
    _allowIpv6 = value;
    unawaited(_persist());
    notifyListeners();
  }

  void upsertHostRule(HostRule rule) {
    _hostRules = _replaceOrPrepend(
      _hostRules,
      (item) => item.id == rule.id,
      rule,
    );
    unawaited(_persist());
    notifyListeners();
  }

  void deleteHostRule(String id) {
    _hostRules = _hostRules
        .where((rule) => rule.id != id)
        .toList(growable: false);
    unawaited(_persist());
    notifyListeners();
  }

  void setHostRuleEnabled(String id, bool enabled) {
    final index = _hostRules.indexWhere((rule) => rule.id == id);
    if (index < 0) {
      return;
    }
    _hostRules[index] = _hostRules[index].copyWith(
      enabled: enabled,
      updatedAt: DateTime.now(),
    );
    unawaited(_persist());
    notifyListeners();
  }

  int importHostsText(String text) {
    final now = DateTime.now();
    final importedRules = <HostRule>[];

    for (final rawLine in text.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }

      final parts = line
          .split(RegExp(r'\s+'))
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      if (parts.length < 2) {
        continue;
      }

      final ip = parts.first;
      for (final domain in parts.skip(1)) {
        importedRules.add(
          HostRule(
            id: 'hr_${now.microsecondsSinceEpoch}_${importedRules.length + 1}',
            domain: domain,
            matchType: _matchTypeForDomain(domain),
            targetIp: ip,
            enabled: true,
            note: '',
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
    }

    if (importedRules.isNotEmpty) {
      _hostRules = [...importedRules, ..._hostRules];
      unawaited(_persist());
      notifyListeners();
    }

    return importedRules.length;
  }

  void upsertDnsProfile(DnsProfile profile) {
    if (isProtectedDnsProfile(profile.id)) {
      return;
    }
    _dnsProfiles = _replaceOrPrepend(
      _dnsProfiles,
      (item) => item.id == profile.id,
      profile,
    );
    _normalizeActiveDnsProfiles(
      preferredId: profile.enabled ? profile.id : null,
    );
    unawaited(_persist());
    notifyListeners();
  }

  void setActiveDnsProfile(String id) {
    _normalizeActiveDnsProfiles(preferredId: id);
    unawaited(_persist());
    notifyListeners();
  }

  void deleteDnsProfile(String id) {
    if (isProtectedDnsProfile(id)) {
      return;
    }
    _dnsProfiles = _dnsProfiles
        .where((profile) => profile.id != id)
        .toList(growable: false);
    if (!_dnsProfiles.any((profile) => profile.id == _systemDnsProfileId)) {
      _dnsProfiles = [
        _systemDnsProfile.copyWith(enabled: false),
        ..._dnsProfiles,
      ];
    }
    _normalizeActiveDnsProfiles();
    unawaited(_persist());
    notifyListeners();
  }

  Future<int?> testDnsProfile(String id) async {
    final index = _dnsProfiles.indexWhere((profile) => profile.id == id);
    if (index < 0) {
      return null;
    }

    final profile = _dnsProfiles[index];
    final result = await VpnPlatformService.testDnsProfile(
      profile.toJson(),
      allowIpv6: _allowIpv6,
    );
    final nextStatus = enumByName(
      DnsHealthStatus.values,
      stringValue(result['healthStatus'], DnsHealthStatus.unknown.name),
      DnsHealthStatus.unknown,
    );
    final detail = stringValue(
      result['healthDetail'],
      _resolveHealthDetail(profile, nextStatus),
    );
    final elapsedMs = nullableIntValue(result['latencyMs']);

    _dnsProfiles[index] = profile.copyWith(
      healthStatus: nextStatus,
      healthDetail: detail,
      latencyMs: elapsedMs,
    );
    notifyListeners();
    return elapsedMs;
  }

  Future<void> syncNativeVpnConfiguration() async {
    await VpnPlatformService.saveConfiguration(_buildConfigurationJson());
  }

  String _buildConfigurationJson() {
    final activeDnsProfileId = _activeDnsProfileId(_dnsProfiles);
    final payload = <String, dynamic>{
      'allowIpv6': _allowIpv6,
      'activeDnsProfileId': activeDnsProfileId,
      'hostRules': _hostRules
          .map((rule) => rule.toJson())
          .toList(growable: false),
      'dnsProfiles': _dnsProfiles
          .where((profile) => !isProtectedDnsProfile(profile.id))
          .map((profile) => profile.toJson())
          .toList(growable: false),
    };
    return jsonEncode(payload);
  }

  HostMatchType _matchTypeForDomain(String domain) {
    if (domain.startsWith('*.')) {
      return HostMatchType.suffix;
    }
    if (domain.contains('*')) {
      return HostMatchType.wildcard;
    }
    return HostMatchType.exact;
  }

  void _normalizeActiveDnsProfiles({String? preferredId}) {
    if (_dnsProfiles.isEmpty) {
      return;
    }

    final activeId =
        preferredId ??
        _activeDnsProfileId(_dnsProfiles) ??
        _dnsProfiles.first.id;
    _dnsProfiles = _dnsProfiles
        .map((profile) => profile.copyWith(enabled: profile.id == activeId))
        .toList(growable: false);
  }

  Future<void> _persist() async {
    await VpnPlatformService.saveAppState(_buildConfigurationJson());
    await syncNativeVpnConfiguration();
  }

  void _resetToDefaultConfiguration() {
    _hostRules = const <HostRule>[];
    _dnsProfiles = _defaultDnsProfiles();
    _allowIpv6 = true;
  }

  String _resolveHealthDetail(DnsProfile profile, DnsHealthStatus status) {
    return switch (status) {
      DnsHealthStatus.healthy => '${profile.name} 连接成功，最近一次测试耗时较短',
      DnsHealthStatus.degraded => '${profile.name} 可用，但响应波动较大',
      DnsHealthStatus.offline => '${profile.name} 当前不可用，请检查服务器或网络',
      DnsHealthStatus.unknown => '${profile.name} 跟随系统网络配置',
    };
  }

  void _applyVpnState(VpnPlatformState state) {
    if (_disposed) {
      return;
    }

    final previousAuthorized = _vpnAuthorized;
    final previousStatus = _vpnStatus;

    _vpnAuthorized = state.authorized;
    if (!state.authorized) {
      _vpnStatus = VpnStatus.unauthorized;
    } else if (state.running) {
      _vpnStatus = VpnStatus.running;
    } else {
      _vpnStatus = VpnStatus.idle;
    }

    if (_vpnAuthorized != previousAuthorized || _vpnStatus != previousStatus) {
      notifyListeners();
    }
  }

  void _setVpnStatus(VpnStatus status) {
    if (_disposed) {
      return;
    }

    if (_vpnStatus == status) {
      return;
    }

    _vpnStatus = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_vpnStateSubscription?.cancel());
    super.dispose();
  }
}

const DnsProfile _systemDnsProfile = DnsProfile(
  id: _systemDnsProfileId,
  name: 'System DNS',
  type: DnsProfileType.system,
  server: 'System',
  secondaryServer: '',
  dohUrl: '',
  dotHostname: '',
  timeoutMs: 2500,
  retryCount: 1,
  enabled: true,
  healthStatus: DnsHealthStatus.unknown,
  healthDetail: '跟随系统网络配置',
  latencyMs: null,
);

const DnsProfile _aliyunDefaultDnsProfile = DnsProfile(
  id: aliyunDefaultDnsProfileId,
  name: '阿里云 DNS',
  type: DnsProfileType.plain,
  server: '223.5.5.5:53',
  secondaryServer: '223.6.6.6:53',
  dohUrl: '',
  dotHostname: '',
  timeoutMs: 1500,
  retryCount: 2,
  enabled: true,
  healthStatus: DnsHealthStatus.unknown,
  healthDetail: '国内网络更稳，作为默认推荐',
  latencyMs: null,
);
