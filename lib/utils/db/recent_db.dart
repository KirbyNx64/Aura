import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:on_audio_query/on_audio_query.dart';

class RecentsDB {
  static final RecentsDB _instance = RecentsDB._internal();
  factory RecentsDB() => _instance;
  RecentsDB._internal();

  static const int maxRecents = 50;
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'recents.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE recents(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            timestamp INTEGER NOT NULL
          );
        ''');
      },
    );
  }

  Future<void> addRecent(SongModel song) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Inserta o actualiza la canción con la nueva marca de tiempo
    await db.insert('recents', {
      'path': song.data,
      'timestamp': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // Borra las más antiguas si hay más de 50
    await db.execute('''
      DELETE FROM recents
      WHERE id NOT IN (
        SELECT id FROM recents ORDER BY timestamp DESC LIMIT $maxRecents
      )
    ''');
  }

  Future<void> addRecentPath(String path) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('recents', {
      'path': path,
      'timestamp': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.execute('''
      DELETE FROM recents
      WHERE id NOT IN (
        SELECT id FROM recents ORDER BY timestamp DESC LIMIT $maxRecents
      )
    ''');
  }

  Future<List<SongModel>> getRecents() async {
    final db = await database;
    final rows = await db.query(
      'recents',
      orderBy: 'timestamp DESC',
      limit: maxRecents,
    );
    final List<String> paths = rows.map((e) => e['path'] as String).toList();

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

  Future<void> removeRecent(String path) async {
    final db = await database;
    await db.delete('recents', where: 'path = ?', whereArgs: [path]);
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('recents');
  }
}
