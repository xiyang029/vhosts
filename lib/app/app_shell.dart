import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../features/dashboard/presentation/dashboard_page.dart';
import '../features/dns/presentation/dns_page.dart';
import '../features/hosts/presentation/hosts_page.dart';
import '../features/settings/presentation/settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  late final List<Widget> _pages = const [
    DashboardPage(),
    HostsPage(),
    DnsPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        height: 48,
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          for (final item in _shellDestinations)
            NavigationDestination(icon: Icon(item.icon), label: item.label),
        ],
      ),
    );
  }
}

class _ShellDestination {
  const _ShellDestination({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

const List<_ShellDestination> _shellDestinations = [
  _ShellDestination(label: '首页', icon: LucideIcons.house),
  _ShellDestination(label: 'Hosts', icon: LucideIcons.braces),
  _ShellDestination(label: 'DNS', icon: LucideIcons.globe),
  _ShellDestination(label: '设置', icon: LucideIcons.settings),
];
