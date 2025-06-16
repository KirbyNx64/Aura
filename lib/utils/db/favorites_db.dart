import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:on_audio_query/on_audio_query.dart';

class FavoritesDB {
  static final FavoritesDB _instance = FavoritesDB._internal();
  factory FavoritesDB() => _instance;
  FavoritesDB._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'favorites.db');
    return await openDatabase(
      path,
      version: 2, // ⚠️ Aumenta la versión si ya tenías una DB anterior
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE favorites(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL
          );
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Si ya existía la DB anterior con otra estructura, la borra y la recrea
        await db.execute('DROP TABLE IF EXISTS favorites');
        await _initDB(); // Recrear con nueva estructura
      },
    );
  }

  Future<void> addFavorite(SongModel song) async {
    final db = await database;
    await db.insert('favorites', {
      'path': song.data,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeFavorite(String path) async {
    final db = await database;
    await db.delete('favorites', where: 'path = ?', whereArgs: [path]);
  }

  Future<List<SongModel>> getFavorites() async {
    final db = await database;
    final rows = await db.query('favorites', orderBy: 'id DESC');
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

  Future<bool> isFavorite(String path) async {
    final db = await database;
    final result = await db.query(
      'favorites',
      where: 'path = ?',
      whereArgs: [path],
    );
    return result.isNotEmpty;
  }
}
