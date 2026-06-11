import 'package:flutter/services.dart';

class AppInstallerPlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/installer');

  static Future<bool> canRequestPackageInstalls() async {
    try {
      final allowed = await _channel.invokeMethod<bool>(
        'canRequestPackageInstalls',
      );
      return allowed ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> openInstallPermissionSettings() {
    return _channel.invokeMethod<void>('openInstallPermissionSettings');
  }
}
