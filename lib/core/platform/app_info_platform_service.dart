import 'package:flutter/services.dart';

class AppInfoPlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/app');

  static Future<String> getVersion() async {
    final version = await _channel.invokeMethod<String>('getAppVersion');
    final normalized = version?.trim() ?? '';
    if (normalized.isEmpty) {
      throw StateError('无法读取应用版本');
    }
    return normalized;
  }

  static Future<List<String>> getSupportedAbis() async {
    final abis = await _channel.invokeListMethod<String>('getSupportedAbis');
    return abis ?? const [];
  }
}
