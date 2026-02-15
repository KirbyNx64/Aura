import 'package:shared_preferences/shared_preferences.dart';

class GesturePreferences {
  static const String _keyDisableOpenPlaylist = 'disable_gesture_open_playlist';
  static const String _keyDisableChangeSong = 'disable_gesture_change_song';

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

  // Obtener todas las preferencias de gestos
  static Future<Map<String, bool>> getAllGesturePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'openPlaylist': prefs.getBool(_keyDisableOpenPlaylist) ?? false,
      'changeSong': prefs.getBool(_keyDisableChangeSong) ?? false,
    };
  }

  // Establecer todas las preferencias de gestos
  static Future<void> setAllGesturePreferences(
    Map<String, bool> preferences,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _keyDisableOpenPlaylist,
      preferences['openPlaylist'] ?? false,
    );
    await prefs.setBool(
      _keyDisableChangeSong,
      preferences['changeSong'] ?? false,
    );
  }
}
