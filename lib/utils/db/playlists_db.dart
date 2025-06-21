import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:on_audio_query/on_audio_query.dart';

class PlaylistsDB {
  static final PlaylistsDB _instance = PlaylistsDB._internal();
  factory PlaylistsDB() => _instance;
  PlaylistsDB._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'playlists.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // Tabla de listas
        await db.execute('''
          CREATE TABLE playlists(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL
          );
        ''');
        // Tabla de canciones por lista
        await db.execute('''
          CREATE TABLE playlist_songs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            playlist_id INTEGER NOT NULL,
            song_path TEXT NOT NULL,
            FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
          );
        ''');
      },
    );
  }

  // Crear una nueva lista
  Future<int> createPlaylist(String name) async {
    final db = await database;
    return await db.insert('playlists', {'name': name});
  }

  // Eliminar una lista y sus canciones
  Future<void> deletePlaylist(int playlistId) async {
    final db = await database;
    await db.delete('playlists', where: 'id = ?', whereArgs: [playlistId]);
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
  }

  // Obtener todas las listas
  Future<List<Map<String, dynamic>>> getAllPlaylists() async {
    final db = await database;
    return await db.query('playlists', orderBy: 'id DESC');
  }

  // Renombrar una lista
  Future<void> renamePlaylist(int playlistId, String newName) async {
    final db = await database;
    await db.update(
      'playlists',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  // Agregar canción a una lista
  Future<void> addSongToPlaylist(int playlistId, SongModel song) async {
    final db = await database;
    await db.insert('playlist_songs', {
      'playlist_id': playlistId,
      'song_path': song.data,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Quitar canción de una lista
  Future<void> removeSongFromPlaylist(int playlistId, String songPath) async {
    final db = await database;
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ? AND song_path = ?',
      whereArgs: [playlistId, songPath],
    );
  }

  // Obtener canciones de una lista
  Future<List<SongModel>> getSongsFromPlaylist(int playlistId) async {
    final db = await database;
    final rows = await db.query(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'id DESC',
    );
    final List<String> paths = rows
        .map((e) => e['song_path'] as String)
        .toList();

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

  // Verificar si una canción está en una lista
  Future<bool> isSongInPlaylist(int playlistId, String songPath) async {
    final db = await database;
    final result = await db.query(
      'playlist_songs',
      where: 'playlist_id = ? AND song_path = ?',
      whereArgs: [playlistId, songPath],
    );
    return result.isNotEmpty;
  }
}
