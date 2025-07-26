import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';

class MostPlayedDB {
  static final MostPlayedDB _instance = MostPlayedDB._internal();
  factory MostPlayedDB() => _instance;
  MostPlayedDB._internal();

  Box<Map>? _box;

  Future<Box<Map>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<Map>('most_played');
    return _box!;
  }

  Future<void> incrementPlayCount(SongModel song) async {
    final b = await box;
    final path = song.data;
    final playCount = b.get(path)?['play_count'] ?? 0;
    await b.put(path, {'play_count': playCount + 1});
  }

  Future<List<SongModel>> getMostPlayed({int limit = 20}) async {
    final b = await box;
    final entries = b.toMap().entries.toList();
    entries.sort((a, b) => (b.value['play_count'] as int).compareTo(a.value['play_count'] as int));
    final paths = entries.take(limit).map((e) => e.key as String).toList();

    final OnAudioQuery query = OnAudioQuery();
    final allSongs = await query.querySongs();

    List<SongModel> ordered = [];
    for (final path in paths) {
      final match = allSongs.where((s) => s.data == path);
      if (match.isNotEmpty) {
        ordered.add(match.first);
      }
    }
    return ordered;
  }

  Future<int> getPlayCount(String path) async {
    final b = await box;
    return b.get(path)?['play_count'] ?? 0;
  }
}
