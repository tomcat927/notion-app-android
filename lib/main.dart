import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:notion_app/app/theme/app_theme.dart';
import 'package:notion_app/features/home/home_screen.dart';
import 'package:notion_app/features/auth/login_screen.dart';
import 'package:notion_app/core/notion_auth.dart';

import 'package:notion_app/core/app_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SharedPreferences.getInstance();
  await AppLogger.init();

  final token = await NotionAuth.getToken();
  final hasToken = token != null && token.isNotEmpty;

  runApp(NotionApp(isLoggedIn: hasToken));
}

class NotionApp extends StatelessWidget {
  final bool isLoggedIn;

  const NotionApp({super.key, required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notion App',
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
