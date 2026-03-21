import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/db/stream_cache_db.dart';
import 'package:music/utils/yt_search/explode_video/youtube_explode_dart.dart'
    as explode_video;
import 'package:music/utils/notifiers.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:isolate';

String _normalizeStreamingQuality(String? rawQuality) {
  final quality = rawQuality?.trim().toLowerCase();
  if (quality == 'high' || quality == 'low') {
    return quality!;
  }
  return 'low';
}

AudioOnlyStreamInfo? _selectAudioByQuality(
  Iterable<AudioOnlyStreamInfo> source, {
  required String quality,
}) {
  final candidates = source.toList()
    ..sort(
      (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond),
    );
  if (candidates.isEmpty) return null;

  final normalized = _normalizeStreamingQuality(quality);
  if (normalized == 'low') {
    return candidates.first; // Menor bitrate disponible
  }
  if (normalized == 'high') {
    return candidates.last; // Máxima calidad disponible
  }

  return candidates.first;
}

String _classifyIsolateResolveError(String message) {
  final lower = message.toLowerCase();

  bool containsAny(List<String> tokens) {
    for (final token in tokens) {
      if (lower.contains(token)) return true;
    }
    return false;
  }

  if (containsAny(<String>[
    'copyright',
    'copyrighted',
    'restricted',
    'restriction',
    'not available',
    'unavailable',
    'video unavailable',
    'private',
    'age-restricted',
    'age restricted',
    'members-only',
    'members only',
    'forbidden',
    'status code: 403',
    'error 403',
    'geo',
    'country',
    'region',
    'premium',
  ])) {
    return 'restricted';
  }

  if (containsAny(<String>[
    'socketexception',
    'httpexception',
    'network',
    'connection',
    'dns',
    'timeout',
    'timed out',
    'handshake',
    'connection closed',
    'connection reset',
    'broken pipe',
  ])) {
    return 'network';
  }

  return 'unknown';
}

Future<Map<String, dynamic>?> _resolveBestAudioStreamInfoInIsolate(
  String videoId,
  RootIsolateToken? token,
  String quality,
) async {
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }

  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    final preferredAudioCandidates = manifest.audioOnly.where((s) {
      return s.codec.mimeType == 'audio/mp4' ||
          s.codec.toString().contains('mp4a');
    }).toList();

    AudioOnlyStreamInfo? bestAudio = _selectAudioByQuality(
      preferredAudioCandidates,
      quality: quality,
    );

    // Fallback: algunos videos no exponen mp4a; intentar cualquier audio-only.
    bestAudio ??= _selectAudioByQuality(manifest.audioOnly, quality: quality);

    if (bestAudio == null) {
      return <String, dynamic>{
        'errorCode': 'restricted',
        'errorMessage': 'No audio streams available in manifest',
      };
    }

    // ignore: avoid_print
    print(
      '[STREAM_QUALITY] videoId=$videoId quality=${_normalizeStreamingQuality(quality)} '
      'bitrate=${bestAudio.bitrate.bitsPerSecond} itag=${bestAudio.tag} codec=${bestAudio.codec}',
    );

    return <String, dynamic>{
      'url': bestAudio.url.toString(),
      'itag': bestAudio.tag,
      'codec': bestAudio.codec.toString(),
      'bitrate': bestAudio.bitrate.bitsPerSecond,
      'size': bestAudio.size.totalBytes,
      'duration': bestAudio.duration,
      'loudnessDb': 0.0,
    };
  } on SocketException catch (e) {
    return <String, dynamic>{
      'errorCode': 'network',
      'errorMessage': e.toString(),
    };
  } on HttpException catch (e) {
    final msg = e.toString().toLowerCase();
    return <String, dynamic>{
      'errorCode': (msg.contains('403') || msg.contains('forbidden'))
          ? 'restricted'
          : 'network',
      'errorMessage': e.toString(),
    };
  } on VideoRequiresPurchaseException catch (e) {
    return <String, dynamic>{
      'errorCode': 'restricted',
      'errorMessage': e.toString(),
    };
  } on VideoUnavailableException catch (e) {
    return <String, dynamic>{
      'errorCode': 'restricted',
      'errorMessage': e.toString(),
    };
  } on VideoUnplayableException catch (e) {
    return <String, dynamic>{
      'errorCode': 'restricted',
      'errorMessage': e.toString(),
    };
  } on YoutubeExplodeException catch (e) {
    return <String, dynamic>{
      'errorCode': _classifyIsolateResolveError(e.toString()),
      'errorMessage': e.toString(),
    };
  } catch (e) {
    return <String, dynamic>{
      'errorCode': _classifyIsolateResolveError(e.toString()),
      'errorMessage': e.toString(),
    };
  } finally {
    try {
      yt.close();
    } catch (_) {}
  }
}

