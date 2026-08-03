import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'app/app_theme.dart';
import 'core/services/app_update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VhostsApp());
}

class VhostsApp extends StatefulWidget {
  const VhostsApp({super.key});

  @override
  State<VhostsApp> createState() => _VhostsAppState();
}

class _VhostsAppState extends State<VhostsApp> {
  late final AppState _appState = AppState();
  late final Future<void> _bootstrapFuture;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AppUpdateService _updateService = AppUpdateService();
  bool _startupUpdateCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _appState.hydrate();
    _bootstrapFuture.then((_) {
      if (!mounted || _startupUpdateCheckScheduled) {
        return;
      }
      _startupUpdateCheckScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_runStartupUpdateCheck());
      });
    });
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  Future<void> _runStartupUpdateCheck() async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return;
    }
    await _updateService.checkForUpdates(context, showUpToDateToast: false);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      notifier: _appState,
      child: ShadApp.custom(
        theme: buildVhostsShadTheme(),
        appBuilder: (context) {
          final materialTheme = buildVhostsMaterialTheme(Theme.of(context));
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            navigatorKey: _navigatorKey,
            title: 'vhosts',
            theme: materialTheme,
            localizationsDelegates: const [
              GlobalShadLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            builder: (context, child) => ShadAppBuilder(child: child!),
            home: FutureBuilder<void>(
              future: _bootstrapFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox.shrink();
                }
                return const AppShell();
              },
            ),
          );
        },
      ),
    );
  }
}
