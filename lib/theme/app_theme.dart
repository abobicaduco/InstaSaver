import 'package:flutter/material.dart';

class AppTheme {
  static const Color primary = Color(0xFF8B5CF6);   // violeta
  static const Color secondary = Color(0xFFEF4444); // vermelho
  static const Color tertiary = Color(0xFF3B82F6);  // azul
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF13131F);
  static const Color card = Color(0xFF1C1C2E);

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: primary,
          secondary: secondary,
          tertiary: tertiary,
          surface: surface,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: surface,
          elevation: 0,
          centerTitle: true,
          foregroundColor: Colors.white,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: primary,
          foregroundColor: Colors.white,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
}