class StreamService {
  static final Map<String, String?> _urlCache = {};
  static final Map<String, String?> _videoUrlCache = {};
  // Cache de video habilitado para mejorar tiempos de arranque.
  static const bool _disableVideoUrlCache = false;
  // Perfil rápido: evitar bitrates muy altos para iniciar video más rápido.
  static const int _videoFastStartTargetBitrate = 550000;
  static const int _videoFastStartMinBitrate = 220000;
  static final Map<String, Future<String?>> _inFlightRequests = {};
  static final Map<String, Future<String?>> _inFlightVideoRequests = {};
  static final Map<String, String> _lastResolveErrorCodeByVideoId = {};
  static StreamCacheDB? _cacheDB;
  static YoutubeExplode? _ytInstance;
  static int _resolveGeneration = 0;
  static int _videoResolveGeneration = 0;
  static const int _maxPrefetchConcurrency = 8;
  static const Duration _urlExpirySafetyMargin = Duration(minutes: 5);

  static void _videoLog(String message) {
    // ignore: avoid_print
    print('[AURA_VIDEO] $message');
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

  static bool _containsAny(String source, List<String> tokens) {
    for (final token in tokens) {
      if (source.contains(token)) return true;
    }
    return false;
  }

  static String _classifyResolveError(Object error) {
    if (error is SocketException) return 'network';

    final message = error.toString().toLowerCase();

    if (_containsAny(message, <String>[
      'copyright',
      'copyrighted',
      'restricted',
      'restriction',
      'not available',
      'unavailable',
      'video unavailable',
      'private',
      'age-restricted',
      'age restricted',
      'members-only',
      'members only',
      'forbidden',
      'status code: 403',
      'error 403',
      'geo',
      'country',
      'region',
      'premium',
    ])) {
      return 'restricted';
    }

    if (error is HttpException) {
      if (_containsAny(message, <String>['403', 'forbidden'])) {
        return 'restricted';
      }
      return 'network';
    }

    if (_containsAny(message, <String>[
      'socketexception',
      'httpexception',
      'network',
      'connection',
      'dns',
      'timeout',
      'timed out',
      'handshake',
      'connection closed',
      'connection reset',
      'broken pipe',
    ])) {
      return 'network';
    }

    return 'unknown';
  }

  static void _setLastResolveErrorCode(String videoId, String code) {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;
    _lastResolveErrorCodeByVideoId[normalizedVideoId] = code;
  }

  static void _clearLastResolveErrorCode(String videoId) {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;
    _lastResolveErrorCodeByVideoId.remove(normalizedVideoId);
  }

  static String? takeLastResolveErrorCode(String videoId) {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    return _lastResolveErrorCodeByVideoId.remove(normalizedVideoId);
  }

  static void _reportResolveErrorIfNeeded(
    String videoId, {
    required bool reportError,
  }) {
    if (!reportError) return;
    final errorCode = takeLastResolveErrorCode(videoId) ?? 'unknown';
    reportStreamPlaybackError(errorCode, videoId: videoId);
  }

  /// Inicializa la base de datos de cache
  static Future<void> _initCache() async {
    _cacheDB ??= StreamCacheDB();
  }

  /// Obtiene la mejor URL de audio con cache persistente
  static Future<String?> getBestAudioUrl(
    String videoId, {
    bool forceRefresh = false,
    bool reportError = false,
    bool fastFail = false,
  }) async {
    await _initCache();
    final int requestGeneration = _resolveGeneration;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    if (forceRefresh) {
      await invalidateCachedStream(normalizedVideoId);
    }
    if (_isResolveCancelled(requestGeneration)) return null;

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
        final resolvedPending = await pending;
        if (_isResolveCancelled(requestGeneration)) return null;
        if (resolvedPending == null || resolvedPending.isEmpty) {
          _reportResolveErrorIfNeeded(
            normalizedVideoId,
            reportError: reportError,
          );
          return null;
        }
        _clearLastResolveErrorCode(normalizedVideoId);
        return resolvedPending;
      }
    }

