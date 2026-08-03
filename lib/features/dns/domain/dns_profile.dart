import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/app_theme.dart';
import '../../../shared/utils/app_utils.dart';

enum DnsProfileType { system, plain, doh, dot }

extension DnsProfileTypeX on DnsProfileType {
  String get label => switch (this) {
    DnsProfileType.system => 'System DNS',
    DnsProfileType.plain => 'Plain DNS',
    DnsProfileType.doh => 'DoH',
    DnsProfileType.dot => 'DoT',
  };

  IconData get icon => switch (this) {
    DnsProfileType.system => LucideIcons.settings,
    DnsProfileType.plain => LucideIcons.globe,
    DnsProfileType.doh => LucideIcons.shield,
    DnsProfileType.dot => LucideIcons.badgeCheck,
  };
}

enum DnsHealthStatus { healthy, degraded, offline, unknown }

extension DnsHealthStatusX on DnsHealthStatus {
  Color get color => switch (this) {
    DnsHealthStatus.healthy => vhostsSuccess,
    DnsHealthStatus.degraded => vhostsWarning,
    DnsHealthStatus.offline => vhostsDanger,
    DnsHealthStatus.unknown => vhostsNeutral,
  };
}

class DnsProfile {
  const DnsProfile({
    required this.id,
    required this.name,
    required this.type,
    required this.server,
    required this.secondaryServer,
    required this.dotHostname,
    required this.timeoutMs,
    required this.retryCount,
    required this.enabled,
    required this.healthStatus,
    required this.healthDetail,
    this.latencyMs,
  });

  final String id;
  final String name;
  final DnsProfileType type;
  final String server;
  final String secondaryServer;
  final String dotHostname;
  final int timeoutMs;
  final int retryCount;
  final bool enabled;
  final DnsHealthStatus healthStatus;
  final String healthDetail;
  final int? latencyMs;

  factory DnsProfile.fromJson(Map<String, dynamic> json) {
    return DnsProfile(
      id: stringValue(json['id']),
      name: stringValue(json['name']),
      type: enumByName(
        DnsProfileType.values,
        stringValue(json['type']),
        DnsProfileType.system,
      ),
      server: stringValue(json['server']),
      secondaryServer: stringValue(json['secondaryServer']),
      dotHostname: stringValue(json['dotHostname']),
      timeoutMs: intValue(json['timeoutMs'], 1500),
      retryCount: intValue(json['retryCount'], 1),
      enabled: boolValue(json['enabled']),
      healthStatus: enumByName(
        DnsHealthStatus.values,
        stringValue(json['healthStatus']),
        DnsHealthStatus.unknown,
      ),
      healthDetail: stringValue(json['healthDetail']),
      latencyMs: nullableIntValue(json['latencyMs']),
    );
  }

  DnsProfile copyWith({
    String? id,
    String? name,
    DnsProfileType? type,
    String? server,
    String? secondaryServer,
    String? dotHostname,
    int? timeoutMs,
    int? retryCount,
    bool? enabled,
    DnsHealthStatus? healthStatus,
    String? healthDetail,
    int? latencyMs,
  }) {
    return DnsProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      server: server ?? this.server,
      secondaryServer: secondaryServer ?? this.secondaryServer,
      dotHostname: dotHostname ?? this.dotHostname,
      timeoutMs: timeoutMs ?? this.timeoutMs,
      retryCount: retryCount ?? this.retryCount,
      enabled: enabled ?? this.enabled,
      healthStatus: healthStatus ?? this.healthStatus,
      healthDetail: healthDetail ?? this.healthDetail,
      latencyMs: latencyMs ?? this.latencyMs,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'type': type.name,
      'server': server,
      'secondaryServer': secondaryServer,
      'dotHostname': dotHostname,
      'timeoutMs': timeoutMs,
      'retryCount': retryCount,
      'enabled': enabled,
      'healthStatus': healthStatus.name,
      'healthDetail': healthDetail,
      'latencyMs': latencyMs,
    };
  }
}
