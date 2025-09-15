import 'package:shared_preferences/shared_preferences.dart';

class GesturePreferences {
  static const String _keyDisableClosePlayer = 'disable_gesture_close_player';
  static const String _keyDisableOpenPlaylist = 'disable_gesture_open_playlist';
  static const String _keyDisableChangeSong = 'disable_gesture_change_song';
  static const String _keyDisableOpenPlayer = 'disable_gesture_open_player';

  // Obtener si el gesto de cerrar reproductor está desactivado
  static Future<bool> isClosePlayerDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDisableClosePlayer) ?? false;
  }

  // Establecer si el gesto de cerrar reproductor está desactivado
  static Future<void> setClosePlayerDisabled(bool disabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableClosePlayer, disabled);
  }

  // Obtener si el gesto de abrir lista de reproducción está desactivado
  static Future<bool> isOpenPlaylistDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDisableOpenPlaylist) ?? false;
  }

  // Establecer si el gesto de abrir lista de reproducción está desactivado
  static Future<void> setOpenPlaylistDisabled(bool disabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableOpenPlaylist, disabled);
  }

  // Obtener si el gesto de cambiar canción está desactivado
  static Future<bool> isChangeSongDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDisableChangeSong) ?? false;
  }

  // Establecer si el gesto de cambiar canción está desactivado
  static Future<void> setChangeSongDisabled(bool disabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableChangeSong, disabled);
  }

  // Obtener si el gesto de abrir reproductor está desactivado
  static Future<bool> isOpenPlayerDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDisableOpenPlayer) ?? false;
  }

  // Establecer si el gesto de abrir reproductor está desactivado
  static Future<void> setOpenPlayerDisabled(bool disabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableOpenPlayer, disabled);
  }

  // Obtener todas las preferencias de gestos
  static Future<Map<String, bool>> getAllGesturePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'closePlayer': prefs.getBool(_keyDisableClosePlayer) ?? false,
      'openPlaylist': prefs.getBool(_keyDisableOpenPlaylist) ?? false,
      'changeSong': prefs.getBool(_keyDisableChangeSong) ?? false,
      'openPlayer': prefs.getBool(_keyDisableOpenPlayer) ?? false,
    };
  }

  // Establecer todas las preferencias de gestos
  static Future<void> setAllGesturePreferences(Map<String, bool> preferences) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDisableClosePlayer, preferences['closePlayer'] ?? false);
    await prefs.setBool(_keyDisableOpenPlaylist, preferences['openPlaylist'] ?? false);
    await prefs.setBool(_keyDisableChangeSong, preferences['changeSong'] ?? false);
    await prefs.setBool(_keyDisableOpenPlayer, preferences['openPlayer'] ?? false);
  }
}
