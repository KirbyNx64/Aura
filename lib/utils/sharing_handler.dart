import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music/utils/yt_search/service.dart';

class SharingHandler {
  /// Extrae el ID de video de YouTube de diferentes formatos de URL
  static String? extractYouTubeVideoId(String url) {
    if (url.isEmpty) return null;
    
    // Patrones de URL de YouTube
    final patterns = [
      RegExp(r'(?:https?:\/\/)?(?:www\.)?youtube\.com\/watch\?v=([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:https?:\/\/)?(?:www\.)?youtube\.com\/embed\/([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:https?:\/\/)?(?:www\.)?youtube\.com\/v\/([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:https?:\/\/)?youtu\.be\/([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:https?:\/\/)?(?:www\.)?youtube\.com\/shorts\/([a-zA-Z0-9_-]{11})'),
      RegExp(r'(?:https?:\/\/)?(?:www\.)?youtube\.com\/live\/([a-zA-Z0-9_-]{11})'),
    ];
    
    for (final pattern in patterns) {
      final match = pattern.firstMatch(url);
      if (match != null && match.groupCount > 0) {
        return match.group(1);
      }
    }
    
    return null;
  }
  
  /// Verifica si una URL es de YouTube
  static bool isYouTubeUrl(String url) {
    return extractYouTubeVideoId(url) != null;
  }
  
  /// Obtiene información del video de YouTube usando YouTube Explode
  static Future<YtMusicResult?> getYouTubeVideoInfo(String videoId) async {
    try {
      final ytExplode = YoutubeExplode();
      final video = await ytExplode.videos.get(videoId);
      
      return YtMusicResult(
        title: video.title,
        artist: video.author,
        thumbUrl: video.thumbnails.highResUrl,
        videoId: videoId,
      );
    } catch (e) {
      // print('Error obteniendo información del video: $e');
      return null;
    }
  }
  
  /// Procesa los enlaces compartidos y retorna los resultados de YouTube
  static Future<List<YtMusicResult>> processSharedLinks(List<SharedFile> sharedFiles) async {
    final List<YtMusicResult> results = [];
    
    for (final file in sharedFiles) {
      final text = file.value;
      if (text != null && isYouTubeUrl(text)) {
        final videoId = extractYouTubeVideoId(text);
        if (videoId != null) {
          final videoInfo = await getYouTubeVideoInfo(videoId);
          if (videoInfo != null) {
            results.add(videoInfo);
          }
        }
      }
    }
    
    return results;
  }
  
  /// Escucha los enlaces compartidos entrantes
  static Stream<List<SharedFile>> get sharingIntentStream => 
      FlutterSharingIntent.instance.getMediaStream();
  
  /// Obtiene los enlaces compartidos iniciales (cuando la app se abre desde un enlace)
  static Future<List<SharedFile>> getInitialSharingMedia() async {
    return await FlutterSharingIntent.instance.getInitialSharing();
  }
}
