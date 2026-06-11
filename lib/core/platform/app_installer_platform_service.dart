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

  static Future<void> showDownloadNotification({
    required int id,
    required String title,
    required String content,
    int? progress,
    bool completed = false,
    bool failed = false,
  }) async {
    try {
      await _channel.invokeMethod<void>('showDownloadNotification', {
        'id': id,
        'title': title,
        'content': content,
        'progress': progress,
        'completed': completed,
        'failed': failed,
      });
    } catch (_) {
      // 通知不可用时不影响 APK 下载和安装流程。
    }
  }
}
