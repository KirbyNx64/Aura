import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class RecentsDB {
  static final RecentsDB _instance = RecentsDB._internal();
  factory RecentsDB() => _instance;
  RecentsDB._internal();

  static const int maxRecents = 300;
  Box<int>? _box;

  Future<Box<int>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<int>('recents');
    return _box!;
  }

  Future<void> addRecent(SongModel song) async {
    await addRecentPath(song.data);
  }

  Future<void> addRecentPath(String path) async {
    final b = await box;
    final now = DateTime.now().millisecondsSinceEpoch;
    await b.put(path, now);

    // Limita a los 50 más recientes
    if (b.length > maxRecents) {
      final entries = b.toMap().entries.toList();
      entries.sort((a, b) => b.value.compareTo(a.value)); // Más recientes primero
      final toRemove = entries.skip(maxRecents).map((e) => e.key).toList();
      await b.deleteAll(toRemove);
    }
  }

  Future<List<SongModel>> getRecents() async {
    final b = await box;
    final entries = b.toMap().entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value)); // Más recientes primero
    final paths = entries.take(maxRecents).map((e) => e.key as String).toList();

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

  Future<void> removeRecent(String path) async {
    final b = await box;
    await b.delete(path);
  }

  Future<void> clearAll() async {
    final b = await box;
    await b.clear();
  }
}
