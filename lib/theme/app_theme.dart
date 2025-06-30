import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFFEF4444);
  static const Color secondaryColor = Color(0xFFB91C1C);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color dangerColor = Color(0xFFEF4444);
  static const Color darkColor = Color(0xFF1F2937);
  static const Color backgroundColor = Color(0xFFF3F4F6);

  static ThemeData get lightTheme {
    return ThemeData(
      scaffoldBackgroundColor: backgroundColor,
      primaryColor: primaryColor,
      fontFamily: 'Inter',
      colorScheme: ColorScheme.light(
        primary: primaryColor,
        secondary: secondaryColor,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData.dark().copyWith(
      primaryColor: primaryColor,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: secondaryColor,
      ),
    );
  }
}
