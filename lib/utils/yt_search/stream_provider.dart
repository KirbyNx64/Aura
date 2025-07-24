import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class StreamService {
  static final Map<String, String?> _urlCache = {};

  static Future<String?> getBestAudioUrl(String videoId) async {
    if (_urlCache.containsKey(videoId) && _urlCache[videoId] != null) {
      return _urlCache[videoId];
    }
    final url = await _getBestAudioUrl(videoId);
    if (url != null) {
      _urlCache[videoId] = url;
    }
    return url;
  }

  static Future<String?> _getBestAudioUrl(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audio = manifest.audioOnly
        .where((s) => s.codec.mimeType == 'audio/mp4' || s.codec.toString().contains('mp4a'))
        .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      return audio.isNotEmpty ? audio.first.url.toString() : null;
    } catch (_) {
      return null;
    } finally {
      yt.close();
    }
  }
} 