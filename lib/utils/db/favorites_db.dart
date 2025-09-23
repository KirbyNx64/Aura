import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'songs_index_db.dart';

class FavoritesDB {
  static final FavoritesDB _instance = FavoritesDB._internal();
  factory FavoritesDB() => _instance;
  FavoritesDB._internal();

  Box<String>? _box;

  Future<Box<String>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<String>('favorites');
    return _box!;
  }

  Future<void> addFavorite(SongModel song) async {
    final b = await box;
    if (!b.values.contains(song.data)) {
      await b.add(song.data);
    }
  }

  Future<void> removeFavorite(String path) async {
    final b = await box;
    final key = b.keys.firstWhere((k) => b.get(k) == path, orElse: () => null);
    if (key != null) {
      await b.delete(key);
    }
  }

  Future<List<SongModel>> getFavorites() async {
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
      final key = b.keys.firstWhere((k) => b.get(k) == song.data, orElse: () => null);
      if (key != null) {
        await b.delete(key);
      }
    } catch (e) {
      // La canción no existe
    }
  }
}
