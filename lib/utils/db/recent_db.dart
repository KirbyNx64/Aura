import 'package:hive_ce/hive_ce.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class RecentsDB {
  static final RecentsDB _instance = RecentsDB._internal();
  factory RecentsDB() => _instance;
  RecentsDB._internal();

  static const int maxRecents = 300;
  Box<int>? _box;
  Box<Map>? _metaBox;

  Future<Box<int>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<int>('recents');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('recents_meta');
    return _metaBox!;
  }

  Future<void> addRecent(SongModel song) async {
    await addRecentPath(song.data, title: song.title, artist: song.artist);
  }

  Future<void> addRecentPath(
    String path, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
  }) async {
    final b = await box;
    final now = DateTime.now().millisecondsSinceEpoch;
    await b.put(path, now);
    final mb = await metaBox;
    final existingRaw = mb.get(path);
    final existing = existingRaw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(existingRaw);
    final next = <String, dynamic>{
      ...existing,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      if (artist != null && artist.trim().isNotEmpty) 'artist': artist.trim(),
      if (videoId != null && videoId.trim().isNotEmpty)
        'videoId': videoId.trim(),
      if (artUri != null && artUri.trim().isNotEmpty) 'artUri': artUri.trim(),
    };
    if (next.isNotEmpty) {
      await mb.put(path, next);
    }

    // Limita al máximo configurado de recientes
    if (b.length > maxRecents) {
      final entries = b.toMap().entries.toList();
      entries.sort(
        (a, b) => b.value.compareTo(a.value),
      ); // Más recientes primero
      final toRemove = entries.skip(maxRecents).map((e) => e.key).toList();
      await b.deleteAll(toRemove);
      await mb.deleteAll(toRemove);
    }
  }

  Future<Map<String, dynamic>?> getRecentMeta(String path) async {
    final mb = await metaBox;
    final raw = mb.get(path);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  Future<List<String>> getRecentPaths() async {
    final b = await box;
    final entries = b.toMap().entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries.take(maxRecents).map((e) => e.key as String).toList();
  }

  Future<List<SongModel>> getRecents() async {
    final paths = await getRecentPaths();

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
    final mb = await metaBox;
    await mb.delete(path);
  }

  Future<void> clearAll() async {
    final b = await box;
    await b.clear();
    final mb = await metaBox;
    await mb.clear();
  }
}
