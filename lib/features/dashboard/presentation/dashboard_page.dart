import 'package:flutter/widgets.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../../app/app_state.dart';
import '../../../app/app_theme.dart';
import '../../../core/platform/vpn_status.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final status = app.vpnStatus;

    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _VpnToggleCircle(status: status, onPressed: app.toggleVpn),
              const SizedBox(height: 18),
              _VpnHint(status: status),
            ],
          ),
        ),
      ),
    );
  }
}

class _VpnToggleCircle extends StatelessWidget {
  const _VpnToggleCircle({required this.status, required this.onPressed});

  final VpnStatus status;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    final color = _circleColor(status);
    final enabled = !status.isTransitioning;
    return Semantics(
      button: true,
      enabled: enabled,
      label: _vpnActionLabel(status),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 168,
          height: 168,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(status.icon, color: vhostsOnAccent, size: 48),
        ),
      ),
    );
  }
}

class _VpnHint extends StatelessWidget {
  const _VpnHint({required this.status});

  final VpnStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Text(
      _vpnHintText(status),
      style: theme.textTheme.p.copyWith(
        color: theme.colorScheme.mutedForeground,
      ),
      textAlign: TextAlign.center,
    );
  }
}

Color _circleColor(VpnStatus status) {
  return switch (status) {
    VpnStatus.running => vhostsVpnActive,
    VpnStatus.unauthorized => vhostsVpnUnauthorized,
    VpnStatus.starting || VpnStatus.stopping => vhostsNeutral,
    VpnStatus.error => vhostsError,
    VpnStatus.idle => vhostsVpnInactive,
  };
}

String _vpnActionLabel(VpnStatus status) {
  return switch (status) {
    VpnStatus.running => '停止 VPN',
    VpnStatus.starting => 'VPN 正在启动',
    VpnStatus.stopping => 'VPN 正在停止',
    VpnStatus.unauthorized || VpnStatus.error || VpnStatus.idle => '启动 VPN',
  };
}

String _vpnHintText(VpnStatus status) {
  return switch (status) {
    VpnStatus.running => '点击停止 VPN',
    VpnStatus.starting => 'VPN 正在启动',
    VpnStatus.stopping => 'VPN 正在停止',
    VpnStatus.unauthorized => '点击授权并启动',
    VpnStatus.error => '点击重试 VPN',
    VpnStatus.idle => '点击启动 VPN',
  };
}
