import 'package:hive_ce/hive_ce.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class DislikesDB {
  static final DislikesDB _instance = DislikesDB._internal();
  factory DislikesDB() => _instance;
  DislikesDB._internal();

  Box<String>? _box;
  Box<Map>? _metaBox;

  Future<Box<String>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<String>('dislikes');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('dislikes_meta');
    return _metaBox!;
  }

  Future<void> addDislike(SongModel song) async {
    await addDislikePath(song.data, title: song.title, artist: song.artist);
  }

  Future<void> addDislikePath(
    String path, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
  }) async {
    final b = await box;
    if (!b.values.contains(path)) {
      await b.add(path);
    }
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
  }

  Future<void> removeDislike(String path) async {
    final b = await box;
    final key = b.keys.firstWhere((k) => b.get(k) == path, orElse: () => null);
    if (key != null) {
      await b.delete(key);
    }
    final mb = await metaBox;
    await mb.delete(path);
  }

  Future<Map<String, dynamic>?> getDislikeMeta(String path) async {
    final mb = await metaBox;
    final raw = mb.get(path);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
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
