import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'app/app_shell.dart';
import 'app/app_state.dart';
import 'app/app_theme.dart';

void main() {
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

  @override
  void initState() {
    super.initState();
    _bootstrapFuture = _appState.hydrate();
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
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
            title: 'vhosts',
            theme: materialTheme.copyWith(
              textTheme: materialTheme.textTheme.apply(
                fontFamilyFallback: _fontFamilyFallback,
              ),
            ),
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

const List<String> _fontFamilyFallback = [
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
  'SimHei',
  'Arial Unicode MS',
];
