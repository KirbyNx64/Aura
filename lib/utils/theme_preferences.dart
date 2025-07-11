import 'package:shared_preferences/shared_preferences.dart';

class ThemePreferences {
  static const String _themeKey = 'theme_mode';
  
  // Guardar la preferencia del tema
  static Future<void> setThemeMode(bool isDarkMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeKey, isDarkMode);
  }
  
  // Obtener la preferencia del tema guardada
  static Future<bool> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    // Por defecto, usar tema oscuro si no hay preferencia guardada
    return prefs.getBool(_themeKey) ?? true;
  }
  
  // Limpiar la preferencia del tema (resetear a valores por defecto)
  static Future<void> clearThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_themeKey);
  }
} 