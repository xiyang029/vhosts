import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VpnPlatformState {
  const VpnPlatformState({required this.authorized, required this.running});

  final bool authorized;
  final bool running;

  factory VpnPlatformState.fromDynamic(dynamic value) {
    if (value is! Map) {
      return const VpnPlatformState(authorized: false, running: false);
    }

    return VpnPlatformState(
      authorized: value['authorized'] == true,
      running: value['running'] == true,
    );
  }
}

class VpnPlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/vpn');
  static const EventChannel _stateEventsChannel = EventChannel(
    'vhosts/vpn_state_events',
  );

  static bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> _invokeBoolMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!_supportedPlatform) {
      return false;
    }

    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> saveConfiguration(String configurationJson) async {
    return _invokeBoolMethod('saveVpnConfiguration', <String, Object?>{
      'configurationJson': configurationJson,
    });
  }

  static Future<String?> loadAppState() async {
    if (!_supportedPlatform) {
      return null;
    }

    try {
      return await _channel.invokeMethod<String>('loadAppState');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> saveAppState(String stateJson) async {
    return _invokeBoolMethod('saveAppState', <String, Object?>{
      'stateJson': stateJson,
    });
  }

  static Stream<VpnPlatformState> stateEvents() {
    if (!_supportedPlatform) {
      return const Stream<VpnPlatformState>.empty();
    }

    return _stateEventsChannel.receiveBroadcastStream().map(
      VpnPlatformState.fromDynamic,
    );
  }

  static Future<bool> requestPermission() async {
    return _invokeBoolMethod('requestVpnPermission');
  }

  static Future<bool> startVpn(String configurationJson) async {
    return _invokeBoolMethod('startVpn', <String, Object?>{
      'configurationJson': configurationJson,
    });
  }

  static Future<bool> stopVpn() async {
    return _invokeBoolMethod('stopVpn');
  }

  static Future<Map<String, dynamic>> testDnsProfile(
    Map<String, dynamic> profile, {
    required bool allowIpv6,
  }) async {
    if (!_supportedPlatform) {
      return const <String, dynamic>{};
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'testDnsProfile',
        <String, Object?>{
          'profileJson': jsonEncode(profile),
          'allowIpv6': allowIpv6,
        },
      );
      if (result == null) {
        return const <String, dynamic>{};
      }
      return Map<String, dynamic>.from(result);
    } on PlatformException {
      return const <String, dynamic>{};
    }
  }
}
