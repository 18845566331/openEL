import 'package:flutter/material.dart';

class AppTheme {
  static const Color canvas = Color(0xFF07121F);
  static const Color panel = Color(0xFF0B1A2D);
  static const Color panelAlt = Color(0xFF071726);
  static const Color stroke = Color(0xFF0B2A4A);
  static const Color primary = Color(0xFF1D4ED8);
  static const Color accent = Color(0xFF0F766E);

  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      primary: primary,
      secondary: Color(0xFF22D3EE),
      surface: panel,
      error: Color(0xFFEF4444),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: 'Microsoft YaHei',
      dividerColor: stroke,
      cardTheme: const CardThemeData(
        elevation: 0,
        color: panel,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: Color(0xFFE2E8F0), height: 1.45),
        titleMedium: TextStyle(color: Color(0xFFE6F0FF), fontWeight: FontWeight.w700),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF22D3EE)),
        ),
        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
        hintStyle: const TextStyle(color: Color(0xFF64748B)),
      ),
    );
  }
}
