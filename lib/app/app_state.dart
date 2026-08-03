import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/platform/app_storage_platform_service.dart';
import '../core/platform/dns_vpn_platform_service.dart';
import '../core/platform/vpn_status.dart';
import '../features/dns/domain/dns_profile.dart';
import '../features/hosts/domain/host_rule.dart';

const String aliyunDefaultDnsProfileId = 'dp_default_alidns';

const Set<String> _protectedDnsProfileIds = <String>{aliyunDefaultDnsProfileId};

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

List<DnsProfile> _defaultDnsProfiles() => const [_aliyunDefaultDnsProfile];

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
    _vpnStateSubscription = DnsVpnPlatformService.statusStream.listen(
      _applyVpnState,
      onError: (_) {},
    );
  }

  VpnStatus _vpnStatus;
  bool _vpnAuthorized = false;
  List<HostRule> _hostRules;
  List<DnsProfile> _dnsProfiles;
  StreamSubscription<String>? _vpnStateSubscription;
  bool _disposed = false;

  VpnStatus get vpnStatus => _vpnStatus;
  bool get vpnAuthorized => _vpnAuthorized;
  UnmodifiableListView<HostRule> get hostRules =>
      UnmodifiableListView(_hostRules);
  UnmodifiableListView<DnsProfile> get dnsProfiles =>
      UnmodifiableListView(_dnsProfiles);
  bool isProtectedDnsProfile(String id) {
    return _protectedDnsProfileIds.contains(id);
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
    final raw = await AppStoragePlatformService.load();
    if (raw == null || raw.trim().isEmpty) {
      _setDefaultConfiguration();
      unawaited(_persist());
      notifyListeners();
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Invalid root payload');
      }

      final root = Map<String, dynamic>.from(decoded);
      final hostRulesJson = root['hostRules'] as List<dynamic>;
      final dnsProfilesJson = root['dnsProfiles'] as List<dynamic>;
      _hostRules = hostRulesJson
          .map(
            (item) => HostRule.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
      final storedProfiles = dnsProfilesJson
          .map(
            (item) =>
                DnsProfile.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .where((profile) => !isProtectedDnsProfile(profile.id));
      _dnsProfiles = [..._defaultDnsProfiles(), ...storedProfiles];
      _normalizeActiveDnsProfiles();
    } catch (_) {
      _setDefaultConfiguration();
    }

    unawaited(_persist());
    notifyListeners();
  }

  Future<bool> requestVpnPermission() async {
    final granted = await DnsVpnPlatformService.requestPermission();
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
    final started = await DnsVpnPlatformService.start(
      profile: activeDnsProfile,
      hostRules: _hostRules,
    );
    if (!started) {
      _setVpnStatus(VpnStatus.error);
    }
  }

  Future<void> stopVpn() async {
    _setVpnStatus(VpnStatus.stopping);
    if (!await DnsVpnPlatformService.stop()) {
      _setVpnStatus(VpnStatus.error);
    }
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
      selectedId: profile.enabled ? profile.id : null,
    );
    unawaited(_persist());
    notifyListeners();
  }

  void setActiveDnsProfile(String id) {
    _normalizeActiveDnsProfiles(selectedId: id);
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
    _normalizeActiveDnsProfiles();
    unawaited(_persist());
    notifyListeners();
  }

  Future<DnsTestResult?> testDnsProfile(String id) async {
    final index = _dnsProfiles.indexWhere((profile) => profile.id == id);
    if (index < 0) {
      return null;
    }

    return DnsVpnPlatformService.test(_dnsProfiles[index]);
  }

  HostMatchType _matchTypeForDomain(String domain) {
    if (domain.startsWith('*.')) {
      return HostMatchType.suffix;
    }
    return HostMatchType.exact;
  }

  void _normalizeActiveDnsProfiles({String? selectedId}) {
    if (_dnsProfiles.isEmpty) {
      return;
    }

    final activeId =
        selectedId ??
        _dnsProfiles
            .firstWhere(
              (profile) => profile.enabled,
              orElse: () => _dnsProfiles.first,
            )
            .id;
    _dnsProfiles = _dnsProfiles
        .map((profile) => profile.copyWith(enabled: profile.id == activeId))
        .toList(growable: false);
  }

  Future<void> _persist() async {
    final appStateJson = jsonEncode(<String, dynamic>{
      'hostRules': _hostRules
          .map((rule) => rule.toJson())
          .toList(growable: false),
      'dnsProfiles': _dnsProfiles
          .where((profile) => !isProtectedDnsProfile(profile.id))
          .map((profile) => profile.toJson())
          .toList(growable: false),
    });
    await AppStoragePlatformService.save(appStateJson);
  }

  void _setDefaultConfiguration() {
    _hostRules = const <HostRule>[];
    _dnsProfiles = _defaultDnsProfiles();
  }

  void _applyVpnState(String state) {
    if (_disposed) {
      return;
    }

    final previousAuthorized = _vpnAuthorized;
    final previousStatus = _vpnStatus;

    if (state == 'started') {
      _vpnAuthorized = true;
      _vpnStatus = VpnStatus.running;
    } else if (state == 'starting') {
      _vpnAuthorized = true;
      _vpnStatus = VpnStatus.starting;
    } else if (state == 'stopping') {
      _vpnStatus = VpnStatus.stopping;
    } else if (state == 'error') {
      _vpnStatus = VpnStatus.error;
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

const DnsProfile _aliyunDefaultDnsProfile = DnsProfile(
  id: aliyunDefaultDnsProfileId,
  name: '阿里云 DNS',
  type: DnsProfileType.doh,
  server: 'https://dns.alidns.com/dns-query',
  secondaryServer: '',
  dotHostname: '',
  timeoutMs: 1500,
  retryCount: 2,
  enabled: true,
);
