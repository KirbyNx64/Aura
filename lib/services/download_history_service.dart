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
    final db = await database;
    // Asegurar que la columna viewed existe
    await _ensureViewedColumnExists(db);
  }

  /// Asegura que la columna viewed existe en la tabla
  Future<void> _ensureViewedColumnExists(Database db) async {
    try {
      if (!await _columnExists(db, 'download_history', 'viewed')) {
        await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
        // print('✅ Columna viewed agregada exitosamente');
      }
    } catch (e) {
      // print('⚠️ Error al verificar/agregar columna viewed: $e');
    }
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
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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
        error_message TEXT,
        viewed INTEGER DEFAULT 0
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Verificar si la columna 'viewed' ya existe antes de intentar agregarla
      try {
        await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
      } catch (e) {
        // Si la columna ya existe, ignorar el error
        // print('La columna viewed ya existe o error al agregarla: $e');
      }
    }
  }

  /// Verifica si la columna viewed existe en la tabla
  Future<bool> _columnExists(Database db, String tableName, String columnName) async {
    final result = await db.rawQuery('PRAGMA table_info($tableName)');
    return result.any((column) => column['name'] == columnName);
  }

  Future<int> insertDownload(DownloadRecord download) async {
    try {
      final db = await database;
      
      // Verificar si la columna viewed existe antes de insertar
      if (!await _columnExists(db, 'download_history', 'viewed')) {
        try {
          await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
        } catch (e) {
          // Si falla, continuar e intentar insertar de todas formas
        }
      }
      
      return await db.insert('download_history', download.toMap());
    } catch (e) {
      // Si falla al insertar con la columna viewed, intentar sin ella
      try {
        final db = await database;
        final map = download.toMap();
        map.remove('viewed'); // Remover la columna viewed si causa problemas
        return await db.insert('download_history', map);
      } catch (e2) {
        rethrow;
      }
    }
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
    try {
      final db = await database;
      
      // Verificar si la columna viewed existe antes de actualizar
      if (!await _columnExists(db, 'download_history', 'viewed')) {
        try {
          await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
        } catch (e) {
          // Si falla, continuar e intentar actualizar de todas formas
        }
      }
      
      return await db.update(
        'download_history',
        download.toMap(),
        where: 'id = ?',
        whereArgs: [download.id],
      );
    } catch (e) {
      // Si falla al actualizar con la columna viewed, intentar sin ella
      try {
        final db = await database;
        final map = download.toMap();
        map.remove('viewed'); // Remover la columna viewed si causa problemas
        return await db.update(
          'download_history',
          map,
          where: 'id = ?',
          whereArgs: [download.id],
        );
      } catch (e2) {
        rethrow;
      }
    }
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

  /// Verifica si hay descargas sin ver
  Future<bool> hasUnviewedDownloads() async {
    try {
      final db = await database;
      
      // Verificar si la columna existe
      if (!await _columnExists(db, 'download_history', 'viewed')) {
        // Si la columna no existe, intentar agregarla
        try {
          await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
        } catch (e) {
          // Si falla, retornar false (no hay descargas sin ver)
          return false;
        }
      }
      
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM download_history WHERE status = ? AND viewed = 0',
        ['completed']
      );
      return (Sqflite.firstIntValue(result) ?? 0) > 0;
    } catch (e) {
      // En caso de error, asumir que no hay descargas sin ver
      return false;
    }
  }

  /// Marca todas las descargas como vistas
  Future<int> markAllAsViewed() async {
    try {
      final db = await database;
      
      // Verificar si la columna existe
      if (!await _columnExists(db, 'download_history', 'viewed')) {
        // Si la columna no existe, intentar agregarla
        try {
          await db.execute('ALTER TABLE download_history ADD COLUMN viewed INTEGER DEFAULT 0');
        } catch (e) {
          // Si falla, retornar 0 (ninguna fila actualizada)
          return 0;
        }
      }
      
      return await db.update(
        'download_history',
        {'viewed': 1},
        where: 'viewed = 0',
      );
    } catch (e) {
      // En caso de error, retornar 0
      return 0;
    }
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}
