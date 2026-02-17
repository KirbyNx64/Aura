import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class DislikesDB {
  static final DislikesDB _instance = DislikesDB._internal();
  factory DislikesDB() => _instance;
  DislikesDB._internal();

  Box<String>? _box;

  Future<Box<String>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<String>('dislikes');
    return _box!;
  }

  Future<void> addDislike(SongModel song) async {
    final b = await box;
    if (!b.values.contains(song.data)) {
      await b.add(song.data);
    }
  }

  Future<void> addDislikePath(String path) async {
    final b = await box;
    if (!b.values.contains(path)) {
      await b.add(path);
    }
  }

  Future<void> removeDislike(String path) async {
    final b = await box;
    final key = b.keys.firstWhere((k) => b.get(k) == path, orElse: () => null);
    if (key != null) {
      await b.delete(key);
    }
  }

  Future<List<SongModel>> getDislikes() async {
    final b = await box;
    final List<String> paths = b.values.toList().reversed.toList();

    // Usar SongsIndexDB para obtener solo canciones no ignoradas
    final SongsIndexDB songsIndex = SongsIndexDB();
    final indexedSongs = await songsIndex.getIndexedSongs();

    List<SongModel> ordered = [];
    for (final path in paths) {
      final match = indexedSongs.where((s) => s.data == path);
      if (match.isNotEmpty) {
        ordered.add(match.first);
      }
    }
    return ordered;
  }

  Future<bool> isDisliked(String path) async {
    final b = await box;
    return b.values.contains(path);
  }
}
