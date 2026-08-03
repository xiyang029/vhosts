import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_theme.dart';
import '../../../core/services/app_update_service.dart';

const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(18, 18, 18, 28);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppUpdateService _updateService = AppUpdateService();
  bool _checkingUpdate = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final checkingUpdate = _checkingUpdate;

    return SafeArea(
      child: ListView(
        padding: _pagePadding,
        children: [
          ShadCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsRow(
                  icon: LucideIcons.download,
                  title: checkingUpdate ? '检查中...' : '检查更新',
                  onTap: checkingUpdate ? null : _checkForUpdates,
                  trailing: checkingUpdate
                      ? SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : const Icon(LucideIcons.chevronRight),
                ),
              ],
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
      await _updateService.checkForUpdates(context);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showVhostsToast(context, '检查更新失败：$error');
    } finally {
      if (mounted) {
        setState(() => _checkingUpdate = false);
      }
    }
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
    final theme = ShadTheme.of(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
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

    if (onTap == null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}
