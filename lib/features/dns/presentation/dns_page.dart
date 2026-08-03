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
    final activeProfile = app.activeDnsProfile;

    return SafeArea(
      child: ListView(
        padding: _pagePadding,
        children: [
          ShadCard(
            padding: _cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IconHeader(
                  icon: activeProfile.type.icon,
                  color: activeProfile.healthStatus.color,
                  title: activeProfile.name,
                  subtitle: activeProfile.type.label,
                  iconSize: 44,
                  iconRadius: 14,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ShadButton(
                        onPressed: () async {
                          final elapsedMs = await app.testDnsProfile(
                            activeProfile.id,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          showVhostsToast(
                            context,
                            elapsedMs == null
                                ? '${activeProfile.name} 测试失败'
                                : '${activeProfile.name} 测试完成，$elapsedMs ms',
                          );
                        },
                        leading: const Icon(LucideIcons.bolt),
                        child: const Text('测试'),
                      ),
                    ),
                    if (!app.isProtectedDnsProfile(activeProfile.id)) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: ShadButton.outline(
                          onPressed: () =>
                              _openProfileEditor(existing: activeProfile),
                          leading: const Icon(LucideIcons.pencil),
                          child: const Text('编辑'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ShadCard(
            padding: _cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('配置列表')),
                    ShadButton.ghost(
                      onPressed: () => _openProfileEditor(),
                      child: const Icon(LucideIcons.circlePlus),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...app.dnsProfiles.map(
                  (profile) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DnsProfileCard(
                      profile: profile,
                      isProtected: app.isProtectedDnsProfile(profile.id),
                      onActivate: () {
                        app.setActiveDnsProfile(profile.id);
                      },
                      onEdit: () => _openProfileEditor(existing: profile),
                      onDelete: () => _confirmDeleteProfile(profile),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final DnsProfile profile;
  final bool isProtected;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
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
                  icon: profile.type.icon,
                  color: profile.healthStatus.color,
                  title: profile.name,
                  subtitle: profile.type.label,
                  iconSize: 42,
                  iconRadius: 14,
                ),
              ),
              ShadBadge.outline(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      profile.enabled
                          ? LucideIcons.circleCheck
                          : LucideIcons.circlePause,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Text(profile.enabled ? '启用中' : '待命'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoItem(label: '主服务器', value: profile.server),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ShadTooltip(
                builder: (context) => Text(profile.enabled ? '已激活' : '激活'),
                child: ShadButton.ghost(
                  width: 40,
                  height: 40,
                  padding: EdgeInsets.zero,
                  enabled: !profile.enabled,
                  onPressed: onActivate,
                  child: Icon(
                    profile.enabled ? LucideIcons.circleCheck : LucideIcons.zap,
                    size: 18,
                    color: profile.enabled ? vhostsSuccess : null,
                  ),
                ),
              ),
              if (!isProtected) ...[
                const SizedBox(width: 4),
                ShadTooltip(
                  builder: (context) => const Text('编辑'),
                  child: ShadButton.ghost(
                    width: 40,
                    height: 40,
                    padding: EdgeInsets.zero,
                    onPressed: onEdit,
                    child: const Icon(LucideIcons.pencil, size: 18),
                  ),
                ),
                const SizedBox(width: 4),
                ShadTooltip(
                  builder: (context) => const Text('删除'),
                  child: ShadButton.ghost(
                    width: 40,
                    height: 40,
                    padding: EdgeInsets.zero,
                    onPressed: onDelete,
                    child: const Icon(LucideIcons.trash2, size: 18),
                  ),
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
  late final TextEditingController _dotController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _retryController;
  late DnsProfileType _type;
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
    _dotController = TextEditingController(
      text: widget.existing?.dotHostname ?? '',
    );
    _timeoutController = TextEditingController(
      text: (widget.existing?.timeoutMs ?? 1500).toString(),
    );
    _retryController = TextEditingController(
      text: (widget.existing?.retryCount ?? 2).toString(),
    );
    _type = widget.existing?.type ?? DnsProfileType.doh;
    _enabled = widget.existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    _secondaryController.dispose();
    _dotController.dispose();
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('协议类型'),
                const SizedBox(height: 6),
                ShadSelect<DnsProfileType>(
                  minWidth: double.infinity,
                  initialValue: _type,
                  placeholder: const Text('协议类型'),
                  options: _editableDnsProfileTypes
                      .map(
                        (type) =>
                            ShadOption(value: type, child: Text(type.label)),
                      )
                      .toList(),
                  selectedOptionBuilder: (context, selected) {
                    return Text(selected.label);
                  },
                  onChanged: (selected) {
                    if (selected != null) {
                      setState(() => _type = selected);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: '配置名称',
              child: ShadInput(
                controller: _nameController,
                placeholder: const Text('例如 家庭 DNS'),
              ),
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: _serverLabelText(_type),
              child: ShadInput(
                controller: _serverController,
                placeholder: Text(_serverHintText(_type)),
              ),
            ),
            if (_type == DnsProfileType.plain) ...[
              const SizedBox(height: 12),
              LabeledField(
                label: '备用服务器',
                child: ShadInput(
                  controller: _secondaryController,
                  placeholder: const Text('可选，例如 223.6.6.6:53'),
                ),
              ),
            ] else if (_type == DnsProfileType.dot) ...[
              const SizedBox(height: 12),
              LabeledField(
                label: 'TLS 主机名',
                child: ShadInput(
                  controller: _dotController,
                  placeholder: const Text('例如 cloudflare-dns.com'),
                ),
              ),
            ],
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
    final dotHostname = _dotController.text.trim();

    if (name.isEmpty) {
      showVhostsToast(context, '请先填写配置名称');
      return;
    }
    if (name.length > 32) {
      showVhostsToast(context, '配置名称请控制在 32 个字符以内');
      return;
    }
    if (!_isValidServerForType(server, _type)) {
      showVhostsToast(context, '服务器地址格式与当前协议不匹配');
      return;
    }
    if (_type == DnsProfileType.plain &&
        secondary.isNotEmpty &&
        !hasUriHost(secondary, scheme: 'dns')) {
      showVhostsToast(context, '备用服务器仅支持 Plain DNS，且格式必须正确');
      return;
    }
    if (_type == DnsProfileType.dot &&
        !hasUriHost(dotHostname, scheme: 'dot')) {
      showVhostsToast(context, 'DoT 需要有效的主机名用于 TLS 校验');
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
        type: _type,
        server: server,
        secondaryServer: _type == DnsProfileType.plain ? secondary : '',
        dotHostname: _type == DnsProfileType.dot ? dotHostname : '',
        timeoutMs: timeoutMs,
        retryCount: retryCount,
        enabled: _enabled,
        healthStatus: widget.existing?.healthStatus ?? DnsHealthStatus.unknown,
        healthDetail: widget.existing?.healthDetail ?? '新建配置，等待健康检查',
        latencyMs: widget.existing?.latencyMs,
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

class _InfoItem extends StatelessWidget {
  const _InfoItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 84, child: Text(label, style: theme.textTheme.muted)),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.p,
            ),
          ),
        ],
      ),
    );
  }
}

const List<DnsProfileType> _editableDnsProfileTypes = [
  DnsProfileType.doh,
  DnsProfileType.plain,
  DnsProfileType.dot,
];

bool _isValidServerForType(String value, DnsProfileType type) {
  return switch (type) {
    DnsProfileType.plain => hasUriHost(value, scheme: 'dns'),
    DnsProfileType.doh => _isValidDohUrl(value),
    DnsProfileType.dot => hasUriHost(value, scheme: 'dot'),
    DnsProfileType.system => true,
  };
}

bool _isValidDohUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

String _serverHintText(DnsProfileType type) {
  return switch (type) {
    DnsProfileType.plain => '例如 223.5.5.5 或 223.5.5.5:53',
    DnsProfileType.doh => 'https://dns.example.com/dns-query',
    DnsProfileType.dot => '例如 1.1.1.1:853',
    DnsProfileType.system => '系统 DNS',
  };
}

String _serverLabelText(DnsProfileType type) {
  return switch (type) {
    DnsProfileType.plain => '主服务器',
    DnsProfileType.doh => 'DoH URL',
    DnsProfileType.dot => 'DoT 服务器',
    DnsProfileType.system => '系统 DNS',
  };
}
