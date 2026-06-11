import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum VpnStatus { unauthorized, idle, starting, running, stopping, error }

extension VpnStatusX on VpnStatus {
  IconData get icon => switch (this) {
    VpnStatus.unauthorized => LucideIcons.lock,
    VpnStatus.idle => LucideIcons.circlePause,
    VpnStatus.starting => LucideIcons.loaderCircle,
    VpnStatus.running => LucideIcons.shield,
    VpnStatus.stopping => LucideIcons.loaderCircle,
    VpnStatus.error => LucideIcons.circleAlert,
  };

  bool get isTransitioning => switch (this) {
    VpnStatus.starting || VpnStatus.stopping => true,
    _ => false,
  };
}
