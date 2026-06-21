import 'package:flutter/material.dart';
import 'screens/browser_screen.dart';
import 'screens/downloads_screen.dart';
import 'theme/app_theme.dart';

class AbobiGramApp extends StatelessWidget {
  const AbobiGramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AbobiGram',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: '/',
      routes: {
        '/': (_) => const BrowserScreen(),
        '/downloads': (_) => const DownloadsScreen(),
      },
    );
  }
}
