import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_state.dart';
import '../../../core/platform/app_installer_platform_service.dart';
import '../../../core/services/app_update_service.dart';

const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(18, 18, 18, 28);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  final AppUpdateService _updateService = AppUpdateService();
  static const int _downloadNotificationId = 1001;
  bool _checkingUpdate = false;
  String? _pendingInstallApkPath;
  bool _waitingInstallPermission = false;
  int _lastNotifiedProgress = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumePendingInstallIfPossible();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = ShadTheme.of(context);

    return SafeArea(
      child: ListView(
        padding: _pagePadding,
        children: [
          Text('网络', style: theme.textTheme.muted),
          const SizedBox(height: 8),
          ShadCard(
            padding: EdgeInsets.zero,
            child: _SettingsRow(
              icon: LucideIcons.network,
              title: '允许 IPv6',
              trailing: ShadSwitch(
                value: app.allowIpv6,
                onChanged: app.setAllowIpv6,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('应用', style: theme.textTheme.muted),
          const SizedBox(height: 8),
          ShadCard(
            padding: EdgeInsets.zero,
            child: IgnorePointer(
              ignoring: _checkingUpdate,
              child: _SettingsRow(
                icon: LucideIcons.download,
                title: '检查更新',
                onTap: _checkForUpdates,
                trailing: const Icon(LucideIcons.chevronRight),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates() async {
    if (_checkingUpdate) {
      return;
    }

    setState(() => _checkingUpdate = true);
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final release = await _updateService.fetchLatestRelease();
      if (!mounted) {
        return;
      }

      if (!_isVersionNewer(release.version, packageInfo.version)) {
        ShadToaster.of(
          context,
        ).show(ShadToast(description: Text('当前已是最新版本 ${packageInfo.version}')));
        return;
      }

      final shouldDownload =
          await showShadDialog<bool>(
            context: context,
            builder: (context) => ShadDialog.alert(
              title: const Text('发现新版本'),
              description: Text(
                '当前版本 ${packageInfo.version}，最新版本 ${release.version}。\n是否立即下载并安装 APK？',
              ),
              actions: [
                ShadButton.outline(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('稍后'),
                ),
                ShadButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('下载'),
                ),
              ],
            ),
          ) ==
          true;
      if (!mounted || !shouldDownload) {
        return;
      }

      await _downloadAndInstallRelease(release);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ShadToaster.of(
        context,
      ).show(ShadToast(description: Text('检查更新失败：$error')));
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
  }

  Future<void> _downloadAndInstallRelease(AppReleaseInfo release) async {
    _lastNotifiedProgress = -1;
    await _showDownloadNotification(
      title: '正在下载更新',
      content: '准备下载 ${release.version}',
      progress: 0,
    );

    try {
      final cachedFile = await _updateService.findCachedReleaseApk(release);
      final file =
          cachedFile ?? await _downloadReleaseWithNotification(release);
      await _showDownloadNotification(
        title: '下载完成',
        content: cachedFile == null ? '正在打开安装包' : '已找到缓存安装包，正在打开安装包',
        progress: 100,
        completed: true,
      );
      await _openDownloadedApk(file.path);
    } catch (error) {
      await _showDownloadNotification(
        title: '下载失败',
        content: error.toString(),
        failed: true,
      );
      if (!mounted) {
        return;
      }
      ShadToaster.of(
        context,
      ).show(ShadToast(description: Text('下载更新失败：$error')));
    }
  }

  Future<void> _showDownloadNotification({
    required String title,
    required String content,
    int? progress,
    bool completed = false,
    bool failed = false,
  }) {
    return AppInstallerPlatformService.showDownloadNotification(
      id: _downloadNotificationId,
      title: title,
      content: content,
      progress: progress,
      completed: completed,
      failed: failed,
    );
  }

  Future<File> _downloadReleaseWithNotification(AppReleaseInfo release) {
    return _updateService.downloadReleaseApk(
      release,
      onProgress: (receivedBytes, totalBytes) {
        if (totalBytes != null && totalBytes > 0) {
          final progress = (receivedBytes / totalBytes * 100)
              .clamp(0, 100)
              .round();
          if (progress == _lastNotifiedProgress) {
            return;
          }
          _lastNotifiedProgress = progress;
          unawaited(
            _showDownloadNotification(
              title: '正在下载更新',
              content: '$progress%',
              progress: progress,
            ),
          );
          return;
        }

        final downloadedMb = receivedBytes / 1024 / 1024;
        unawaited(
          _showDownloadNotification(
            title: '正在下载更新',
            content: '已下载 ${downloadedMb.toStringAsFixed(1)} MB',
          ),
        );
      },
    );
  }

  Future<void> _resumePendingInstallIfPossible() async {
    if (!_waitingInstallPermission || _pendingInstallApkPath == null) {
      return;
    }

    final allowed =
        await AppInstallerPlatformService.canRequestPackageInstalls();
    if (!allowed) {
      return;
    }

    final apkPath = _pendingInstallApkPath;
    _waitingInstallPermission = false;
    _pendingInstallApkPath = null;
    if (apkPath != null) {
      await _openDownloadedApk(apkPath);
    }
  }

  Future<void> _openDownloadedApk(String apkPath) async {
    final allowed =
        await AppInstallerPlatformService.canRequestPackageInstalls();
    if (!allowed) {
      _pendingInstallApkPath = apkPath;
      _waitingInstallPermission = true;
      await AppInstallerPlatformService.openInstallPermissionSettings();
      return;
    }

    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
    if (!mounted) {
      return;
    }

    switch (result.type) {
      case ResultType.done:
        break;
      case ResultType.permissionDenied:
        ShadToaster.of(
          context,
        ).show(const ShadToast(description: Text('无法打开安装包，请检查文件访问权限')));
        break;
      case ResultType.noAppToOpen:
        ShadToaster.of(
          context,
        ).show(const ShadToast(description: Text('系统没有可用的安装程序')));
        break;
      case ResultType.fileNotFound:
        ShadToaster.of(
          context,
        ).show(const ShadToast(description: Text('安装包不存在，请重新下载')));
        break;
      case ResultType.error:
        ShadToaster.of(
          context,
        ).show(ShadToast(description: Text('打开安装包失败：${result.message}')));
        break;
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
        .toList();
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      final theme = ShadTheme.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.mutedForeground),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: theme.textTheme.p)),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      );
    }

    return ShadButton.ghost(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      onPressed: onTap,
      leading: Icon(icon),
      trailing: trailing,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      child: Text(title),
    );
  }
}
