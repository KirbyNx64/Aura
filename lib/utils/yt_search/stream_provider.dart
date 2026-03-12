import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/db/stream_cache_db.dart';

class StreamService {
  static final Map<String, String?> _urlCache = {};
  static final Map<String, Future<String?>> _inFlightRequests = {};
  static StreamCacheDB? _cacheDB;

  /// Inicializa la base de datos de cache
  static Future<void> _initCache() async {
    _cacheDB ??= StreamCacheDB();
  }

  /// Obtiene la mejor URL de audio con cache persistente
  static Future<String?> getBestAudioUrl(String videoId) async {
    await _initCache();
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;

    // Cache en memoria (fast path)
    final memoryCached = _urlCache[normalizedVideoId];
    if (memoryCached != null && memoryCached.isNotEmpty) {
      return memoryCached;
    }

    // Deduplicar solicitudes concurrentes por videoId
    final pending = _inFlightRequests[normalizedVideoId];
    if (pending != null) {
      return await pending;
    }

    final request = _resolveBestAudioUrl(normalizedVideoId);
    _inFlightRequests[normalizedVideoId] = request;
    try {
      return await request;
    } finally {
      _inFlightRequests.remove(normalizedVideoId);
    }
  }

  static Future<String?> _resolveBestAudioUrl(String videoId) async {
    // En cola "Up next" priorizamos latencia: usar cache persistente sin HEAD.
    // Si el stream expiró antes de tiempo, fallará al reproducir y se regenerará.
    final cachedStream = await _cacheDB!.getStream(videoId);
    if (cachedStream != null &&
        cachedStream.streamUrl.isNotEmpty &&
        !cachedStream.isExpired) {
      _urlCache[videoId] = cachedStream.streamUrl;
      return cachedStream.streamUrl;
    }

    // Si no está en cache o expiró, generar uno nuevo
    final streamInfo = await _getBestAudioStreamInfo(videoId);
    if (streamInfo == null) return null;

    final streamUrl = streamInfo['url'];
    if (streamUrl == null || streamUrl.isEmpty) return null;

    // Guardar en cache persistente
    await _cacheDB!.saveStream(
      videoId: videoId,
      streamUrl: streamUrl,
      itag: streamInfo['itag'],
      codec: streamInfo['codec'],
      bitrate: streamInfo['bitrate'],
      size: streamInfo['size'],
      duration: streamInfo['duration'],
      loudnessDb: streamInfo['loudnessDb'],
    );

    _urlCache[videoId] = streamUrl;
    return streamUrl;
  }

  /// Obtiene información completa del mejor stream de audio
  static Future<Map<String, dynamic>?> _getBestAudioStreamInfo(
    String videoId,
  ) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audio =
          manifest.audioOnly
              .where(
                (s) =>
                    s.codec.mimeType == 'audio/mp4' ||
                    s.codec.toString().contains('mp4a'),
              )
              .toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (audio.isEmpty) return null;

      final bestAudio = audio.first;
      return {
        'url': bestAudio.url.toString(),
        'itag': bestAudio.tag,
        'codec': bestAudio.codec.toString(),
        'bitrate': bestAudio.bitrate.bitsPerSecond,
        'size': bestAudio.size.totalBytes,
        'duration': bestAudio.duration,
        'loudnessDb':
            0.0, // YouTube no proporciona esta información directamente
      };
    } catch (_) {
      return null;
    } finally {
      yt.close();
    }
  }

  /// Limpia el cache de streams expirados
  static Future<int> cleanExpiredStreams() async {
    await _initCache();
    return await _cacheDB!.cleanExpiredStreams();
  }

  /// Obtiene estadísticas del cache
  static Future<CacheStats> getCacheStats() async {
    await _initCache();
    return await _cacheDB!.getCacheStats();
  }

  /// Limpia todo el cache
  static Future<void> clearCache() async {
    await _initCache();
    await _cacheDB!.clearCache();
    _urlCache.clear();
  }

  /// Cierra la base de datos
  static Future<void> close() async {
    await _cacheDB?.close();
    _cacheDB = null;
  }
}
