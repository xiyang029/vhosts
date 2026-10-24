import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_state.dart';
import '../../../app/app_theme.dart';
import '../../../shared/utils/app_utils.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../domain/dns_profile.dart';

const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(18, 18, 18, 28);
const EdgeInsets _cardPadding = EdgeInsets.all(16);
const EdgeInsets _sheetContentPadding = EdgeInsets.fromLTRB(2, 16, 2, 2);

class DnsPage extends StatefulWidget {
  const DnsPage({super.key});

  @override
  State<DnsPage> createState() => _DnsPageState();
}

class _DnsPageState extends State<DnsPage> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = ShadTheme.of(context);

    return SafeArea(
      child: ListView(
        padding: _pagePadding,
        children: [
          Row(
            children: [
              Expanded(child: Text('DNS 配置', style: theme.textTheme.large)),
              ShadButton(
                onPressed: () => _openProfileEditor(),
                leading: const Icon(LucideIcons.plus),
                child: const Text('新增配置'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...app.dnsProfiles.map(
            (profile) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DnsProfileCard(
                profile: profile,
                isProtected: app.isProtectedDnsProfile(profile.id),
                onTest: () => _testProfile(profile),
                onActivate: () => app.setActiveDnsProfile(profile.id),
                onEdit: () => _openProfileEditor(existing: profile),
                onDelete: () => _confirmDeleteProfile(profile),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _testProfile(DnsProfile profile) async {
    final result = await AppScope.of(context).testDnsProfile(profile.id);
    if (!mounted) {
      return;
    }
    showVhostsToast(
      context,
      result == null || !result.success
          ? '${profile.name} 测试失败：${result?.detail ?? '平台不支持'}'
          : '${profile.name} 测试完成，${result.latencyMs} ms',
    );
  }

  Future<void> _openProfileEditor({DnsProfile? existing}) async {
    final app = AppScope.of(context);
    final result = await showShadSheet<DnsProfile>(
      context: context,
      side: ShadSheetSide.bottom,
      builder: (context) => _ProfileEditorSheet(existing: existing),
    );

    if (result == null) {
      return;
    }

    app.upsertDnsProfile(result);
  }

  Future<void> _confirmDeleteProfile(DnsProfile profile) async {
    final app = AppScope.of(context);
    final confirmed =
        await showShadDialog<bool>(
          context: context,
          builder: (context) => ShadDialog.alert(
            title: const Text('删除 DNS 配置'),
            description: Text('确认删除 ${profile.name} 吗？'),
            actions: [
              ShadButton.outline(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              ShadButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ==
        true;

    if (!confirmed) {
      return;
    }

    app.deleteDnsProfile(profile.id);
    if (!mounted) {
      return;
    }
    showVhostsToast(context, '已删除 ${profile.name}');
  }
}

class _DnsProfileCard extends StatelessWidget {
  const _DnsProfileCard({
    required this.profile,
    required this.isProtected,
    required this.onTest,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final DnsProfile profile;
  final bool isProtected;
  final VoidCallback onTest;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      padding: _cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _IconHeader(
                  icon: LucideIcons.globe,
                  color: theme.colorScheme.primary,
                  title: profile.name,
                  subtitle: 'Plain DNS',
                  iconSize: 42,
                  iconRadius: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '主服务器：${profile.server}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 10),
          if (profile.secondaryServer.isNotEmpty)
            Text(
              '备用服务器：${profile.secondaryServer}',
              style: theme.textTheme.muted,
            ),
          Wrap(
            alignment: WrapAlignment.start,
            children: [
              if (profile.enabled)
                ShadButton.ghost(
                  enabled: false,
                  leading: const Icon(LucideIcons.circleCheck),
                  child: const Text('已启用'),
                )
              else
                ShadButton.ghost(
                  onPressed: onActivate,
                  leading: const Icon(LucideIcons.zap),
                  child: const Text('启用'),
                ),
              ShadButton.ghost(
                onPressed: onTest,
                leading: const Icon(LucideIcons.bolt),
                child: const Text('测试'),
              ),
              if (!isProtected) ...[
                ShadButton.ghost(
                  onPressed: onEdit,
                  leading: const Icon(LucideIcons.pencil),
                  child: const Text('编辑'),
                ),
                ShadButton.ghost(
                  onPressed: onDelete,
                  leading: const Icon(LucideIcons.trash2),
                  child: const Text('删除'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileEditorSheet extends StatefulWidget {
  const _ProfileEditorSheet({this.existing});

  final DnsProfile? existing;

  @override
  State<_ProfileEditorSheet> createState() => _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends State<_ProfileEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _serverController;
  late final TextEditingController _secondaryController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _retryController;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _serverController = TextEditingController(
      text: widget.existing?.server ?? '',
    );
    _secondaryController = TextEditingController(
      text: widget.existing?.secondaryServer ?? '',
    );
    _timeoutController = TextEditingController(
      text: (widget.existing?.timeoutMs ?? 1500).toString(),
    );
    _retryController = TextEditingController(
      text: (widget.existing?.retryCount ?? 2).toString(),
    );
    _enabled = widget.existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    _secondaryController.dispose();
    _timeoutController.dispose();
    _retryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadSheet(
      title: Text(widget.existing == null ? '新建 DNS' : '编辑 DNS'),
      constraints: const BoxConstraints(maxWidth: 560),
      actions: [ShadButton(onPressed: _save, child: const Text('保存'))],
      child: Padding(
        padding: _sheetContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            LabeledField(
              label: '配置名称',
              child: ShadInput(
                controller: _nameController,
                placeholder: const Text('例如 家庭 DNS'),
              ),
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: '主服务器',
              child: ShadInput(
                controller: _serverController,
                placeholder: const Text('例如 223.5.5.5（默认端口 53）'),
              ),
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: '备用服务器',
              child: ShadInput(
                controller: _secondaryController,
                placeholder: const Text('可选，例如 223.6.6.6（默认端口 53）'),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '立即启用',
                      style: ShadTheme.of(context).textTheme.small,
                    ),
                  ),
                  ShadSwitch(
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LabeledField(
                    label: '超时 (ms)',
                    child: ShadInput(
                      keyboardType: TextInputType.number,
                      controller: _timeoutController,
                      placeholder: const Text('1500'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LabeledField(
                    label: '重试次数',
                    child: ShadInput(
                      keyboardType: TextInputType.number,
                      controller: _retryController,
                      placeholder: const Text('2'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final server = _serverController.text.trim();
    final secondary = _secondaryController.text.trim();

    if (name.isEmpty) {
      showVhostsToast(context, '请先填写配置名称');
      return;
    }
    if (name.length > 32) {
      showVhostsToast(context, '配置名称请控制在 32 个字符以内');
      return;
    }
    if (!hasUriHost(server, scheme: 'dns')) {
      showVhostsToast(context, '服务器地址格式不正确');
      return;
    }
    if (secondary.isNotEmpty && !hasUriHost(secondary, scheme: 'dns')) {
      showVhostsToast(context, '备用服务器格式必须正确');
      return;
    }

    final timeoutMs = int.tryParse(_timeoutController.text.trim()) ?? 1500;
    final retryCount = int.tryParse(_retryController.text.trim()) ?? 2;
    if (timeoutMs < 300 || timeoutMs > 10000) {
      showVhostsToast(context, '超时时间需在 300 到 10000 ms 之间');
      return;
    }
    if (retryCount < 1 || retryCount > 5) {
      showVhostsToast(context, '重试次数需在 1 到 5 之间');
      return;
    }

    final now = DateTime.now();
    Navigator.of(context).pop(
      DnsProfile(
        id: widget.existing?.id ?? 'dp_${now.millisecondsSinceEpoch}',
        name: name,
        server: server,
        secondaryServer: secondary,
        timeoutMs: timeoutMs,
        retryCount: retryCount,
        enabled: _enabled,
      ),
    );
  }
}

class _IconHeader extends StatelessWidget {
  const _IconHeader({
    required this.icon,
    required this.color,
    required this.title,
    required this.iconSize,
    required this.iconRadius,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final double iconSize;
  final double iconRadius;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      children: [
        Container(
          width: iconSize,
          height: iconSize,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(iconRadius),
          ),
          child: Icon(icon, color: color, size: iconSize * 0.52),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: theme.textTheme.muted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

