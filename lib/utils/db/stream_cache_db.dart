import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'dart:io';

class StreamCacheDB {
  static Box<Map>? _box;
  static const String _boxName = 'stream_cache_box';

  // Keys del registro en Hive
  static const String _columnId = 'id';
  static const String _columnVideoId = 'video_id';
  static const String _columnStreamUrl = 'stream_url';
  static const String _columnItag = 'itag';
  static const String _columnCodec = 'codec';
  static const String _columnBitrate = 'bitrate';
  static const String _columnSize = 'size';
  static const String _columnDuration = 'duration';
  static const String _columnLoudnessDb = 'loudness_db';
  static const String _columnCreatedAt = 'created_at';
  static const String _columnLastUsed = 'last_used';
  static const String _columnIsValid = 'is_valid';
  static const String _columnExpiresAt = 'expires_at';

  // Tiempo de expiración por defecto (24 horas)
  static const Duration _defaultExpiration = Duration(hours: 24);

  Future<Box<Map>> get box async {
    if (_box != null && _box!.isOpen) return _box!;
    _box = await Hive.openBox<Map>(_boxName);
    return _box!;
  }

  /// Guarda un stream en el cache
  Future<void> saveStream({
    required String videoId,
    required String streamUrl,
    int? itag,
    String? codec,
    int? bitrate,
    int? size,
    int? duration,
    double? loudnessDb,
    Duration? expiration,
  }) async {
    final b = await box;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + (expiration ?? _defaultExpiration).inMilliseconds;

    final previous = b.get(normalizedVideoId);
    final createdAt = _asInt(previous?[_columnCreatedAt]) ?? now;

    await b.put(normalizedVideoId, {
      _columnId: _asInt(previous?[_columnId]) ?? now,
      _columnVideoId: normalizedVideoId,
      _columnStreamUrl: streamUrl,
      _columnItag: itag,
      _columnCodec: codec,
      _columnBitrate: bitrate,
      _columnSize: size,
      _columnDuration: duration,
      _columnLoudnessDb: loudnessDb,
      _columnCreatedAt: createdAt,
      _columnLastUsed: now,
      _columnIsValid: 1,
      _columnExpiresAt: expiresAt,
    });
  }

