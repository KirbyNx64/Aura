import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/db/stream_cache_db.dart';

class StreamService {
  static final Map<String, String?> _urlCache = {};
  static StreamCacheDB? _cacheDB;

  /// Inicializa la base de datos de cache
  static Future<void> _initCache() async {
    _cacheDB ??= StreamCacheDB();
  }

  /// Obtiene la mejor URL de audio con cache persistente
  static Future<String?> getBestAudioUrl(String videoId) async {
    await _initCache();
    
    // Primero intentar obtener del cache persistente
    final cachedStream = await _cacheDB!.getValidatedStream(videoId);
    if (cachedStream != null) {
      // print('🎵 [STREAM_SERVICE] Usando stream de la DB para videoId: $videoId');
      // print('🎵 [STREAM_SERVICE] URL: ${cachedStream.streamUrl}');
      // print('🎵 [STREAM_SERVICE] Creado: ${cachedStream.createdAt}');
      return cachedStream.streamUrl;
    }

    // print('🔄 [STREAM_SERVICE] Generando nuevo stream para videoId: $videoId');
    // Si no está en cache o es inválido, obtener nuevo stream
    final streamInfo = await _getBestAudioStreamInfo(videoId);
    if (streamInfo != null) {
      // print('✅ [STREAM_SERVICE] Nuevo stream generado exitosamente');
      // print('✅ [STREAM_SERVICE] URL: ${streamInfo['url']}');
      // print('✅ [STREAM_SERVICE] Codec: ${streamInfo['codec']}');
      // print('✅ [STREAM_SERVICE] Bitrate: ${streamInfo['bitrate']} bps');
      
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
      
      // print('💾 [STREAM_SERVICE] Stream guardado en la base de datos');
      
      // También actualizar cache en memoria para acceso rápido
      _urlCache[videoId] = streamInfo['url'];
      
      return streamInfo['url'];
    }

    // print('❌ [STREAM_SERVICE] No se pudo generar stream para videoId: $videoId');
    return null;
  }

  /// Obtiene información completa del mejor stream de audio
  static Future<Map<String, dynamic>?> _getBestAudioStreamInfo(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audio = manifest.audioOnly
        .where((s) => s.codec.mimeType == 'audio/mp4' || s.codec.toString().contains('mp4a'))
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
        'loudnessDb': 0.0, // YouTube no proporciona esta información directamente
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