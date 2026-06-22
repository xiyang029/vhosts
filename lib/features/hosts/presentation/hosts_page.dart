import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_state.dart';
import '../../../app/app_theme.dart';
import '../domain/host_rule.dart';

const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(18, 18, 18, 28);
const EdgeInsets _cardPadding = EdgeInsets.all(16);
const EdgeInsets _sheetContentPadding = EdgeInsets.fromLTRB(2, 16, 2, 2);

class HostsPage extends StatefulWidget {
  const HostsPage({super.key});

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  final TextEditingController _searchController = TextEditingController();
  int _filterIndex = 0;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<HostRule> get _filteredRules {
    final app = AppScope.of(context);
    final query = _searchController.text.trim().toLowerCase();
    return app.hostRules.where((rule) {
      final matchesQuery =
          query.isEmpty ||
          rule.domain.toLowerCase().contains(query) ||
          rule.targetIp.toLowerCase().contains(query) ||
          rule.note.toLowerCase().contains(query);
      final matchesFilter = switch (_filterIndex) {
        1 => rule.enabled,
        2 => !rule.enabled,
        _ => true,
      };
      return matchesQuery && matchesFilter;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
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
                ShadInput(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  leading: const Icon(LucideIcons.search),
                  placeholder: const Text('搜索域名、IP、备注'),
                ),
                const SizedBox(height: 14),
                ShadTabs<int>(
                  value: _filterIndex,
                  onChanged: (value) {
                    setState(() => _filterIndex = value);
                  },
                  tabs: [
                    for (final tab in _filterTabs)
                      ShadTab(
                        value: tab.value,
                        content: const SizedBox.shrink(),
                        child: Text(tab.label),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ShadButton(
                  onPressed: _openRuleEditor,
                  leading: const Icon(LucideIcons.plus),
                  child: const Text('新增规则'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ShadButton.outline(
                  onPressed: _openImportSheet,
                  leading: const Icon(LucideIcons.fileUp),
                  child: const Text('导入'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_filteredRules.isEmpty)
            ShadCard(
              padding: _cardPadding,
              child: Center(child: Text('没有找到规则', style: theme.textTheme.p)),
            )
          else
            ..._filteredRules.map((rule) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _HostRuleCard(
                  rule: rule,
                  onToggle: (value) {
                    AppScope.of(context).setHostRuleEnabled(rule.id, value);
                  },
                  onEdit: () => _openRuleEditor(existing: rule),
                  onDelete: () => _confirmDeleteRule(rule),
                ),
              );
            }),
        ],
      ),
    );
  }

  Future<void> _openRuleEditor({HostRule? existing}) async {
    final app = AppScope.of(context);
    final result = await showShadSheet<HostRule>(
      context: context,
      side: ShadSheetSide.bottom,
      builder: (context) => _RuleEditorSheet(existing: existing),
    );

    if (result == null) {
      return;
    }

    app.upsertHostRule(result);
  }

  Future<void> _openImportSheet() async {
    final app = AppScope.of(context);
    final result = await showShadSheet<String>(
      context: context,
      side: ShadSheetSide.bottom,
      builder: (context) => const _HostsImportSheet(),
    );

    if (result == null || result.trim().isEmpty) {
      return;
    }

    final imported = app.importHostsText(result);
    if (!mounted) {
      return;
    }

    showVhostsToast(context, '已导入 $imported 条规则');
  }

  Future<void> _confirmDeleteRule(HostRule rule) async {
    final app = AppScope.of(context);
    final confirmed =
        await showShadDialog<bool>(
          context: context,
          builder: (context) => ShadDialog.alert(
            title: const Text('删除规则'),
            description: Text('确认删除 ${rule.domain} 吗？'),
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

    app.deleteHostRule(rule.id);
    if (!mounted) {
      return;
    }

    showVhostsToast(context, '已删除 ${rule.domain}');
  }
}

const List<({int value, String label})> _filterTabs = [
  (value: 0, label: '全部'),
  (value: 1, label: '启用'),
  (value: 2, label: '禁用'),
];

class _HostRuleCard extends StatelessWidget {
  const _HostRuleCard({
    required this.rule,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final HostRule rule;
  final ValueChanged<bool> onToggle;
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
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rule.domain, style: theme.textTheme.large),
                    const SizedBox(height: 4),
                    Text(
                      '${rule.matchType.label} · ${rule.targetIp}',
                      style: theme.textTheme.muted,
                    ),
                  ],
                ),
              ),
              ShadSwitch(value: rule.enabled, onChanged: onToggle),
            ],
          ),
          const SizedBox(height: 8),
          if (rule.note.trim().isNotEmpty)
            Text(
              rule.note,
              style: theme.textTheme.p,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
            ),
          ),
        ],
      ),
    );
  }
}

