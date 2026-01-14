import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Import SharedPreferences
import 'app_theme.dart';

class ThemeProvider with ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system; // Default to system theme initially
  static const String _themeKey = 'user_theme_mode'; // Key for SharedPreferences

  ThemeProvider() {
    _loadThemeMode(); // Load theme mode when provider is created
  }

  ThemeMode get themeMode => _themeMode;

  // This getter needs to be more robust if ThemeMode.system is the default
  // It should reflect the *actual* applied theme if system mode is dark
  bool get isDarkMode {
    if (_themeMode == ThemeMode.system) {
      // If system mode, check the platform brightness
      return WidgetsBinding.instance.window.platformBrightness == Brightness.dark;
    }
    return _themeMode == ThemeMode.dark;
  }

  // Method to load the saved theme preference
  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedTheme = prefs.getString(_themeKey);

    if (savedTheme == 'dark') {
      _themeMode = ThemeMode.dark;
    } else if (savedTheme == 'light') {
      _themeMode = ThemeMode.light;
    } else {
      _themeMode = ThemeMode.system; // Fallback to system if nothing saved or invalid
    }
    notifyListeners(); // Notify listeners after loading the theme
  }

  // Method to toggle and save the theme preference
  void toggleTheme(bool isOn) async {
    _themeMode = isOn ? ThemeMode.dark : ThemeMode.light;
    notifyListeners(); // Notify listeners immediately for UI update

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, isOn ? 'dark' : 'light'); // Save the preference
  }
}
