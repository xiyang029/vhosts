import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/dns/domain/dns_profile.dart';
import '../../features/hosts/domain/host_rule.dart';

class DnsTestResult {
  const DnsTestResult({
    required this.success,
    required this.latencyMs,
    required this.detail,
  });

  final bool success;
  final int? latencyMs;
  final String detail;

  factory DnsTestResult.fromMap(Map<dynamic, dynamic> map) {
    return DnsTestResult(
      success: map['success'] == true,
      latencyMs: (map['latencyMs'] as num?)?.toInt(),
      detail: map['detail']?.toString() ?? '未知错误',
    );
  }
}

class DnsVpnPlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/dns');
  static const EventChannel _events = EventChannel('vhosts/dns/events');

  static bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<String> get statusStream {
    if (!_supportedPlatform) {
      return const Stream<String>.empty();
    }
    return _events.receiveBroadcastStream().map((event) => event.toString());
  }

  static Future<bool> requestPermission() async {
    if (!_supportedPlatform) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('requestVpnPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> start({
    required DnsProfile profile,
    required Iterable<HostRule> hostRules,
  }) async {
    if (!_supportedPlatform) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('startVpn', <String, Object?>{
            'profileJson': jsonEncode(profile.toJson()),
            'hostRulesJson': jsonEncode(
              hostRules.map((rule) => rule.toJson()).toList(growable: false),
            ),
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> stop() async {
    if (!_supportedPlatform) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('stopVpn') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<DnsTestResult?> test(DnsProfile profile) async {
    if (!_supportedPlatform) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'testDns',
        <String, Object?>{'profileJson': jsonEncode(profile.toJson())},
      );
      return result == null ? null : DnsTestResult.fromMap(result);
    } on PlatformException catch (error) {
      return DnsTestResult(
        success: false,
        latencyMs: null,
        detail: error.message ?? '平台调用失败',
      );
    } on MissingPluginException {
      return null;
    }
  }
}
