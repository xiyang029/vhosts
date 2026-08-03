import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../platform/app_info_platform_service.dart';
import '../platform/app_installer_platform_service.dart';
import '../../app/app_theme.dart';

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.apkUrl,
    required this.fileName,
  });

  final String version;
  final String apkUrl;
  final String fileName;
}

class AppUpdateService {
  AppUpdateService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

  static final Uri _latestReleaseUri = Uri.parse(
    'https://api.github.com/repos/xiyang029/vhosts/releases/latest',
  );
  static Future<void>? _activeCheck;

  Future<void> checkForUpdates(
    BuildContext context, {
    bool showUpToDateToast = true,
  }) {
    final active = _activeCheck;
    if (active != null) {
      return active;
    }

    final future =
        _checkForUpdates(
          context,
          showUpToDateToast: showUpToDateToast,
        ).whenComplete(() {
          _activeCheck = null;
        });
    _activeCheck = future;
    return future;
  }

  Future<void> _checkForUpdates(
    BuildContext context, {
    required bool showUpToDateToast,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final currentVersion = await AppInfoPlatformService.getVersion();
      final release = await fetchLatestRelease();
      if (!context.mounted) {
        return;
      }

      if (!_isVersionNewer(release.version, currentVersion)) {
        if (showUpToDateToast) {
          showVhostsToast(context, '当前已是最新版本 $currentVersion');
        }
        return;
      }

      final shouldDownload =
          await showShadDialog<bool>(
            context: context,
            builder: (dialogContext) => ShadDialog.alert(
              title: const Text('发现新版本'),
              description: Text(
                '当前版本 $currentVersion，最新版本 ${release.version}。\n是否立即下载并安装对应 ABI 的 APK？',
              ),
              actions: [
                ShadButton.outline(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('稍后'),
                ),
                ShadButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('下载'),
                ),
              ],
            ),
          ) ==
          true;

      if (!context.mounted || !shouldDownload) {
        return;
      }

      showVhostsToast(context, '开始后台下载更新，完成后将自动安装');
      final file = await downloadReleaseApk(release);
      if (!context.mounted) {
        return;
      }

      await _openDownloadedApk(file.path);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      showVhostsToast(context, '检查更新失败：$error');
    }
  }

  Future<AppReleaseInfo> fetchLatestRelease() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Android only');
    }

    final response = await _get(_latestReleaseUri, followRedirects: true);
    final Map<String, dynamic> data =
        json.decode(await utf8.decodeStream(response)) as Map<String, dynamic>;
    final assets = data['assets'] as List<dynamic>? ?? const [];
    final abi = await _resolveAndroidAbi();
    final apkAsset = _selectApkAsset(assets, abi);
    final version = (data['tag_name'] as String?)?.trim().takeIfNotEmpty();
    final releaseVersion =
        version ?? (throw const FormatException('Release tag_name is missing'));

    return AppReleaseInfo(
      version: releaseVersion,
      apkUrl: apkAsset['browser_download_url'] as String,
      fileName: _buildLocalApkFileName(releaseVersion, abi),
    );
  }

  Future<File> downloadReleaseApk(AppReleaseInfo release) async {
    final downloadDirectory =
        await AppInstallerPlatformService.getDownloadDirectory();
    final directory = Directory(downloadDirectory);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final file = File(
      '${directory.path}${Platform.pathSeparator}${release.fileName}',
    );
    if (await file.exists()) {
      return file;
    }

    final temporaryFile = File('${file.path}.part');
    try {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      final response = await _get(
        Uri.parse(release.apkUrl),
        followRedirects: true,
      );
      await response.pipe(temporaryFile.openWrite());
      if (!await temporaryFile.exists() || await temporaryFile.length() == 0) {
        throw FileSystemException('下载完成但文件为空', temporaryFile.path);
      }
      await temporaryFile.rename(file.path);
      return file;
    } catch (_) {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      rethrow;
    }
  }

  Future<void> _openDownloadedApk(String apkPath) async {
    final allowed =
        await AppInstallerPlatformService.canRequestPackageInstalls();
    if (!allowed) {
      await AppInstallerPlatformService.openInstallPermissionSettings();
      return;
    }

    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );

    switch (result.type) {
      case ResultType.done:
        break;
      case ResultType.permissionDenied:
        throw StateError('无法打开安装包，请检查文件访问权限');
      case ResultType.noAppToOpen:
        throw StateError('系统没有可用的安装程序');
      case ResultType.fileNotFound:
        throw StateError('安装包不存在，请重新下载');
      case ResultType.error:
        throw StateError('打开安装包失败：${result.message}');
    }
  }

  Future<HttpClientResponse> _get(
    Uri uri, {
    required bool followRedirects,
  }) async {
    final request = await _httpClient.getUrl(uri);
    request.followRedirects = followRedirects;
    request.headers.set(HttpHeaders.userAgentHeader, 'vhosts-app-updater');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw HttpException(
        'Request failed with status ${response.statusCode}',
        uri: uri,
      );
    }
    return response;
  }

  Future<String> _resolveAndroidAbi() async {
    const supportedOrder = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];
    final supportedAbis = await AppInfoPlatformService.getSupportedAbis();

    for (final abi in supportedOrder) {
      if (supportedAbis.contains(abi)) {
        return abi;
      }
    }

    if (supportedAbis.isNotEmpty) {
      return supportedAbis.first;
    }

    throw StateError('无法识别当前设备 ABI');
  }

  Map<String, dynamic> _selectApkAsset(List<dynamic> assets, String abi) {
    final typedAssets = assets
        .whereType<Map>()
        .map((asset) => Map<String, dynamic>.from(asset))
        .where((asset) {
          final name = asset['name'] as String? ?? '';
          return name.toLowerCase().endsWith('.apk');
        })
        .toList(growable: false);

    final exactName = _defaultApkNameForAbi(abi);
    for (final asset in typedAssets) {
      if (asset['name'] == exactName) {
        return asset;
      }
    }

    for (final asset in typedAssets) {
      final name = asset['name'] as String? ?? '';
      if (name.contains(abi)) {
        return asset;
      }
    }

    throw FormatException('APK asset for ABI $abi not found');
  }

  String _defaultApkNameForAbi(String abi) {
    return 'app-$abi-release.apk';
  }

  String _buildLocalApkFileName(String version, String abi) {
    final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return 'vhosts-$safeVersion-$abi.apk';
  }

  bool _isVersionNewer(String latest, String current) {
    final latestParts = _versionParts(latest);
    final currentParts = _versionParts(current);
    final length = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;
    for (var index = 0; index < length; index++) {
      final latestPart = index < latestParts.length ? latestParts[index] : 0;
      final currentPart = index < currentParts.length ? currentParts[index] : 0;
      if (latestPart != currentPart) {
        return latestPart > currentPart;
      }
    }
    return false;
  }

  List<int> _versionParts(String version) {
    return version
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
  }
}

extension on String {
  String? takeIfNotEmpty() => isEmpty ? null : this;
}
