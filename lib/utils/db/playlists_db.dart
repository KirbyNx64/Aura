import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'playlist_model.dart' as hive_model;
import 'songs_index_db.dart';

class PlaylistsDB {
  static final PlaylistsDB _instance = PlaylistsDB._internal();
  factory PlaylistsDB() => _instance;
  PlaylistsDB._internal();

  Box<hive_model.PlaylistModel>? _box;

  Future<Box<hive_model.PlaylistModel>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<hive_model.PlaylistModel>('playlists');
    return _box!;
  }

  // Crear una nueva lista
  Future<String> createPlaylist(String name) async {
    final b = await box;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final playlist = hive_model.PlaylistModel(id: id, name: name, songPaths: []);
    await b.put(id, playlist);
    return id;
  }

  // Eliminar una lista y sus canciones
  Future<void> deletePlaylist(String playlistId) async {
    final b = await box;
    await b.delete(playlistId);
  }

  // Obtener todas las listas
  Future<List<hive_model.PlaylistModel>> getAllPlaylists() async {
    final b = await box;
    return b.values.toList().reversed.toList();
  }

  // Renombrar una lista
  Future<void> renamePlaylist(String playlistId, String newName) async {
    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist != null) {
      playlist.name = newName;
      await playlist.save();
    }
  }

  // Agregar canción a una lista
  Future<void> addSongToPlaylist(String playlistId, SongModel song) async {
    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist != null && !playlist.songPaths.contains(song.data)) {
      playlist.songPaths.add(song.data);
      await playlist.save();
    }
  }

  // Quitar canción de una lista
  Future<void> removeSongFromPlaylist(String playlistId, String songPath) async {
    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist != null && playlist.songPaths.contains(songPath)) {
      playlist.songPaths.remove(songPath);
      await playlist.save();
    }
  }

  // Obtener canciones de una lista
  Future<List<SongModel>> getSongsFromPlaylist(String playlistId) async {
    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist == null) return [];
    
    // Usar SongsIndexDB para obtener solo canciones no ignoradas
    final SongsIndexDB songsIndex = SongsIndexDB();
    final indexedSongs = await songsIndex.getIndexedSongs();
    
    List<SongModel> ordered = [];
    for (final path in playlist.songPaths) {
      final match = indexedSongs.where((s) => s.data == path);
      if (match.isNotEmpty) {
        ordered.add(match.first);
      }
    }
    return ordered;
  }

  // Verificar si una canción está en una lista
  Future<bool> isSongInPlaylist(String playlistId, String songPath) async {
    final b = await box;
    final playlist = b.get(playlistId);
    return playlist?.songPaths.contains(songPath) ?? false;
  }
}
