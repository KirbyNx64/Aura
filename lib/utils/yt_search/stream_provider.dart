import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/db/stream_cache_db.dart';
import 'dart:io';

class StreamService {
  static final Map<String, String?> _urlCache = {};
  static final Map<String, Future<String?>> _inFlightRequests = {};
  static StreamCacheDB? _cacheDB;
  static YoutubeExplode? _ytInstance;
  static const int _maxPrefetchConcurrency = 8;
  static const Duration _urlExpirySafetyMargin = Duration(minutes: 5);

  static YoutubeExplode _getYoutubeExplode() {
    _ytInstance ??= YoutubeExplode();
    return _ytInstance!;
  }

  static void _recreateYoutubeExplode() {
    try {
      _ytInstance?.close();
    } catch (_) {}
    _ytInstance = YoutubeExplode();
  }

  static bool _shouldRecreateClient(Object error) {
    if (error is SocketException || error is HttpException) return true;
    final message = error.toString().toLowerCase();
    return message.contains('connection closed') ||
        message.contains('connection reset') ||
        message.contains('broken pipe') ||
        message.contains('timeout') ||
        message.contains('timed out') ||
        message.contains('header was received') ||
        message.contains('client is closed');
  }

  /// Inicializa la base de datos de cache
  static Future<void> _initCache() async {
    _cacheDB ??= StreamCacheDB();
  }

  /// Obtiene la mejor URL de audio con cache persistente
  static Future<String?> getBestAudioUrl(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    await _initCache();
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    if (forceRefresh) {
      await invalidateCachedStream(normalizedVideoId);
    }

    // Cache en memoria (fast path)
    final memoryCached = _urlCache[normalizedVideoId];
    if (memoryCached != null && memoryCached.isNotEmpty) {
      if (!_isStreamUrlExpired(memoryCached)) {
        return memoryCached;
      }
      _urlCache.remove(normalizedVideoId);
      await _cacheDB?.invalidateStream(normalizedVideoId);
    }

    // Deduplicar solicitudes concurrentes por videoId
    if (!forceRefresh) {
      final pending = _inFlightRequests[normalizedVideoId];
      if (pending != null) {
        return await pending;
      }
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
        !cachedStream.isExpired &&
        !_isStreamUrlExpired(cachedStream.streamUrl)) {
      _urlCache[videoId] = cachedStream.streamUrl;
      return cachedStream.streamUrl;
    }
    if (cachedStream != null) {
      await _cacheDB!.invalidateStream(videoId);
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

  /// Precarga URLs de audio para calentar caché en memoria/DB sin bloquear la UI.
  static Future<void> prefetchBestAudioUrls(
    List<String> videoIds, {
    int maxConcurrent = 3,
  }) async {
    await _initCache();
    if (videoIds.isEmpty) return;

    final uniqueIds = <String>{};
    final pendingIds = <String>[];
    for (final rawId in videoIds) {
      final videoId = rawId.trim();
      if (videoId.isEmpty || !uniqueIds.add(videoId)) continue;

      final cached = _urlCache[videoId];
      if (cached != null && cached.isNotEmpty) {
        if (!_isStreamUrlExpired(cached)) continue;
        _urlCache.remove(videoId);
      }

      pendingIds.add(videoId);
    }
    if (pendingIds.isEmpty) return;

    final int concurrency = maxConcurrent.clamp(1, _maxPrefetchConcurrency);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        if (cursor >= pendingIds.length) return;
        final int index = cursor++;
        final videoId = pendingIds[index];
        try {
          await getBestAudioUrl(videoId);
        } catch (_) {
          // La precarga es best-effort; errores se ignoran.
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  /// Obtiene información completa del mejor stream de audio
  static Future<Map<String, dynamic>?> _getBestAudioStreamInfo(
    String videoId,
  ) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final yt = _getYoutubeExplode();
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
      } catch (e) {
        if (attempt == 0 && _shouldRecreateClient(e)) {
          _recreateYoutubeExplode();
          continue;
        }
        return null;
      }
    }
    return null;
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
    _inFlightRequests.clear();
  }

  /// Invalida el cache de stream para un video específico
  static Future<void> invalidateCachedStream(String videoId) async {
    await _initCache();
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;
    _urlCache.remove(normalizedVideoId);
    _inFlightRequests.remove(normalizedVideoId);
    await _cacheDB!.invalidateStream(normalizedVideoId);
  }

  /// Fuerza generar una URL nueva de stream para un video específico
  static Future<String?> refreshBestAudioUrl(String videoId) async {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    return await getBestAudioUrl(normalizedVideoId, forceRefresh: true);
  }

  /// Cierra la base de datos
  static Future<void> close() async {
    await _cacheDB?.close();
    _cacheDB = null;
    try {
      _ytInstance?.close();
    } catch (_) {}
    _ytInstance = null;
  }

  static int? _extractExpireEpochSeconds(String streamUrl) {
    try {
      final parsed = Uri.tryParse(streamUrl);
      final expireRaw = parsed?.queryParameters['expire'];
      if (expireRaw != null) {
        return int.tryParse(expireRaw);
      }
    } catch (_) {}

    final match = RegExp(r'(?:^|[?&])expire=(\d+)').firstMatch(streamUrl);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static bool _isStreamUrlExpired(String streamUrl) {
    final expireEpoch = _extractExpireEpochSeconds(streamUrl);
    if (expireEpoch == null) return false;
    final nowEpochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (nowEpochSeconds + _urlExpirySafetyMargin.inSeconds) >= expireEpoch;
  }
}
