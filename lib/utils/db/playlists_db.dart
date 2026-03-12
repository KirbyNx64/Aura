import 'package:hive_ce/hive_ce.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'playlist_model.dart' as hive_model;
import 'songs_index_db.dart';

class PlaylistsDB {
  static final PlaylistsDB _instance = PlaylistsDB._internal();
  factory PlaylistsDB() => _instance;
  PlaylistsDB._internal();

  Box<hive_model.PlaylistModel>? _box;
  Box<Map>? _metaBox;

  Future<Box<hive_model.PlaylistModel>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<hive_model.PlaylistModel>('playlists');
    return _box!;
  }

  Future<Box<Map>> get metaBox async {
    if (_metaBox != null) return _metaBox!;
    _metaBox = await Hive.openBox<Map>('playlists_meta');
    return _metaBox!;
  }

  String _metaKey(String playlistId, String path) => '$playlistId::$path';

  // Crear una nueva lista
  Future<String> createPlaylist(String name) async {
    final b = await box;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final playlist = hive_model.PlaylistModel(
      id: id,
      name: name,
      songPaths: [],
    );
    await b.put(id, playlist);
    return id;
  }

  // Eliminar una lista y sus canciones
  Future<void> deletePlaylist(String playlistId) async {
    final b = await box;
    await b.delete(playlistId);
    final mb = await metaBox;
    final prefix = '$playlistId::';
    final keysToDelete = mb.keys
        .whereType<String>()
        .where((k) => k.startsWith(prefix))
        .toList();
    for (final key in keysToDelete) {
      await mb.delete(key);
    }
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
    await addSongPathToPlaylist(
      playlistId,
      song.data,
      title: song.title,
      artist: song.artist,
    );
  }

  Future<void> addSongPathToPlaylist(
    String playlistId,
    String path, {
    String? title,
    String? artist,
    String? videoId,
    String? artUri,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return;

    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist == null) return;

    if (!playlist.songPaths.contains(normalizedPath)) {
      playlist.songPaths.add(normalizedPath);
      await playlist.save();
    }

    final mb = await metaBox;
    final existingRaw = mb.get(_metaKey(playlistId, normalizedPath));
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
      await mb.put(_metaKey(playlistId, normalizedPath), next);
    }
  }

  // Quitar canción de una lista
  Future<void> removeSongFromPlaylist(
    String playlistId,
    String songPath,
  ) async {
    final b = await box;
    final playlist = b.get(playlistId);
    if (playlist != null && playlist.songPaths.contains(songPath)) {
      playlist.songPaths.remove(songPath);
      await playlist.save();
    }
    final mb = await metaBox;
    await mb.delete(_metaKey(playlistId, songPath));
  }

  Future<Map<String, dynamic>?> getPlaylistSongMeta(
    String playlistId,
    String path,
  ) async {
    final mb = await metaBox;
    final raw = mb.get(_metaKey(playlistId, path));
    if (raw == null) return null;
    return Map<String, dynamic>.from(raw);
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
