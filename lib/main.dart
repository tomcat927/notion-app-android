import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notion_app/app/theme/app_theme.dart';
import 'package:notion_app/features/home/home_screen.dart';
import 'package:notion_app/features/auth/login_screen.dart';
import 'package:notion_app/core/notion_auth.dart';
import 'package:notion_app/core/network_proxy.dart';

import 'package:notion_app/core/app_logger.dart';
import 'package:notion_app/core/cache_cleanup_service.dart';
import 'package:notion_app/core/notion_web_session.dart';

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        unawaited(
          AppLogger.logCrash(
            'FlutterError',
            details.exceptionAsString(),
            details.stack,
          ),
        );
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        unawaited(
          AppLogger.logCrash('PlatformDispatcher', error, stackTrace),
        );
        return true;
      };

      await NetworkProxy.initialize();
      await SharedPreferences.getInstance();
      await AppLogger.init();
      unawaited(CacheCleanupService.cleanupStartupCaches());

      final token = await NotionAuth.getToken();
      final hasToken = token != null && token.isNotEmpty;

      await NotionWebSession.instance.loadFromStorage();

      runApp(NotionApp(isLoggedIn: hasToken));
    },
    (error, stackTrace) {
      unawaited(AppLogger.logCrash('runZonedGuarded', error, stackTrace));
    },
  );
}

class NotionApp extends StatelessWidget {
  final bool isLoggedIn;

  const NotionApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notion Lite',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: isLoggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
