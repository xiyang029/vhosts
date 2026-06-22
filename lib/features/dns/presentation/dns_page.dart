import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_state.dart';
import '../../../app/app_theme.dart';
import '../../../shared/utils/app_utils.dart';
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
    final theme = ShadTheme.of(context);

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
                    if (!_isQuickSwitchProfile(activeProfile.id)) ...[
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
              children: [
                for (final (index, preset) in _quickSwitchProfiles.indexed) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: preset.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(preset.icon, color: preset.color),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                preset.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                preset.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.muted,
                              ),
                            ],
                          ),
                        ),
                        ShadButton.ghost(
                          onPressed: () => _activatePreset(preset),
                          child: Icon(
                            preset.profile.id == activeProfile.id
                                ? LucideIcons.circleCheck
                                : LucideIcons.zap,
                            color: preset.profile.id == activeProfile.id
                                ? vhostsSuccess
                                : preset.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (index != _quickSwitchProfiles.length - 1)
                    const ShadSeparator.horizontal(),
                ],
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
                ...app.visibleDnsProfiles
                    .where(
                      (profile) =>
                          !quickSwitchDnsProfileIds.contains(profile.id),
                    )
                    .map(
                      (profile) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _DnsProfileCard(
                          profile: profile,
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

  void _activatePreset(_QuickSwitchProfile preset) {
    final app = AppScope.of(context);
    final exists = app.dnsProfiles.any(
      (profile) => profile.id == preset.profile.id,
    );
    if (!exists) {
      app.upsertDnsProfile(preset.profile);
    }
    app.setActiveDnsProfile(preset.profile.id);
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

class _QuickSwitchProfile {
  const _QuickSwitchProfile({
    required this.profile,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final DnsProfile profile;
  final String subtitle;
  final IconData icon;
  final Color color;

  String get name => profile.name;
}

const List<_QuickSwitchProfile> _quickSwitchProfiles = [
  _QuickSwitchProfile(
    profile: DnsProfile(
      id: aliyunDefaultDnsProfileId,
      name: '阿里云 DNS',
      type: DnsProfileType.plain,
      server: '223.5.5.5:53',
      secondaryServer: '223.6.6.6:53',
      dohUrl: '',
      dotHostname: '',
      timeoutMs: 1500,
      retryCount: 2,
      enabled: true,
      healthStatus: DnsHealthStatus.unknown,
      healthDetail: '阿里云公共递归 DNS，适合作为默认快速切换项',
      latencyMs: null,
    ),
    subtitle: '223.5.5.5 / 223.6.6.6',
    icon: LucideIcons.cloud,
    color: vhostsAliyunDns,
  ),
  _QuickSwitchProfile(
    profile: DnsProfile(
      id: googleDefaultDnsProfileId,
      name: 'Google Public DNS',
      type: DnsProfileType.plain,
      server: '8.8.8.8:53',
      secondaryServer: '8.8.4.4:53',
      dohUrl: '',
      dotHostname: '',
      timeoutMs: 1500,
      retryCount: 2,
      enabled: true,
      healthStatus: DnsHealthStatus.unknown,
      healthDetail: 'Google 公共递归 DNS，稳定性和可用性较高',
      latencyMs: null,
    ),
    subtitle: '8.8.8.8 / 8.8.4.4',
    icon: LucideIcons.earth,
    color: vhostsGoogleDns,
  ),
  _QuickSwitchProfile(
    profile: DnsProfile(
      id: cloudflareDefaultDnsProfileId,
      name: 'Cloudflare DNS',
      type: DnsProfileType.plain,
      server: '1.1.1.1:53',
      secondaryServer: '1.0.0.1:53',
      dohUrl: '',
      dotHostname: '',
      timeoutMs: 1500,
      retryCount: 2,
      enabled: true,
      healthStatus: DnsHealthStatus.unknown,
      healthDetail: 'Cloudflare 公共递归 DNS，延迟和隐私表现都不错',
      latencyMs: null,
    ),
    subtitle: '1.1.1.1 / 1.0.0.1',
    icon: LucideIcons.shield,
    color: vhostsCloudflareDns,
  ),
];

bool _isQuickSwitchProfile(String id) {
  return quickSwitchDnsProfileIds.contains(id);
}

class _DnsProfileCard extends StatelessWidget {
  const _DnsProfileCard({
    required this.profile,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final DnsProfile profile;
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
              if (!_isQuickSwitchProfile(profile.id)) ...[
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
  late final TextEditingController _plainServerController;
  late final TextEditingController _dohUrlController;
  late final TextEditingController _dotServerController;
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
    _plainServerController = TextEditingController(
      text: widget.existing?.server ?? '',
    );
    _dohUrlController = TextEditingController(
      text: widget.existing?.type == DnsProfileType.doh
          ? (widget.existing?.dohUrl.isNotEmpty == true
                ? widget.existing!.dohUrl
                : widget.existing?.server ?? '')
          : '',
    );
    _dotServerController = TextEditingController(
      text: widget.existing?.type == DnsProfileType.dot
          ? widget.existing?.server ?? ''
          : '',
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
    _type = widget.existing?.type ?? DnsProfileType.plain;
    _enabled = widget.existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _plainServerController.dispose();
    _dohUrlController.dispose();
    _dotServerController.dispose();
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
            ShadInput(
              controller: _nameController,
              placeholder: const Text('例如 家庭 DNS'),
            ),
            const SizedBox(height: 12),
            if (_type == DnsProfileType.plain) ...[
              ShadInput(
                controller: _plainServerController,
                placeholder: const Text('例如 223.5.5.5 或 223.5.5.5:53'),
              ),
              const SizedBox(height: 12),
              ShadInput(
                controller: _secondaryController,
                placeholder: const Text('备用服务器，可选'),
              ),
            ] else if (_type == DnsProfileType.doh) ...[
              ShadInput(
                controller: _dohUrlController,
                placeholder: const Text('https://dns.example.com/dns-query'),
              ),
            ] else if (_type == DnsProfileType.dot) ...[
              ShadInput(
                controller: _dotServerController,
                placeholder: const Text('例如 1.1.1.1:853'),
              ),
              const SizedBox(height: 12),
              ShadInput(
                controller: _dotController,
                placeholder: const Text('例如 cloudflare-dns.com'),
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
                  child: ShadInput(
                    keyboardType: TextInputType.number,
                    controller: _timeoutController,
                    placeholder: const Text('超时 (ms)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ShadInput(
                    keyboardType: TextInputType.number,
                    controller: _retryController,
                    placeholder: const Text('重试次数'),
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
    final plainServer = _plainServerController.text.trim();
    final dohUrl = _dohUrlController.text.trim();
    final dotServer = _dotServerController.text.trim();
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
    final normalizedServer = switch (_type) {
      DnsProfileType.plain => plainServer,
      DnsProfileType.doh => dohUrl,
      DnsProfileType.dot => dotServer,
      DnsProfileType.system => plainServer,
    };
    if (!_isValidServerForType(normalizedServer, _type)) {
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
        server: _type == DnsProfileType.plain || _type == DnsProfileType.dot
            ? normalizedServer
            : '',
        secondaryServer: _type == DnsProfileType.plain ? secondary : '',
        dohUrl: _type == DnsProfileType.doh ? normalizedServer : '',
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
  DnsProfileType.plain,
  DnsProfileType.doh,
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
