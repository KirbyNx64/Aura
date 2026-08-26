import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/db/stream_cache_db.dart';
import 'package:music/screens/download/stream_provider.dart';

/// Servicio mejorado para manejar cache de streams de audio
/// Compatible tanto con previews como con descargas
class EnhancedStreamCacheService {
  static StreamCacheDB? _cacheDB;
  static final Map<String, String?> _urlCache = {};

  /// Inicializa la base de datos de cache
  static Future<void> _initCache() async {
    _cacheDB ??= StreamCacheDB();
  }

  /// Obtiene la mejor URL de audio para previews (compatible con StreamService)
  static Future<String?> getBestAudioUrl(String videoId) async {
    await _initCache();

    // Primero intentar obtener del cache persistente
    final cachedStream = await _cacheDB!.getValidatedStream(videoId);
    if (cachedStream != null) {
      // print('🎵 [CACHE] Usando stream de la DB para videoId: $videoId');
      // print('🎵 [CACHE] URL: ${cachedStream.streamUrl}');
      // print('🎵 [CACHE] Creado: ${cachedStream.createdAt}');
      return cachedStream.streamUrl;
    }

    // print('🔄 [CACHE] Generando nuevo stream para videoId: $videoId');
    // Si no está en cache o es inválido, obtener nuevo stream
    final streamInfo = await _getBestAudioStreamInfo(videoId);
    if (streamInfo != null) {
      //print('✅ [CACHE] Nuevo stream generado exitosamente');
      // print('✅ [CACHE] URL: ${streamInfo['url']}');
      // print('✅ [CACHE] Codec: ${streamInfo['codec']}');
      // print('✅ [CACHE] Bitrate: ${streamInfo['bitrate']} bps');

      // Guardar en cache persistente
      await _cacheDB!.saveStream(
        videoId: videoId,
        streamUrl: streamInfo['url']!,
        itag: streamInfo['itag'],
        codec: streamInfo['codec'],
        bitrate: streamInfo['bitrate'],
        size: streamInfo['size'],
        duration: streamInfo['duration'],
        loudnessDb: streamInfo['loudnessDb'],
      );

      // print('💾 [CACHE] Stream guardado en la base de datos');

      // También actualizar cache en memoria para acceso rápido
      _urlCache[videoId] = streamInfo['url'];

      return streamInfo['url'];
    }

    // print('❌ [CACHE] No se pudo generar stream para videoId: $videoId');
    return null;
  }

