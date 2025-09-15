import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

enum AppThemeMode { system, light, dark }

enum AppColorScheme {
  deepPurple,
  purple,
  deepPurpleAccent,
  indigo,
  blueAccent,
  cyanAccent,
  deepOrange,
  tealAccent,
  indigoAccent,
  lightGreen,
  pink,
  red,
  green,
  orange,
  amber,
  lime,
  amoled,
}

class ThemePreferences {
  static const String _themeKey = 'theme_mode';
  static const String _colorKey = 'color_scheme';

  // Guardar la preferencia del tema
  static Future<void> setThemeMode(AppThemeMode themeMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeKey, themeMode.index);
  }

  // Obtener la preferencia del tema guardada
  static Future<AppThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();

    try {
      // First try to get as integer (new format)
      final index = prefs.getInt(_themeKey);
      if (index != null && index >= 0 && index < AppThemeMode.values.length) {
        return AppThemeMode.values[index];
      }
    } catch (e) {
      // If there's an error reading as int, it might be the old boolean format
    }

    try {
      // Migration: Check for old boolean value with same key
      final oldIsDarkMode = prefs.getBool(_themeKey);
      if (oldIsDarkMode != null) {
        // Convert old boolean to new enum
        final newThemeMode = oldIsDarkMode
            ? AppThemeMode.dark
            : AppThemeMode.light;
        // Save in new format
        await prefs.setInt(_themeKey, newThemeMode.index);
        return newThemeMode;
      }
    } catch (e) {
      // If there's an error reading as bool, continue to default
    }

    // Default to system theme
    return AppThemeMode.system;
  }

  // Guardar la preferencia del color
  static Future<void> setColorScheme(AppColorScheme colorScheme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorKey, colorScheme.index);
  }

  // Obtener la preferencia del color guardada
  static Future<AppColorScheme> getColorScheme() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_colorKey);
    if (index != null && index >= 0 && index < AppColorScheme.values.length) {
      return AppColorScheme.values[index];
    }
    // Default to deepPurple
    return AppColorScheme.deepPurple;
  }

  // Limpiar la preferencia del tema (resetear a valores por defecto)
  static Future<void> clearThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_themeKey);
  }

  // Limpiar la preferencia del color (resetear a valores por defecto)
  static Future<void> clearColorScheme() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_colorKey);
  }

  // Obtener el Color correspondiente al esquema de color
  static Color getColorFromScheme(AppColorScheme scheme) {
    switch (scheme) {
      case AppColorScheme.deepPurple:
        return Colors.deepPurple;
      case AppColorScheme.purple:
        return Colors.purple;
      case AppColorScheme.deepPurpleAccent:
        return Colors.deepPurpleAccent;
      case AppColorScheme.indigo:
        return Colors.indigo;
      case AppColorScheme.blueAccent:
        return Colors.blueAccent;
      case AppColorScheme.cyanAccent:
        return Colors.cyanAccent;
      case AppColorScheme.deepOrange:
        return Colors.deepOrange;
      case AppColorScheme.tealAccent:
        return Colors.tealAccent;
      case AppColorScheme.indigoAccent:
        return Colors.indigoAccent;
      case AppColorScheme.lightGreen:
        return Colors.lightGreen;
      case AppColorScheme.pink:
        return Colors.pink;
      case AppColorScheme.red:
        return Colors.red;
      case AppColorScheme.green:
        return Colors.green;
      case AppColorScheme.orange:
        return Colors.orange;
      case AppColorScheme.amber:
        return Colors.amber;
      case AppColorScheme.lime:
        return Colors.lime;
      case AppColorScheme.amoled:
        return Colors.black;
    }
  }

  // Obtener el nombre del color para mostrar en la UI
  static String getColorName(AppColorScheme scheme) {
    switch (scheme) {
      case AppColorScheme.deepPurple:
        return 'Deep Purple';
      case AppColorScheme.purple:
        return 'Purple';
      case AppColorScheme.deepPurpleAccent:
        return 'Deep Purple Accent';
      case AppColorScheme.indigo:
        return 'Indigo';
      case AppColorScheme.blueAccent:
        return 'Blue Accent';
      case AppColorScheme.cyanAccent:
        return 'Cyan Accent';
      case AppColorScheme.deepOrange:
        return 'Deep Orange';
      case AppColorScheme.tealAccent:
        return 'Teal Accent';
      case AppColorScheme.indigoAccent:
        return 'Indigo Accent';
      case AppColorScheme.lightGreen:
        return 'Light Green';
      case AppColorScheme.pink:
        return 'Pink';
      case AppColorScheme.red:
        return 'Red';
      case AppColorScheme.green:
        return 'Green';
      case AppColorScheme.orange:
        return 'Orange';
      case AppColorScheme.amber:
        return 'Amber';
      case AppColorScheme.lime:
        return 'Lime';
      case AppColorScheme.amoled:
        return 'AMOLED Black';
    }
  }
}

/// Helper function to format folder paths by removing the Android storage prefix
String formatFolderPath(String path) {
  const storagePrefix = '/storage/emulated/0';
  if (path.startsWith(storagePrefix)) {
    return path.substring(storagePrefix.length);
  }
  return path;
}