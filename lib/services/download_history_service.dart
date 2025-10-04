import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/download_record.dart';

class DownloadHistoryService {
  static final DownloadHistoryService _instance = DownloadHistoryService._internal();
  factory DownloadHistoryService() => _instance;
  DownloadHistoryService._internal();

  static Database? _database;
  static Future<Database>? _initializationFuture;

  /// Pre-inicializa la base de datos para evitar lag en la primera apertura
  Future<void> preInitialize() async {
    await database;
  }

  Future<Database> get database async {
    // Si ya existe la base de datos, devolverla inmediatamente
    if (_database != null) return _database!;
    
    // Si ya hay una inicialización en proceso, esperar a que termine
    if (_initializationFuture != null) {
      return await _initializationFuture!;
    }
    
    // Iniciar nueva inicialización
    _initializationFuture = _initDatabase();
    _database = await _initializationFuture!;
    _initializationFuture = null;
    
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'download_history.db');
    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE download_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        download_url TEXT NOT NULL,
        thumbnail_url TEXT NOT NULL,
        download_date INTEGER NOT NULL,
        status TEXT NOT NULL,
        error_message TEXT
      )
    ''');
  }

  Future<int> insertDownload(DownloadRecord download) async {
    final db = await database;
    return await db.insert('download_history', download.toMap());
  }

  Future<List<DownloadRecord>> getAllDownloads() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'download_history',
      orderBy: 'download_date DESC',
    );
    return List.generate(maps.length, (i) => DownloadRecord.fromMap(maps[i]));
  }

  Future<List<DownloadRecord>> getCompletedDownloads() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'download_history',
      where: 'status = ?',
      whereArgs: ['completed'],
      orderBy: 'download_date DESC',
    );
    return List.generate(maps.length, (i) => DownloadRecord.fromMap(maps[i]));
  }

  Future<DownloadRecord?> getDownloadById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'download_history',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return DownloadRecord.fromMap(maps.first);
    }
    return null;
  }

  Future<int> updateDownload(DownloadRecord download) async {
    final db = await database;
    return await db.update(
      'download_history',
      download.toMap(),
      where: 'id = ?',
      whereArgs: [download.id],
    );
  }

  Future<int> deleteDownload(int id) async {
    final db = await database;
    return await db.delete(
      'download_history',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteAllDownloads() async {
    final db = await database;
    return await db.delete('download_history');
  }

  Future<int> getDownloadCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM download_history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getCompletedDownloadCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM download_history WHERE status = ?',
      ['completed']
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
