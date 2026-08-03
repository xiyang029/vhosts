import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum DnsProfileType { plain, doh, dot }

extension DnsProfileTypeX on DnsProfileType {
  String get label => switch (this) {
    DnsProfileType.plain => 'Plain DNS',
    DnsProfileType.doh => 'DoH',
    DnsProfileType.dot => 'DoT',
  };

  IconData get icon => switch (this) {
    DnsProfileType.plain => LucideIcons.globe,
    DnsProfileType.doh => LucideIcons.shield,
    DnsProfileType.dot => LucideIcons.badgeCheck,
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

  factory DnsProfile.fromJson(Map<String, dynamic> json) {
    return DnsProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      type: DnsProfileType.values.byName(json['type'] as String),
      server: json['server'] as String,
      secondaryServer: json['secondaryServer'] as String,
      dotHostname: json['dotHostname'] as String,
      timeoutMs: (json['timeoutMs'] as num).toInt(),
      retryCount: (json['retryCount'] as num).toInt(),
      enabled: json['enabled'] as bool,
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
    };
  }
}
