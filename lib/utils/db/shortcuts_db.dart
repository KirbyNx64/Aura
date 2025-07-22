import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class ShortcutsDB {
  static final ShortcutsDB _instance = ShortcutsDB._internal();
  factory ShortcutsDB() => _instance;
  ShortcutsDB._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'shortcuts.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE shortcuts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            song_path TEXT UNIQUE,
            order_index INTEGER
          )
        ''');
      },
    );
  }

  Future<List<String>> getShortcuts() async {
    final db = await database;
    final res = await db.query(
      'shortcuts',
      orderBy: 'order_index ASC',
      limit: 18,
    );
    return res.map((e) => e['song_path'] as String).toList();
  }

  Future<void> addShortcut(String songPath) async {
    final db = await database;
    final shortcuts = await getShortcuts();
    if (shortcuts.contains(songPath)) return;
    if (shortcuts.length >= 18) {
      // No agregar si ya hay 18
      return;
    }
    await db.insert(
      'shortcuts',
      {
        'song_path': songPath,
        'order_index': shortcuts.length,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeShortcut(String songPath) async {
    final db = await database;
    await db.delete('shortcuts', where: 'song_path = ?', whereArgs: [songPath]);
    // Reordenar los accesos directos restantes
    final shortcuts = await getShortcuts();
    for (int i = 0; i < shortcuts.length; i++) {
      await db.update('shortcuts', {'order_index': i}, where: 'song_path = ?', whereArgs: [shortcuts[i]]);
    }
  }

  Future<bool> isShortcut(String songPath) async {
    final db = await database;
    final res = await db.query('shortcuts', where: 'song_path = ?', whereArgs: [songPath]);
    return res.isNotEmpty;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete('shortcuts');
  }
} 