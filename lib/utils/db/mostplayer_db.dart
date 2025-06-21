import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:on_audio_query/on_audio_query.dart';

class MostPlayedDB {
  static final MostPlayedDB _instance = MostPlayedDB._internal();
  factory MostPlayedDB() => _instance;
  MostPlayedDB._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'most_played.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE most_played(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            play_count INTEGER NOT NULL DEFAULT 0
          );
        ''');
      },
    );
  }

  Future<void> incrementPlayCount(SongModel song) async {
    final db = await database;
    final existing = await db.query(
      'most_played',
      where: 'path = ?',
      whereArgs: [song.data],
    );
    if (existing.isNotEmpty) {
      final count = (existing.first['play_count'] as int) + 1;
      await db.update(
        'most_played',
        {'play_count': count},
        where: 'path = ?',
        whereArgs: [song.data],
      );
    } else {
      await db.insert('most_played', {'path': song.data, 'play_count': 1});
    }
  }

  Future<List<SongModel>> getMostPlayed({int limit = 20}) async {
    final db = await database;
    final rows = await db.query(
      'most_played',
      orderBy: 'play_count DESC, id DESC',
      limit: limit,
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

  Future<int> getPlayCount(String path) async {
    final db = await database;
    final result = await db.query(
      'most_played',
      where: 'path = ?',
      whereArgs: [path],
    );
    if (result.isNotEmpty) {
      return result.first['play_count'] as int;
    }
    return 0;
  }
}
