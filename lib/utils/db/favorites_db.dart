import 'package:hive_ce/hive_ce.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class FavoritesDB {
  static final FavoritesDB _instance = FavoritesDB._internal();
  factory FavoritesDB() => _instance;
  FavoritesDB._internal();

  Box<String>? _box;
  Box<Map>? _metaBox;

  Future<Box<String>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<String>('favorites');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('favorites_meta');
    return _metaBox!;
  }

  Future<void> addFavorite(SongModel song) async {
    final b = await box;
    if (!b.values.contains(song.data)) {
      await b.add(song.data);
    }
    await addFavoritePath(
      song.data,
      title: song.title,
      artist: song.artist,
    );
  }

  Future<void> addFavoritePath(
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

  Future<void> removeFavorite(String path) async {
    final b = await box;
    final key = b.keys.firstWhere((k) => b.get(k) == path, orElse: () => null);
    if (key != null) {
      await b.delete(key);
    }
    final mb = await metaBox;
    await mb.delete(path);
  }

  Future<Map<String, dynamic>?> getFavoriteMeta(String path) async {
    final mb = await metaBox;
    final raw = mb.get(path);
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
  }

  Future<List<String>> getFavoritePaths() async {
    final b = await box;
    return b.values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList()
        .reversed
        .toList();
  }

  Future<List<SongModel>> getFavorites() async {
    final List<String> paths = await getFavoritePaths();

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

  Future<bool> isFavorite(String path) async {
    final b = await box;
    return b.values.contains(path);
  }

  Future<void> removeFavoriteById(int songId) async {
    final b = await box;
    final OnAudioQuery query = OnAudioQuery();
    final allSongs = await query.querySongs();
    try {
      final song = allSongs.firstWhere((s) => s.id == songId);
      final key = b.keys.firstWhere(
        (k) => b.get(k) == song.data,
        orElse: () => null,
      );
      if (key != null) {
        await removeFavorite(song.data);
      }
    } catch (e) {
      // La canción no existe
    }
  }
}