  /// Obtiene información completa del stream para descargas (compatible con StreamProvider)
  static Future<StreamProvider?> getStreamProvider(String videoId) async {
    await _initCache();

    // Primero intentar obtener del cache persistente
    final cachedStream = await _cacheDB!.getValidatedStream(videoId);
    if (cachedStream != null) {
      // print('📥 [CACHE] Usando StreamProvider de la DB para videoId: $videoId');
      // print('📥 [CACHE] URL: ${cachedStream.streamUrl}');
      // print('📥 [CACHE] Codec: ${cachedStream.codec}');
      // print('📥 [CACHE] Bitrate: ${cachedStream.bitrate} bps');
      // Reconstruir StreamProvider desde cache
      return _createStreamProviderFromCache(cachedStream);
    }

    // print('🔄 [CACHE] Generando nuevo StreamProvider para videoId: $videoId');
    // Si no está en cache o es inválido, obtener nuevo stream
    final streamProvider = await _getStreamProviderFromYouTube(videoId);
    if (streamProvider != null && streamProvider.audioFormats != null) {
      // print('✅ [CACHE] Nuevo StreamProvider generado exitosamente');
      // print('✅ [CACHE] Formatos disponibles: ${streamProvider.audioFormats!.length}');

      // Guardar en cache persistente
      final bestAudio =
          streamProvider.highestBitrateMp4aAudio ??
          streamProvider.highestBitrateOpusAudio;

      if (bestAudio != null) {
        // print('💾 [CACHE] Guardando mejor audio en la DB');
        // print('💾 [CACHE] Codec: ${bestAudio.audioCodec}');
        // print('💾 [CACHE] Bitrate: ${bestAudio.bitrate} bps');
        // print('💾 [CACHE] Tamaño: ${bestAudio.size} bytes');

        await _cacheDB!.saveStream(
          videoId: videoId,
          streamUrl: bestAudio.url,
          itag: bestAudio.itag,
          codec: bestAudio.audioCodec.toString(),
          bitrate: bestAudio.bitrate,
          size: bestAudio.size,
          duration: bestAudio.duration,
          loudnessDb: bestAudio.loudnessDb,
        );

        // print('💾 [CACHE] StreamProvider guardado en la base de datos');
      }
    } else {
      // print('❌ [CACHE] No se pudo generar StreamProvider para videoId: $videoId');
    }

    return streamProvider;
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
        'duration': null,
        'loudnessDb':
            0.0, // YouTube no proporciona esta información directamente
      };
    } catch (_) {
      return null;
    } finally {
      yt.close();
    }
  }

  /// Obtiene StreamProvider desde YouTube
  static Future<StreamProvider?> _getStreamProviderFromYouTube(
    String videoId,
  ) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      return StreamProvider.fromManifest(manifest);
    } catch (_) {
      return null;
    } finally {
      yt.close();
    }
  }

  /// Crea un StreamProvider desde datos en cache
  static StreamProvider _createStreamProviderFromCache(CachedStream cached) {
    final audio = Audio(
      itag: cached.itag ?? 140,
      audioCodec: _parseCodec(cached.codec),
      bitrate: cached.bitrate ?? 128000,
      duration: cached.duration ?? 0,
      loudnessDb: cached.loudnessDb ?? 0.0,
      url: cached.streamUrl,
      size: cached.size ?? 0,
    );

    return StreamProvider(
      playable: true,
      statusMSG: "OK (Cached)",
      audioFormats: [audio],
    );
  }

  /// Parsea el codec desde string
  static Codec _parseCodec(String? codecString) {
    if (codecString == null) return Codec.mp4a;
    if (codecString.toLowerCase().contains('opus')) return Codec.opus;
    return Codec.mp4a;
  }

  /// Valida si un stream sigue siendo válido
  static Future<bool> validateStream(String streamUrl) async {
    await _initCache();
    return await _cacheDB!.validateStream(streamUrl);
  }

  /// Marca un stream como inválido
  static Future<void> invalidateStream(String videoId) async {
    await _initCache();
    await _cacheDB!.invalidateStream(videoId);
    _urlCache.remove(videoId);
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

  /// Obtiene información detallada de un stream en cache
  static Future<CachedStream?> getCachedStreamInfo(String videoId) async {
    await _initCache();
    return await _cacheDB!.getStream(videoId);
  }

  /// Fuerza la actualización de un stream específico
  static Future<String?> refreshStream(String videoId) async {
    // Invalidar el stream actual
    await invalidateStream(videoId);

    // Obtener nuevo stream
    return await getBestAudioUrl(videoId);
  }

  /// Configura el tiempo de expiración personalizado para un stream
  static Future<void> setStreamExpiration(
    String videoId,
    Duration expiration,
  ) async {
    await _initCache();

    final cached = await _cacheDB!.getStream(videoId);
    if (cached != null) {
      // Invalidar el actual
      await _cacheDB!.invalidateStream(videoId);

      // Guardar con nueva expiración
      await _cacheDB!.saveStream(
        videoId: videoId,
        streamUrl: cached.streamUrl,
        itag: cached.itag,
        codec: cached.codec,
        bitrate: cached.bitrate,
        size: cached.size,
        duration: cached.duration,
        loudnessDb: cached.loudnessDb,
        expiration: expiration,
      );
    }
  }
}
