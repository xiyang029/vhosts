import 'dart:io';

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

  static Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> getDownloadDirectory() async {
    try {
      final directory = await _channel.invokeMethod<String>(
        'getDownloadDirectory',
      );
      return directory?.trim().isNotEmpty == true
          ? directory!.trim()
          : Directory.systemTemp.path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }
}
