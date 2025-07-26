import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

part 'synced_lyrics_service.g.dart';

@HiveType(typeId: 0)
class LyricsData extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String? synced;

  @HiveField(2)
  String? plainLyrics;

  LyricsData({
    required this.id,
    this.synced,
    this.plainLyrics,
  });
}

class SyncedLyricsService {
  static const String _boxName = 'lyrics_box';
  static Box<LyricsData>? _box;

  static Future<Box<LyricsData>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<LyricsData>(_boxName);
    return _box!;
  }

  static Future<void> initialize() async {
    await Hive.initFlutter();
    Hive.registerAdapter(LyricsDataAdapter());
  }

  static Future<LyricsData?> getSyncedLyrics(
    MediaItem song, {
    int? durInSec,
  }) async {
    final lyricsBox = await box;

    // Buscar en la base local
    final existingLyrics = lyricsBox.get(song.id);
    if (existingLyrics != null) {
      return existingLyrics;
    }

    // Si no está, buscar online
    final dur = song.duration?.inSeconds ?? durInSec ?? 0;
    final url =
        'https://lrclib.net/api/get?artist_name=${Uri.encodeComponent(song.artist ?? "")}'
        '&track_name=${Uri.encodeComponent(song.title)}'
        '&duration=$dur';

    try {
      final response = (await Dio().get(url)).data;
      if (response["syncedLyrics"] != null) {
        final lyricsData = LyricsData(
          id: song.id,
          synced: response["syncedLyrics"],
          plainLyrics: response["plainLyrics"],
        );
        await lyricsBox.put(song.id, lyricsData);
        return lyricsData;
      }
    } on DioException {
      // Puedes loggear el error si quieres
    }
    return null;
  }

  static Future<void> clearLyrics() async {
    final lyricsBox = await box;
    await lyricsBox.clear();
  }
}