  /// Obtiene un stream del cache si es válido
  Future<CachedStream?> getStream(String videoId) async {
    final b = await box;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    final row = b.get(normalizedVideoId);

    if (row == null) return null;
    final isValid = _asInt(row[_columnIsValid]) ?? 0;
    final expiresAt = _asInt(row[_columnExpiresAt]) ?? 0;
    if (isValid != 1 || expiresAt <= now) return null;

    row[_columnLastUsed] = now;
    await b.put(normalizedVideoId, row);

    return CachedStream(
      videoId: row[_columnVideoId] as String? ?? normalizedVideoId,
      streamUrl: row[_columnStreamUrl] as String? ?? '',
      itag: _asInt(row[_columnItag]),
      codec: row[_columnCodec] as String?,
      bitrate: _asInt(row[_columnBitrate]),
      size: _asInt(row[_columnSize]),
      duration: _asInt(row[_columnDuration]),
      loudnessDb: _asDouble(row[_columnLoudnessDb]),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        _asInt(row[_columnCreatedAt]) ?? now,
      ),
      lastUsed: DateTime.fromMillisecondsSinceEpoch(
        _asInt(row[_columnLastUsed]) ?? now,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }

  /// Marca un stream como inválido
  Future<void> invalidateStream(String videoId) async {
    final b = await box;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;

    final row = b.get(normalizedVideoId);
    if (row == null) return;

    row[_columnIsValid] = 0;
    await b.put(normalizedVideoId, row);
  }

  /// Valida si un stream sigue siendo válido haciendo una petición HEAD
  Future<bool> validateStream(String streamUrl) async {
    try {
      // print('🔍 [CACHE_DB] Validando stream: $streamUrl');
      final client = HttpClient();
      final request = await client.headUrl(Uri.parse(streamUrl));
      final response = await request.close();
      client.close();

      final isValid = response.statusCode >= 200 && response.statusCode < 300;
      // print('🔍 [CACHE_DB] Stream ${isValid ? 'válido' : 'inválido'} (Status: ${response.statusCode})');

      // Considerar válido si el status code es 200-299
      return isValid;
    } catch (e) {
      // print('❌ [CACHE_DB] Error validando stream: $e');
      return false;
    }
  }

  /// Valida y actualiza un stream si es necesario
  Future<CachedStream?> getValidatedStream(String videoId) async {
    final cached = await getStream(videoId);
    if (cached == null) {
      // print('🔍 [CACHE_DB] No hay stream en cache para videoId: $videoId');
      return null;
    }

    // print('🔍 [CACHE_DB] Stream encontrado en cache para videoId: $videoId');
    // print('🔍 [CACHE_DB] Creado: ${cached.createdAt}');
    // print('🔍 [CACHE_DB] Expira: ${cached.expiresAt}');

    // Validar el stream
    final isValid = await validateStream(cached.streamUrl);
    if (!isValid) {
      // print('❌ [CACHE_DB] Stream inválido, marcando como inválido en la DB');
      // Marcar como inválido y retornar null
      await invalidateStream(videoId);
      return null;
    }

    // print('✅ [CACHE_DB] Stream válido, usando desde cache');
    return cached;
  }

  /// Limpia streams expirados
  Future<int> cleanExpiredStreams() async {
    final b = await box;
    final now = DateTime.now().millisecondsSinceEpoch;

    final keysToDelete = <dynamic>[];
    for (final key in b.keys) {
      final row = b.get(key);
      if (row == null) continue;

      final isValid = _asInt(row[_columnIsValid]) ?? 0;
      final expiresAt = _asInt(row[_columnExpiresAt]) ?? 0;
      if (isValid == 0 || expiresAt < now) {
        keysToDelete.add(key);
      }
    }

    if (keysToDelete.isNotEmpty) {
      await b.deleteAll(keysToDelete);
    }

    return keysToDelete.length;
  }

  /// Obtiene estadísticas del cache
  Future<CacheStats> getCacheStats() async {
    final b = await box;
    final now = DateTime.now().millisecondsSinceEpoch;

    int validStreams = 0;
    int expiredStreams = 0;

    for (final row in b.values) {
      final isValid = _asInt(row[_columnIsValid]) ?? 0;
      final expiresAt = _asInt(row[_columnExpiresAt]) ?? 0;

      if (isValid == 1 && expiresAt > now) {
        validStreams++;
      } else if (expiresAt <= now) {
        expiredStreams++;
      }
    }

    return CacheStats(
      totalStreams: b.length,
      validStreams: validStreams,
      expiredStreams: expiredStreams,
    );
  }

  /// Limpia todo el cache
  Future<void> clearCache() async {
    final b = await box;
    await b.clear();
  }

  /// Cierra la base de datos
  Future<void> close() async {
    final b = _box;
    if (b != null && b.isOpen) {
      await b.close();
      _box = null;
    }
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

/// Modelo para representar un stream en cache
class CachedStream {
  final String videoId;
  final String streamUrl;
  final int? itag;
  final String? codec;
  final int? bitrate;
  final int? size;
  final int? duration;
  final double? loudnessDb;
  final DateTime createdAt;
  final DateTime lastUsed;
  final DateTime expiresAt;

  CachedStream({
    required this.videoId,
    required this.streamUrl,
    this.itag,
    this.codec,
    this.bitrate,
    this.size,
    this.duration,
    this.loudnessDb,
    required this.createdAt,
    required this.lastUsed,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toMap() {
    return {
      'videoId': videoId,
      'streamUrl': streamUrl,
      'itag': itag,
      'codec': codec,
      'bitrate': bitrate,
      'size': size,
      'duration': duration,
      'loudnessDb': loudnessDb,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'lastUsed': lastUsed.millisecondsSinceEpoch,
      'expiresAt': expiresAt.millisecondsSinceEpoch,
    };
  }
}

/// Estadísticas del cache
class CacheStats {
  final int totalStreams;
  final int validStreams;
  final int expiredStreams;

  CacheStats({
    required this.totalStreams,
    required this.validStreams,
    required this.expiredStreams,
  });

  double get hitRate => totalStreams > 0 ? validStreams / totalStreams : 0.0;
}