class _RuleEditorSheet extends StatefulWidget {
  const _RuleEditorSheet({this.existing});

  final HostRule? existing;

  @override
  State<_RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _HostsImportSheet extends StatefulWidget {
  const _HostsImportSheet();

  @override
  State<_HostsImportSheet> createState() => _HostsImportSheetState();
}

class _HostsImportSheetState extends State<_HostsImportSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadSheet(
      title: const Text('导入 Hosts'),
      constraints: const BoxConstraints(maxWidth: 560),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导入'),
        ),
      ],
      child: Padding(
        padding: _sheetContentPadding,
        child: ShadTextarea(
          controller: _controller,
          minHeight: 180,
          maxHeight: 320,
          placeholder: const Text('每行一条：IP 域名1 域名2 ...'),
        ),
      ),
    );
  }
}

class _RuleEditorSheetState extends State<_RuleEditorSheet> {
  late final TextEditingController _domainController;
  late final TextEditingController _ipController;
  late final TextEditingController _noteController;
  late HostMatchType _matchType;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _domainController = TextEditingController(
      text: widget.existing?.domain ?? '',
    );
    _ipController = TextEditingController(
      text: widget.existing?.targetIp ?? '',
    );
    _noteController = TextEditingController(text: widget.existing?.note ?? '');
    _matchType = widget.existing?.matchType ?? HostMatchType.exact;
    _enabled = widget.existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _domainController.dispose();
    _ipController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadSheet(
      title: Text(widget.existing == null ? '新增规则' : '编辑规则'),
      constraints: const BoxConstraints(maxWidth: 560),
      actions: [ShadButton(onPressed: _save, child: const Text('保存'))],
      child: Padding(
        padding: _sheetContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ShadInput(
              controller: _domainController,
              placeholder: Text(_domainHintText(_matchType)),
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('匹配类型'),
                const SizedBox(height: 6),
                ShadSelect<HostMatchType>(
                  minWidth: double.infinity,
                  initialValue: _matchType,
                  placeholder: const Text('匹配类型'),
                  options: HostMatchType.values
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
                      setState(() => _matchType = selected);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _matchTypeHelpText(_matchType),
              style: ShadTheme.of(context).textTheme.muted,
            ),
            const SizedBox(height: 12),
            ShadInput(
              controller: _ipController,
              placeholder: const Text('例如 127.0.0.1'),
            ),
            const SizedBox(height: 12),
            ShadInput(
              controller: _noteController,
              placeholder: const Text('备注，可选'),
            ),
            const SizedBox(height: 12),
            Row(
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
          ],
        ),
      ),
    );
  }

  void _save() {
    final domain = _domainController.text.trim();
    final ip = _ipController.text.trim();

    if (domain.isEmpty || ip.isEmpty) {
      showVhostsToast(context, '请先填写域名和目标 IP');
      return;
    }
    if (!_isValidHostPattern(domain, _matchType)) {
      showVhostsToast(context, '域名或匹配类型格式不正确');
      return;
    }
    if (Uri.tryParse('http://$ip')?.host.isEmpty ?? true) {
      showVhostsToast(context, '目标 IP 格式不正确');
      return;
    }
    if (_noteController.text.trim().length > 40) {
      showVhostsToast(context, '备注请控制在 40 个字符以内');
      return;
    }

    final now = DateTime.now();
    Navigator.of(context).pop(
      HostRule(
        id: widget.existing?.id ?? 'hr_${now.millisecondsSinceEpoch}',
        domain: domain,
        matchType: _matchType,
        targetIp: ip,
        enabled: _enabled,
        note: _noteController.text.trim(),
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }
}

bool _isValidHostPattern(String domain, HostMatchType matchType) {
  final value = domain.trim();
  if (value.isEmpty) {
    return false;
  }
  return switch (matchType) {
    HostMatchType.exact => !value.contains('*'),
    HostMatchType.suffix => value.startsWith('*.') && value.length > 2,
    HostMatchType.wildcard => value.contains('*'),
  };
}

String _domainHintText(HostMatchType matchType) {
  return switch (matchType) {
    HostMatchType.exact => '例如 example.com',
    HostMatchType.suffix => '例如 *.example.com',
    HostMatchType.wildcard => '例如 api-*.example.com',
  };
}

String _matchTypeHelpText(HostMatchType matchType) {
  return switch (matchType) {
    HostMatchType.exact => '精确匹配：直接填写完整域名，例如 example.com',
    HostMatchType.suffix => '后缀匹配：必须以 *. 开头，例如 *.example.com',
    HostMatchType.wildcard => '通配符匹配：包含 * 即可，例如 api-*.example.com',
  };
}
