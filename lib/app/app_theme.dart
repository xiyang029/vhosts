import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const vhostsAccent = Color(0xFFFB7299);
const vhostsSoftBorder = Color(0xFFE7E9EE);
const vhostsMutedText = Color(0xFF7E8492);
const vhostsPrimaryText = Color(0xFF2F3440);
const vhostsScaffoldBackground = Colors.white;
const vhostsOnAccent = Color(0xFFFFFFFF);
const vhostsError = Color(0xFFE65C84);
const vhostsSuccess = Color(0xFF027A48);
const vhostsWarning = Color(0xFFB54708);
const vhostsDanger = Color(0xFFB42318);
const vhostsNeutral = Color(0xFF667085);
const vhostsVpnActive = vhostsSuccess;
const vhostsVpnInactive = vhostsAccent;
const vhostsVpnUnauthorized = vhostsWarning;
const vhostsAliyunDns = Color(0xFF0A84FF);
const vhostsGoogleDns = Color(0xFF155EEF);
const vhostsCloudflareDns = Color(0xFF7A5AF8);

class _VhostsToastPlatformService {
  static const MethodChannel _channel = MethodChannel('vhosts/toast');

  static bool get _supportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> showToast(String message, {bool long = false}) async {
    if (!_supportedPlatform) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('showToast', <String, Object?>{
        'message': message,
        'long': long,
      });
    } on PlatformException {
      return;
    }
  }
}

void showVhostsToast(
  BuildContext context,
  String message, {
  bool long = false,
}) {
  _VhostsToastPlatformService.showToast(message, long: long);

  if (_VhostsToastPlatformService._supportedPlatform || !context.mounted) {
    return;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: long ? const Duration(seconds: 4) : const Duration(seconds: 2),
    ),
  );
}

ThemeData buildVhostsMaterialTheme(ThemeData baseTheme) {
  return baseTheme.copyWith(
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: Colors.transparent,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: isSelected ? vhostsAccent : vhostsMutedText,
          size: 20,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final isSelected = states.contains(WidgetState.selected);
        return TextStyle(
          color: isSelected ? vhostsAccent : vhostsMutedText,
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
    ),
  );
}

ShadThemeData buildVhostsShadTheme() {
  return ShadThemeData(
    disableSecondaryBorder: true,
    radius: const BorderRadius.all(Radius.circular(16)),
    colorScheme: const ShadZincColorScheme.light(
      primary: vhostsAccent,
      foreground: vhostsPrimaryText,
      mutedForeground: vhostsMutedText,
      background: vhostsScaffoldBackground,
      border: vhostsSoftBorder,
      input: vhostsSoftBorder,
      ring: vhostsAccent,
      destructive: vhostsError,
    ),
    alertDialogTheme: const ShadDialogTheme(
      useSafeArea: false,
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24),
      radius: BorderRadius.all(Radius.circular(16)),
      removeBorderRadiusWhenTiny: false,
    ),
    primaryDialogTheme: const ShadDialogTheme(
      useSafeArea: false,
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24),
      radius: BorderRadius.all(Radius.circular(16)),
      removeBorderRadiusWhenTiny: false,
    ),
    sheetTheme: const ShadSheetTheme(
      useSafeArea: false,
      radius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
  );
}
