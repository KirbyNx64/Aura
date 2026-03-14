import 'package:hive_ce_flutter/hive_ce_flutter.dart';

class ArtistImagesCacheDB {
  static const String _boxName = 'artist_images_cache_box';
  static Box<Map>? _box;

  static Future<Box<Map>> get _cacheBox async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  // Guardar imagen de artista en cache
  static Future<void> cacheArtistImage({
    required String artistName,
    String? thumbUrl,
    String? browseId,
    String? subscribers,
    Duration cacheDuration = const Duration(days: 7),
  }) async {
    final box = await _cacheBox;
    final normalizedName = artistName.trim();
    if (normalizedName.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + cacheDuration.inMilliseconds;

    await box.put(normalizedName, {
      'artist_name': normalizedName,
      'thumb_url': thumbUrl,
      'browse_id': browseId,
      'subscribers': subscribers,
      'cached_at': now,
      'expires_at': expiresAt,
    });
  }

  // Obtener imagen de artista desde cache
  static Future<Map<String, dynamic>?> getCachedArtistImage(
    String artistName,
  ) async {
    final box = await _cacheBox;
    final normalizedName = artistName.trim();
    if (normalizedName.isEmpty) return null;

    final now = DateTime.now().millisecondsSinceEpoch;

    final row = box.get(normalizedName);
    if (row == null) return null;

    final expiresAt = _asInt(row['expires_at']) ?? 0;
    if (expiresAt <= now) {
      await box.delete(normalizedName);
      return null;
    }

    return {
      'name': row['artist_name'],
      'thumbUrl': row['thumb_url'],
      'browseId': row['browse_id'],
      'subscribers': row['subscribers'],
      'cachedAt': _asInt(row['cached_at']),
      'expiresAt': expiresAt,
    };
  }

  // Obtener múltiples imágenes de artistas desde cache
  static Future<List<Map<String, dynamic>>> getCachedArtistImages(
    List<String> artistNames,
  ) async {
    if (artistNames.isEmpty) return [];
    final box = await _cacheBox;
    final now = DateTime.now().millisecondsSinceEpoch;

    final results = <Map<String, dynamic>>[];
    for (final rawName in artistNames) {
      final artistName = rawName.trim();
      if (artistName.isEmpty) continue;

      final row = box.get(artistName);
      if (row == null) continue;

      final expiresAt = _asInt(row['expires_at']) ?? 0;
      if (expiresAt <= now) continue;

      results.add({
        'name': row['artist_name'],
        'thumbUrl': row['thumb_url'],
        'browseId': row['browse_id'],
        'subscribers': row['subscribers'],
        'cachedAt': _asInt(row['cached_at']),
        'expiresAt': expiresAt,
      });
    }

    return results;
  }

  // Limpiar cache expirado
  static Future<int> cleanExpiredCache() async {
    final box = await _cacheBox;
    final now = DateTime.now().millisecondsSinceEpoch;

    final keysToDelete = <dynamic>[];
    for (final key in box.keys) {
      final row = box.get(key);
      if (row == null) continue;

      final expiresAt = _asInt(row['expires_at']) ?? 0;
      if (expiresAt <= now) {
        keysToDelete.add(key);
      }
    }

    if (keysToDelete.isNotEmpty) {
      await box.deleteAll(keysToDelete);
    }

    return keysToDelete.length;
  }

  // Limpiar todo el cache
  static Future<void> clearAllCache() async {
    final box = await _cacheBox;
    await box.clear();
  }

  // Obtener estadísticas del cache
  static Future<Map<String, int>> getCacheStats() async {
    final box = await _cacheBox;
    final now = DateTime.now().millisecondsSinceEpoch;

    final total = box.length;
    int expired = 0;

    for (final row in box.values) {
      final expiresAt = _asInt(row['expires_at']) ?? 0;
      if (expiresAt <= now) expired++;
    }

    final valid = total - expired;

    return {'total': total, 'valid': valid, 'expired': expired};
  }

  // Verificar si un artista está en cache y es válido
  static Future<bool> isArtistCached(String artistName) async {
    final cached = await getCachedArtistImage(artistName);
    return cached != null;
  }

  // Actualizar solo la URL de imagen de un artista existente
  static Future<void> updateArtistImageUrl(
    String artistName,
    String thumbUrl,
  ) async {
    final box = await _cacheBox;
    final normalizedName = artistName.trim();
    if (normalizedName.isEmpty) return;

    final row = box.get(normalizedName);
    if (row == null) return;

    row['thumb_url'] = thumbUrl;
    await box.put(normalizedName, row);
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
