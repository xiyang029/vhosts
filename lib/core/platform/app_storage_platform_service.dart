import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppStoragePlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/app');

  static bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<String?> load() async {
    if (!_supportedPlatform) {
      return null;
    }

    try {
      return await _channel.invokeMethod<String>('loadAppState');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> save(String stateJson) async {
    if (!_supportedPlatform) {
      return false;
    }

    try {
      return await _channel.invokeMethod<bool>(
            'saveAppState',
            <String, Object?>{'stateJson': stateJson},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
