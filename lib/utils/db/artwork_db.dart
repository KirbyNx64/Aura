import 'package:hive_flutter/hive_flutter.dart';

class ArtworkDB {
  static const String _boxName = 'artwork_cache';
  static Box<String>? _box;

  static Future<Box<String>> get box async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = await Hive.openBox<String>(_boxName);
    return _box!;
  }

  static Future<void> insertArtwork(String songPath, String artworkPath) async {
    final artworkBox = await box;
    await artworkBox.put(songPath, artworkPath);
  }

  static Future<String?> getArtwork(String songPath) async {
    final artworkBox = await box;
    return artworkBox.get(songPath);
  }

  static Future<void> clearCache() async {
    final artworkBox = await box;
    await artworkBox.clear();
  }

  static Future<void> closeBox() async {
    if (_box != null && _box!.isOpen) {
      await _box!.close();
      _box = null;
    }
  }
}