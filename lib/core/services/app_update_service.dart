import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../platform/app_installer_platform_service.dart';
import '../../app/app_theme.dart';

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.apkUrl,
    required this.fileName,
    required this.abi,
    required this.releasePageUrl,
  });

  final String version;
  final String apkUrl;
  final String fileName;
  final String abi;
  final String releasePageUrl;
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

    final future = _checkForUpdates(
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
      final packageInfo = await PackageInfo.fromPlatform();
      final release = await fetchLatestRelease();
      if (!context.mounted) {
        return;
      }

      if (!_isVersionNewer(release.version, packageInfo.version)) {
        if (showUpToDateToast) {
          showVhostsToast(context, '当前已是最新版本 ${packageInfo.version}');
        }
        return;
      }

      final shouldDownload =
          await showShadDialog<bool>(
            context: context,
            builder: (dialogContext) => ShadDialog.alert(
              title: const Text('发现新版本'),
              description: Text(
                '当前版本 ${packageInfo.version}，最新版本 ${release.version}。\n是否立即下载并安装对应 ABI 的 APK？',
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
        json.decode(await _readResponseBody(response)) as Map<String, dynamic>;
    final assets = data['assets'] as List<dynamic>? ?? const [];
    final abi = await _resolveAndroidAbi();
    final apkAsset = _selectApkAsset(assets, abi);
    final version = (data['tag_name'] as String?)?.trim().takeIfNotEmpty();
    final releaseVersion =
        version ?? _throwFormat('Release tag_name is missing');

    return AppReleaseInfo(
      version: releaseVersion,
      apkUrl: apkAsset['browser_download_url'] as String,
      fileName: _buildLocalApkFileName(releaseVersion, abi),
      abi: abi,
      releasePageUrl:
          (data['html_url'] as String?)?.trim().takeIfNotEmpty() ??
          _latestReleaseUri.toString(),
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
    final existingTask = await _findTaskForFile(
      directory.path,
      release.fileName,
    );
    if (existingTask != null) {
      if (existingTask.status == DownloadTaskStatus.complete &&
          await file.exists()) {
        return file;
      }

      if (existingTask.status == DownloadTaskStatus.complete) {
        await _removeDownloadArtifact(existingTask.taskId, file);
      } else if (existingTask.status != DownloadTaskStatus.failed &&
          existingTask.status != DownloadTaskStatus.canceled &&
          existingTask.status != DownloadTaskStatus.undefined) {
        return _waitForTaskCompletion(existingTask.taskId, file);
      } else {
        await _removeDownloadArtifact(existingTask.taskId, file);
      }
    }

    if (await file.exists()) {
      await file.delete();
    }

    final notificationGranted =
        await AppInstallerPlatformService.requestNotificationPermission();
    if (!notificationGranted) {
      throw StateError('需要通知权限才能后台下载更新');
    }

    String? taskId;
    try {
      taskId = await FlutterDownloader.enqueue(
        url: release.apkUrl,
        savedDir: directory.path,
        fileName: release.fileName,
        showNotification: true,
        openFileFromNotification: false,
      );

      if (taskId == null) {
        throw StateError('创建下载任务失败');
      }

      while (true) {
        final tasks = await FlutterDownloader.loadTasks();
        final task = _findTask(tasks, taskId);
        if (task == null) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }

        switch (task.status) {
          case DownloadTaskStatus.complete:
            if (!await file.exists()) {
              await _removeDownloadArtifact(taskId, file);
              throw FileSystemException('下载完成但文件不存在', file.path);
            }
            return file;
          case DownloadTaskStatus.failed:
          case DownloadTaskStatus.canceled:
          case DownloadTaskStatus.undefined:
            await _removeDownloadArtifact(taskId, file);
            throw StateError('下载任务已失效，请重新下载');
          default:
            await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    } catch (_) {
      if (taskId != null) {
        await _removeDownloadArtifact(taskId, file);
      } else if (await file.exists()) {
        await file.delete();
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

  Future<String> _readResponseBody(HttpClientResponse response) async {
    return utf8.decodeStream(response);
  }

  Future<String> _resolveAndroidAbi() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    const supportedOrder = <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];

    for (final abi in supportedOrder) {
      if (androidInfo.supportedAbis.contains(abi)) {
        return abi;
      }
    }

    if (androidInfo.supportedAbis.isNotEmpty) {
      return androidInfo.supportedAbis.first;
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

  DownloadTask? _findTask(List<DownloadTask>? tasks, String taskId) {
    if (tasks == null) {
      return null;
    }

    for (final task in tasks) {
      if (task.taskId == taskId) {
        return task;
      }
    }
    return null;
  }

  Future<File> _waitForTaskCompletion(String taskId, File file) async {
    while (true) {
      final tasks = await FlutterDownloader.loadTasks();
      final task = _findTask(tasks, taskId);
      if (task == null) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }

      switch (task.status) {
        case DownloadTaskStatus.complete:
          if (!await file.exists()) {
            await _removeDownloadArtifact(taskId, file);
            throw FileSystemException('下载完成但文件不存在', file.path);
          }
          return file;
        case DownloadTaskStatus.failed:
        case DownloadTaskStatus.canceled:
        case DownloadTaskStatus.undefined:
          await _removeDownloadArtifact(taskId, file);
          throw StateError('下载任务已失效，请重新下载');
        default:
          await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<DownloadTask?> _findTaskForFile(
    String savedDir,
    String fileName,
  ) async {
    final tasks = await FlutterDownloader.loadTasks();
    if (tasks == null) {
      return null;
    }

    for (final task in tasks) {
      if (task.savedDir == savedDir && task.filename == fileName) {
        return task;
      }
    }
    return null;
  }

  Future<void> _removeDownloadArtifact(String taskId, File file) async {
    try {
      await FlutterDownloader.remove(
        taskId: taskId,
        shouldDeleteContent: true,
      );
    } catch (_) {}

    if (await file.exists()) {
      await file.delete();
    }
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

  Never _throwFormat(String message) {
    throw FormatException(message);
  }
}

extension on String {
  String? takeIfNotEmpty() => isEmpty ? null : this;
}
