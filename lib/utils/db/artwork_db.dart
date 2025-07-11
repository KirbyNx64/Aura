import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class ArtworkDB {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  static Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'artwork_cache.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE artwork_cache (
            song_path TEXT PRIMARY KEY,
            artwork_path TEXT
          )
        ''');
      },
    );
  }

  static Future<void> insertArtwork(String songPath, String artworkPath) async {
    final db = await database;
    await db.insert(
      'artwork_cache',
      {'song_path': songPath, 'artwork_path': artworkPath},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> getArtwork(String songPath) async {
    final db = await database;
    final result = await db.query(
      'artwork_cache',
      where: 'song_path = ?',
      whereArgs: [songPath],
      limit: 1,
    );
    if (result.isNotEmpty) {
      return result.first['artwork_path'] as String;
    }
    return null;
  }
}