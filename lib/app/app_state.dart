import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_singbox_client/flutter_singbox_client.dart';

import '../core/platform/app_storage_platform_service.dart';
import '../core/platform/vpn_status.dart';
import '../features/dns/domain/dns_profile.dart';
import '../features/hosts/domain/host_rule.dart';
import '../shared/utils/app_utils.dart';

const String aliyunDefaultDnsProfileId = 'dp_default_alidns';

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

List<DnsProfile> _defaultDnsProfiles() => [_aliyunDefaultDnsProfile];

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
    try {
      _vpnStateSubscription = _singboxClient.serviceStateStream.listen(
        _applySingboxState,
        onError: (_) {},
      );
    } on StateError {
      // The plugin is initialized before AppState in the Android entrypoint.
    }
  }

  static final SingboxClient _singboxClient = SingboxClient();

  VpnStatus _vpnStatus;
  bool _vpnAuthorized = false;
  bool _allowIpv6 = true;
  List<HostRule> _hostRules;
  List<DnsProfile> _dnsProfiles;
  StreamSubscription<ServiceState>? _vpnStateSubscription;
  bool _disposed = false;

  VpnStatus get vpnStatus => _vpnStatus;
  bool get vpnAuthorized => _vpnAuthorized;
  bool get allowIpv6 => _allowIpv6;
  UnmodifiableListView<HostRule> get hostRules =>
      UnmodifiableListView(_hostRules);
  UnmodifiableListView<DnsProfile> get dnsProfiles =>
      UnmodifiableListView(_dnsProfiles);
  bool isProtectedDnsProfile(String id) {
    return id == aliyunDefaultDnsProfileId;
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
      _resetToDefaultConfiguration();
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

    unawaited(_persist());
    notifyListeners();
  }

  Future<bool> requestVpnPermission() async {
    final granted = await _requestSingboxPermission();
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
    final configurationJson = _buildConfigurationJson();
    try {
      await _singboxClient.checkConfig(configurationJson);
    } on PlatformException {
      _setVpnStatus(VpnStatus.error);
      return;
    }
    try {
      await _singboxClient.connect(
        SessionOptions(
          config: configurationJson,
          networkMode: NetworkMode.vpn,
          notification: const NotificationConfig(
            title: 'vhosts',
            channelName: 'vhosts VPN',
            showStopButton: true,
            stopButtonLabel: '断开',
          ),
        ),
      );
    } on PlatformException {
      _setVpnStatus(VpnStatus.error);
    }
  }

  Future<void> stopVpn() async {
    _setVpnStatus(VpnStatus.stopping);
    try {
      await _singboxClient.disconnect();
    } on PlatformException {
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
    var valid = false;
    try {
      await _singboxClient.checkConfig(
        _buildConfigurationJson(activeProfileOverride: profile),
      );
      valid = true;
    } on PlatformException {
      valid = false;
    }
    final nextStatus = valid
        ? DnsHealthStatus.healthy
        : DnsHealthStatus.offline;
    final detail = valid
        ? '${profile.name} 配置已通过 sing-box 核心校验'
        : '${profile.name} 配置未通过 sing-box 核心校验，请检查服务器地址';
    const int? elapsedMs = null;

    _dnsProfiles[index] = profile.copyWith(
      healthStatus: nextStatus,
      healthDetail: detail,
      latencyMs: elapsedMs,
    );
    notifyListeners();
    return elapsedMs;
  }

  String _buildConfigurationJson({DnsProfile? activeProfileOverride}) {
    final activeDnsProfileId = _activeDnsProfileId(_dnsProfiles);
    final activeProfile =
        activeProfileOverride ??
        _dnsProfiles.firstWhere(
          (profile) => profile.id == activeDnsProfileId,
          orElse: () => _dnsProfiles.first,
        );
    final primaryServer = _dnsServerForProfile(
      activeProfile,
      tag: 'vhosts-dns-primary',
    );
    final secondaryServer = _secondaryDnsServerForProfile(activeProfile);
    final dnsServers = <Map<String, dynamic>>[
      if (_serverNeedsBootstrapResolver(primaryServer))
        <String, dynamic>{'type': 'local', 'tag': 'vhosts-bootstrap'},
      primaryServer,
      ...?(secondaryServer == null
          ? null
          : <Map<String, dynamic>>[secondaryServer]),
    ];
    final dnsRules = <Map<String, dynamic>>[];
    for (final rule in _hostRules.where((item) => item.enabled)) {
      final hostRule = _dnsRuleForHost(rule);
      if (hostRule != null) {
        dnsRules.add(hostRule);
      }
    }
    if (secondaryServer == null) {
      dnsRules.add(<String, dynamic>{
        'action': 'route',
        'server': 'vhosts-dns-primary',
        'timeout': '${activeProfile.timeoutMs}ms',
      });
    } else {
      dnsRules.add(<String, dynamic>{
        'action': 'evaluate',
        'server': 'vhosts-dns-primary',
        'timeout': '${activeProfile.timeoutMs}ms',
      });
      dnsRules.add(<String, dynamic>{
        'match_response': true,
        'ip_accept_any': true,
        'action': 'respond',
      });
      dnsRules.add(<String, dynamic>{
        'action': 'evaluate',
        'server': 'vhosts-dns-secondary',
        'timeout': '${activeProfile.timeoutMs}ms',
      });
      dnsRules.add(<String, dynamic>{
        'match_response': true,
        'action': 'respond',
      });
    }
    final payload = <String, dynamic>{
      'log': <String, dynamic>{'level': 'warn'},
      'dns': <String, dynamic>{
        'servers': dnsServers,
        'rules': dnsRules,
        'final': 'vhosts-dns-primary',
        'strategy': _allowIpv6 ? 'prefer_ipv4' : 'ipv4_only',
      },
      'inbounds': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'tun',
          'tag': 'vhosts-tun',
          'address': <String>[
            '172.18.0.1/30',
            if (_allowIpv6) 'fdfe:dcba:9876::1/126',
          ],
          'mtu': 1500,
          'auto_route': true,
          'strict_route': true,
        },
      ],
      'outbounds': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'direct', 'tag': 'direct'},
        <String, dynamic>{'type': 'block', 'tag': 'block'},
      ],
      'route': <String, dynamic>{
        'auto_detect_interface': true,
        'final': 'direct',
      },
    };
    return jsonEncode(payload);
  }

  Map<String, dynamic>? _dnsRuleForHost(HostRule rule) {
    final domain = _normalizeHostDomain(rule.domain);
    final targetIp = rule.targetIp.trim();
    if (domain.isEmpty || targetIp.isEmpty) {
      return null;
    }

    final String matchField;
    final String owner;
    switch (rule.matchType) {
      case HostMatchType.exact:
        matchField = 'domain';
        owner = domain;
      case HostMatchType.suffix:
        if (!domain.startsWith('*.') || domain.length <= 2) {
          return null;
        }
        matchField = 'domain_suffix';
        owner = '*${domain.substring(1)}';
    }
    final recordType = targetIp.contains(':') ? 'AAAA' : 'A';
    return <String, dynamic>{
      matchField: <String>[
        matchField == 'domain' ? domain : owner.substring(1),
      ],
      'query_type': <String>[recordType],
      'action': 'predefined',
      'answer': <String>['$owner. IN $recordType $targetIp'],
    };
  }

  Map<String, dynamic> _dnsServerForProfile(
    DnsProfile profile, {
    required String tag,
  }) {
    final server = profile.server.trim();
    switch (profile.type) {
      case DnsProfileType.system:
        return <String, dynamic>{'type': 'local', 'tag': tag};
      case DnsProfileType.plain:
        final parsed = _parseHostPort(server, 53);
        return <String, dynamic>{
          'type': 'udp',
          'tag': tag,
          'server': parsed.host,
          'server_port': parsed.port,
          if (_isDomainName(parsed.host)) 'domain_resolver': 'vhosts-bootstrap',
        };
      case DnsProfileType.doh:
        final uri = Uri.tryParse(server);
        if (uri == null || uri.host.isEmpty) {
          return <String, dynamic>{'type': 'local', 'tag': tag};
        }
        return <String, dynamic>{
          'type': 'https',
          'tag': tag,
          'server': uri.host,
          'server_port': uri.hasPort ? uri.port : 443,
          'path': uri.path.isEmpty ? '/dns-query' : uri.path,
          'tls': <String, dynamic>{'server_name': uri.host},
          if (_isDomainName(uri.host)) 'domain_resolver': 'vhosts-bootstrap',
        };
      case DnsProfileType.dot:
        final parsed = _parseHostPort(server, 853);
        final hostname = profile.dotHostname.trim();
        return <String, dynamic>{
          'type': 'tls',
          'tag': tag,
          'server': parsed.host,
          'server_port': parsed.port,
          'tls': <String, dynamic>{
            if (hostname.isNotEmpty) 'server_name': hostname,
          },
          if (_isDomainName(parsed.host)) 'domain_resolver': 'vhosts-bootstrap',
        };
    }
  }

  Map<String, dynamic>? _secondaryDnsServerForProfile(DnsProfile profile) {
    final secondary = profile.secondaryServer.trim();
    if (secondary.isEmpty || profile.type != DnsProfileType.plain) {
      return null;
    }
    final parsed = _parseHostPort(secondary, 53);
    return <String, dynamic>{
      'type': 'udp',
      'tag': 'vhosts-dns-secondary',
      'server': parsed.host,
      'server_port': parsed.port,
      if (_isDomainName(parsed.host)) 'domain_resolver': 'vhosts-bootstrap',
    };
  }

  bool _serverNeedsBootstrapResolver(Map<String, dynamic> server) {
    return server['domain_resolver'] == 'vhosts-bootstrap';
  }

  bool _isDomainName(String value) {
    final input = value.trim();
    return input.isNotEmpty &&
        !RegExp(r'^\[?([0-9a-fA-F:]+)\]?$').hasMatch(input) &&
        !RegExp(r'^\d+(\.\d+){3}$').hasMatch(input);
  }

  String _normalizeHostDomain(String value) {
    var domain = value.trim().toLowerCase();
    if (domain.endsWith('.')) {
      domain = domain.substring(0, domain.length - 1);
    }
    return domain;
  }

  ({String host, int port}) _parseHostPort(String value, int defaultPort) {
    var input = value.trim();
    if (input.startsWith('dns://')) {
      input = input.substring(6);
    }
    if (input.startsWith('[')) {
      final end = input.indexOf(']');
      if (end > 0) {
        final host = input.substring(1, end);
        final port = end + 1 < input.length && input[end + 1] == ':'
            ? int.tryParse(input.substring(end + 2)) ?? defaultPort
            : defaultPort;
        return (host: host, port: port);
      }
    }
    final separator = input.lastIndexOf(':');
    if (separator > 0 && input.indexOf(':') == separator) {
      return (
        host: input.substring(0, separator),
        port: int.tryParse(input.substring(separator + 1)) ?? defaultPort,
      );
    }
    return (host: input, port: defaultPort);
  }

  HostMatchType _matchTypeForDomain(String domain) {
    if (domain.startsWith('*.')) {
      return HostMatchType.suffix;
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
    final activeDnsProfileId = _activeDnsProfileId(_dnsProfiles);
    final appStateJson = jsonEncode(<String, dynamic>{
      'allowIpv6': _allowIpv6,
      'activeDnsProfileId': activeDnsProfileId,
      'hostRules': _hostRules
          .map((rule) => rule.toJson())
          .toList(growable: false),
      'dnsProfiles': _dnsProfiles
          .map((profile) => profile.toJson())
          .toList(growable: false),
    });
    await AppStoragePlatformService.save(appStateJson);
  }

  void _resetToDefaultConfiguration() {
    _hostRules = const <HostRule>[];
    _dnsProfiles = _defaultDnsProfiles();
    _allowIpv6 = true;
  }

  Future<bool> _requestSingboxPermission() async {
    try {
      return await _singboxClient.requestVPNPermission();
    } on PlatformException {
      return false;
    } on StateError {
      return false;
    }
  }

  void _applySingboxState(ServiceState state) {
    if (_disposed) {
      return;
    }

    final previousAuthorized = _vpnAuthorized;
    final previousStatus = _vpnStatus;

    if (state == ServiceState.started) {
      _vpnAuthorized = true;
      _vpnStatus = VpnStatus.running;
    } else if (state == ServiceState.starting) {
      _vpnAuthorized = true;
      _vpnStatus = VpnStatus.starting;
    } else if (state == ServiceState.stopping) {
      _vpnStatus = VpnStatus.stopping;
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
  healthStatus: DnsHealthStatus.unknown,
  healthDetail: '默认使用阿里云 DoH，由 sing-box 负责解析',
  latencyMs: null,
);