    final request = _resolveBestAudioUrl(
      normalizedVideoId,
      fastFail: fastFail || reportError,
      requestGeneration: requestGeneration,
    );
    _inFlightRequests[normalizedVideoId] = request;
    try {
      final resolved = await request;
      if (_isResolveCancelled(requestGeneration)) return null;
      if (resolved == null || resolved.isEmpty) {
        _reportResolveErrorIfNeeded(
          normalizedVideoId,
          reportError: reportError,
        );
        return null;
      }
      _clearLastResolveErrorCode(normalizedVideoId);
      return resolved;
    } finally {
      _inFlightRequests.remove(normalizedVideoId);
    }
  }

  static Future<String?> _resolveBestAudioUrl(
    String videoId, {
    bool fastFail = false,
    required int requestGeneration,
  }) async {
    if (_isResolveCancelled(requestGeneration)) return null;
    // En cola "Up next" priorizamos latencia: usar cache persistente sin HEAD.
    // Si el stream expiró antes de tiempo, fallará al reproducir y se regenerará.
    final cachedStream = await _cacheDB!.getStream(videoId);
    if (_isResolveCancelled(requestGeneration)) return null;
    if (cachedStream != null &&
        cachedStream.streamUrl.isNotEmpty &&
        !cachedStream.isExpired &&
        !_isStreamUrlExpired(cachedStream.streamUrl)) {
      _urlCache[videoId] = cachedStream.streamUrl;
      _clearLastResolveErrorCode(videoId);
      return cachedStream.streamUrl;
    }
    if (cachedStream != null) {
      await _cacheDB!.invalidateStream(videoId);
    }

    // Si no está en cache o expiró, generar uno nuevo
    final streamInfo = await _getBestAudioStreamInfo(
      videoId,
      fastFail: fastFail,
      requestGeneration: requestGeneration,
    );
    if (_isResolveCancelled(requestGeneration)) return null;
    if (streamInfo == null) {
      _setLastResolveErrorCode(
        videoId,
        _lastResolveErrorCodeByVideoId[videoId] ?? 'unknown',
      );
      return null;
    }

    final streamUrl = streamInfo['url'];
    if (streamUrl == null || streamUrl.isEmpty) {
      _setLastResolveErrorCode(videoId, 'unknown');
      return null;
    }

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
    if (_isResolveCancelled(requestGeneration)) return null;

    _urlCache[videoId] = streamUrl;
    _clearLastResolveErrorCode(videoId);
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
    String videoId, {
    bool fastFail = false,
    required int requestGeneration,
  }) async {
    final preferredQuality = _normalizeStreamingQuality(
      streamingAudioQualityNotifier.value,
    );
    final maxAttempts = fastFail ? 1 : 2;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      if (_isResolveCancelled(requestGeneration)) return null;
      try {
        Map<String, dynamic>? streamInfo;
        try {
          final token = RootIsolateToken.instance;
          // Mover parse/seleccion de manifest a otro isolate reduce jank en UI.
          streamInfo = await Isolate.run<Map<String, dynamic>?>(
            () => _resolveBestAudioStreamInfoInIsolate(
              videoId,
              token,
              preferredQuality,
            ),
          );
        } catch (e) {
          // Fallback defensivo: si el isolate falla por plataforma/estado,
          // resolver en el isolate actual para no romper reproducción.
          /*
          print(
            '[STREAM_PROVIDER] Isolate.run failed for $videoId: $e. Falling back to direct resolve.',
          );
          */
          streamInfo = await _resolveBestAudioStreamInfoInIsolate(
            videoId,
            null,
            preferredQuality,
          );
        }

        if (_isResolveCancelled(requestGeneration)) return null;
        if (streamInfo == null) {
          // print('[STREAM_PROVIDER] streamInfo is null for $videoId');
          _setLastResolveErrorCode(videoId, 'unknown');
          return null;
        }

        final errorCode = streamInfo['errorCode']?.toString();
        // final errorMessage = streamInfo['errorMessage']?.toString();
        if (errorCode != null && errorCode.isNotEmpty) {
          /*
          debugPrint(
            '[STREAM_PROVIDER] Resolve error for $videoId: code=$errorCode message=${errorMessage ?? 'n/a'}',
          );
          */
          _setLastResolveErrorCode(videoId, errorCode);
          return null;
        }

        final resolvedUrl = streamInfo['url']?.toString();
        if (resolvedUrl == null || resolvedUrl.isEmpty) {
          // print('[STREAM_PROVIDER] Missing resolved URL for $videoId');
          _setLastResolveErrorCode(videoId, 'unknown');
          return null;
        }

        _clearLastResolveErrorCode(videoId);
        return streamInfo;
      } catch (e) {
        if (_isResolveCancelled(requestGeneration)) return null;
        final classified = _classifyResolveError(e);
        _setLastResolveErrorCode(videoId, classified);
        if (!fastFail && attempt == 0 && _shouldRecreateClient(e)) {
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
    _videoUrlCache.clear();
    _inFlightRequests.clear();
    _lastResolveErrorCodeByVideoId.clear();
  }

  /// Invalida el cache de stream para un video específico
  static Future<void> invalidateCachedStream(String videoId) async {
    await _initCache();
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return;
    _urlCache.remove(normalizedVideoId);
    _videoUrlCache.remove(normalizedVideoId);
    _inFlightRequests.remove(normalizedVideoId);
    _lastResolveErrorCodeByVideoId.remove(normalizedVideoId);
    await _cacheDB!.invalidateStream(normalizedVideoId);
  }

  /// Fuerza generar una URL nueva de stream para un video específico
  static Future<String?> refreshBestAudioUrl(String videoId) async {
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    return await getBestAudioUrl(normalizedVideoId, forceRefresh: true);
  }

  /// URL de video-only para render opcional en PlayerScreen.
  /// Se obtiene bajo demanda solo cuando el usuario activa modo video.
  static Future<String?> getBestVideoUrl(
    String videoId, {
    bool forceRefresh = false,
  }) async {
    final int requestGeneration = _videoResolveGeneration;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return null;
    if (_isVideoResolveCancelled(requestGeneration)) return null;
    _videoLog(
      'getBestVideoUrl:start videoId=$normalizedVideoId forceRefresh=$forceRefresh',
    );

    if (_disableVideoUrlCache) {
      _videoUrlCache.remove(normalizedVideoId);
      _videoLog(
        'getBestVideoUrl:cache_disabled_temp videoId=$normalizedVideoId',
      );
    } else if (forceRefresh) {
      _videoUrlCache.remove(normalizedVideoId);
      _videoLog('getBestVideoUrl:cache invalidated videoId=$normalizedVideoId');
    } else {
      final cached = _videoUrlCache[normalizedVideoId];
      if (cached != null && cached.isNotEmpty && !_isStreamUrlExpired(cached)) {
        _videoLog(
          'getBestVideoUrl:cache_hit videoId=$normalizedVideoId url=${cached.length > 120 ? '${cached.substring(0, 120)}...' : cached}',
        );
        return cached;
      }
      _videoLog('getBestVideoUrl:cache_miss videoId=$normalizedVideoId');
    }
    if (_isVideoResolveCancelled(requestGeneration)) return null;

    if (!forceRefresh) {
      final pending = _inFlightVideoRequests[normalizedVideoId];
      if (pending != null) {
        final resolvedPending = await pending;
        if (_isVideoResolveCancelled(requestGeneration)) return null;
        return resolvedPending;
      }
    }

    Future<String?> resolveOnce() async {
      if (_isVideoResolveCancelled(requestGeneration)) return null;
      // Cliente dedicado para video preview: evita interferencia con
      // resoluciones concurrentes de audio y estados compartidos.
      _videoLog(
        'getBestVideoUrl:provider explode_video_local videoId=$normalizedVideoId',
      );
      final yt = explode_video.YoutubeExplode();
      explode_video.StreamManifest manifest;
      try {
        manifest = await yt.videos.streamsClient.getManifest(normalizedVideoId);
      } finally {
        try {
          yt.close();
        } catch (_) {}
      }
      if (_isVideoResolveCancelled(requestGeneration)) return null;
      _videoLog(
        'getBestVideoUrl:manifest videoId=$normalizedVideoId muxed=${manifest.muxed.length} videoOnly=${manifest.videoOnly.length} audioOnly=${manifest.audioOnly.length}',
      );

      // Candidatos MP4 para video_player.
      final muxedMp4Candidates = manifest.muxed.where((stream) {
        return stream.container.name.toLowerCase().contains('mp4') ||
            stream.codec.mimeType.toLowerCase().contains('video/mp4');
      }).toList();

      T selectByFastStartBitrate<T extends explode_video.StreamInfo>(
        List<T> candidates,
      ) {
        candidates.sort(
          (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond),
        );

        // Preferir calidad media-baja para arranque rápido.
        final inFastRange = candidates.where((stream) {
          final bps = stream.bitrate.bitsPerSecond;
          return bps >= _videoFastStartMinBitrate &&
              bps <= _videoFastStartTargetBitrate;
        }).toList();
        if (inFastRange.isNotEmpty) return inFastRange.last;

        // Si no hay en rango, elegir la más cercana por debajo del target.
        final belowTarget = candidates.where((stream) {
          return stream.bitrate.bitsPerSecond <= _videoFastStartTargetBitrate;
        }).toList();
        if (belowTarget.isNotEmpty) return belowTarget.last;

        // Si todas son más altas, usar la más baja disponible.
        return candidates.first;
      }

      String? selectedSource;
      int? selectedBitrate;
      int? selectedTag;
      String? pickUrlFrom<T extends explode_video.StreamInfo>(
        List<T> list,
        String source,
      ) {
        if (list.isEmpty) return null;
        final selected = selectByFastStartBitrate<T>(list);
        final url = selected.url.toString();
        if (url.isEmpty) return null;
        selectedSource = source;
        selectedBitrate = selected.bitrate.bitsPerSecond;
        selectedTag = selected.tag;
        return url;
      }

      final videoOnlyMp4Candidates = manifest.videoOnly.where((stream) {
        return stream.container.name.toLowerCase().contains('mp4') ||
            stream.codec.mimeType.toLowerCase().contains('video/mp4');
      }).toList();

      bool isAvcCompatible(explode_video.StreamInfo stream) {
        final codec = stream.codec.toString().toLowerCase();
        return codec.contains('avc1') || codec.contains('h264');
      }

      final videoOnlyMp4AvcCandidates = videoOnlyMp4Candidates
          .where(isAvcCompatible)
          .toList();
      final muxedMp4AvcCandidates = muxedMp4Candidates
          .where(isAvcCompatible)
          .toList();

      _videoLog(
        'getBestVideoUrl:candidates videoOnlyMp4=${videoOnlyMp4Candidates.length} videoOnlyAvc=${videoOnlyMp4AvcCandidates.length} muxedMp4=${muxedMp4Candidates.length} muxedAvc=${muxedMp4AvcCandidates.length}',
      );

      String? url;
      if (forceRefresh) {
        // Segundo intento: priorizar compatibilidad/arranque rápido.
        url = pickUrlFrom<explode_video.MuxedStreamInfo>(
          muxedMp4AvcCandidates,
          'muxed_mp4_avc_retry',
        );
        url ??= pickUrlFrom<explode_video.MuxedStreamInfo>(
          muxedMp4Candidates,
          'muxed_mp4_retry',
        );
        url ??= pickUrlFrom<explode_video.VideoOnlyStreamInfo>(
          videoOnlyMp4AvcCandidates,
          'video_only_mp4_avc_retry',
        );
        url ??= pickUrlFrom<explode_video.VideoOnlyStreamInfo>(
          videoOnlyMp4Candidates,
          'video_only_mp4_retry',
        );
      } else {
        // Primer intento: arrancar rápido con stream muxed AVC (más compatible).
        url = pickUrlFrom<explode_video.MuxedStreamInfo>(
          muxedMp4AvcCandidates,
          'muxed_mp4_avc_fast_start',
        );
        url ??= pickUrlFrom<explode_video.MuxedStreamInfo>(
          muxedMp4Candidates,
          'muxed_mp4_fast_start',
        );
        url ??= pickUrlFrom<explode_video.VideoOnlyStreamInfo>(
          videoOnlyMp4AvcCandidates,
          'video_only_mp4_avc_fast_start',
        );
        url ??= pickUrlFrom<explode_video.VideoOnlyStreamInfo>(
          videoOnlyMp4Candidates,
          'video_only_mp4_fast_start',
        );
      }

      // Último recurso.
      url ??= pickUrlFrom<explode_video.VideoOnlyStreamInfo>(
        manifest.videoOnly.toList(),
        'video_only_any_highest',
      );
      url ??= pickUrlFrom<explode_video.MuxedStreamInfo>(
        manifest.muxed.toList(),
        'muxed_any_highest',
      );

      if (url == null || url.isEmpty) {
        if (manifest.muxed.isEmpty && manifest.videoOnly.isEmpty) {
          _videoLog(
            'getBestVideoUrl:no_video_streams videoId=$normalizedVideoId audioOnly=${manifest.audioOnly.length}',
          );
        }
        _videoLog('getBestVideoUrl:empty_result videoId=$normalizedVideoId');
        return null;
      }
      if (_isVideoResolveCancelled(requestGeneration)) return null;
      _videoLog(
        'getBestVideoUrl:selected videoId=$normalizedVideoId source=${selectedSource ?? 'unknown'} itag=${selectedTag ?? -1} bitrate=${selectedBitrate ?? -1} url=${url.length > 120 ? '${url.substring(0, 120)}...' : url}',
      );
      if (!_disableVideoUrlCache) {
        _videoUrlCache[normalizedVideoId] = url;
      }
      return url;
    }

    final request = () async {
      try {
        final resolved = await resolveOnce();
        if (_isVideoResolveCancelled(requestGeneration)) return null;
        _videoLog(
          'getBestVideoUrl:done videoId=$normalizedVideoId ok=${resolved != null && resolved.isNotEmpty}',
        );
        return resolved;
      } catch (e) {
        if (_isVideoResolveCancelled(requestGeneration)) return null;
        _videoLog('getBestVideoUrl:error videoId=$normalizedVideoId error=$e');
        if (_shouldRecreateClient(e)) {
          _videoLog('getBestVideoUrl:recreate_client videoId=$normalizedVideoId');
          _recreateYoutubeExplode();
          try {
            final resolved = await resolveOnce();
            if (_isVideoResolveCancelled(requestGeneration)) return null;
            _videoLog(
              'getBestVideoUrl:retry_done videoId=$normalizedVideoId ok=${resolved != null && resolved.isNotEmpty}',
            );
            return resolved;
          } catch (retryError) {
            if (_isVideoResolveCancelled(requestGeneration)) return null;
            _videoLog(
              'getBestVideoUrl:retry_error videoId=$normalizedVideoId error=$retryError',
            );
            return null;
          }
        }
        return null;
      }
    }();

    _inFlightVideoRequests[normalizedVideoId] = request;
    try {
      final resolved = await request;
      if (_isVideoResolveCancelled(requestGeneration)) return null;
      return resolved;
    } finally {
      _inFlightVideoRequests.remove(normalizedVideoId);
    }
  }

  /// Cierra la base de datos
  static Future<void> close() async {
    await _cacheDB?.close();
    _cacheDB = null;
    _inFlightRequests.clear();
    _inFlightVideoRequests.clear();
    try {
      _ytInstance?.close();
    } catch (_) {}
    _ytInstance = null;
  }

  /// Cancela resoluciones en curso (DB/red) y opcionalmente fuerza recrear cliente HTTP.
  static void cancelPendingResolves({bool resetClient = true}) {
    _resolveGeneration++;
    _inFlightRequests.clear();
    cancelPendingVideoResolves();
    if (resetClient) {
      _recreateYoutubeExplode();
    }
  }

  /// Cancela únicamente resoluciones de URL de video.
  static void cancelPendingVideoResolves() {
    _videoResolveGeneration++;
    _inFlightVideoRequests.clear();
  }

  static bool _isResolveCancelled(int requestGeneration) {
    return requestGeneration != _resolveGeneration;
  }

  static bool _isVideoResolveCancelled(int requestGeneration) {
    return requestGeneration != _videoResolveGeneration;
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
