import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:io';

class StreamCacheDB {
  static Database? _database;
  static const String _tableName = 'stream_cache';
  static const String _dbName = 'stream_cache.db';
  static const int _dbVersion = 1;

  // Columnas de la tabla
  static const String _columnId = 'id';
  static const String _columnVideoId = 'video_id';
  static const String _columnStreamUrl = 'stream_url';
  static const String _columnItag = 'itag';
  static const String _columnCodec = 'codec';
  static const String _columnBitrate = 'bitrate';
  static const String _columnSize = 'size';
  static const String _columnDuration = 'duration';
  static const String _columnLoudnessDb = 'loudness_db';
  static const String _columnCreatedAt = 'created_at';
  static const String _columnLastUsed = 'last_used';
  static const String _columnIsValid = 'is_valid';
  static const String _columnExpiresAt = 'expires_at';

  // Tiempo de expiración por defecto (24 horas)
  static const Duration _defaultExpiration = Duration(hours: 24);

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        $_columnId INTEGER PRIMARY KEY AUTOINCREMENT,
        $_columnVideoId TEXT NOT NULL UNIQUE,
        $_columnStreamUrl TEXT NOT NULL,
        $_columnItag INTEGER,
        $_columnCodec TEXT,
        $_columnBitrate INTEGER,
        $_columnSize INTEGER,
        $_columnDuration INTEGER,
        $_columnLoudnessDb REAL,
        $_columnCreatedAt INTEGER NOT NULL,
        $_columnLastUsed INTEGER NOT NULL,
        $_columnIsValid INTEGER NOT NULL DEFAULT 1,
        $_columnExpiresAt INTEGER NOT NULL
      )
    ''');

    // Crear índices para mejorar el rendimiento
    await db.execute('''
      CREATE INDEX idx_video_id ON $_tableName($_columnVideoId)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_expires_at ON $_tableName($_columnExpiresAt)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_is_valid ON $_tableName($_columnIsValid)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Implementar migraciones si es necesario en el futuro
  }

  /// Guarda un stream en el cache
  Future<void> saveStream({
    required String videoId,
    required String streamUrl,
    int? itag,
    String? codec,
    int? bitrate,
    int? size,
    int? duration,
    double? loudnessDb,
    Duration? expiration,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + (expiration ?? _defaultExpiration).inMilliseconds;

    await db.insert(
      _tableName,
      {
        _columnVideoId: videoId,
        _columnStreamUrl: streamUrl,
        _columnItag: itag,
        _columnCodec: codec,
        _columnBitrate: bitrate,
        _columnSize: size,
        _columnDuration: duration,
        _columnLoudnessDb: loudnessDb,
        _columnCreatedAt: now,
        _columnLastUsed: now,
        _columnIsValid: 1,
        _columnExpiresAt: expiresAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Obtiene un stream del cache si es válido
  Future<CachedStream?> getStream(String videoId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final result = await db.query(
      _tableName,
      where: '$_columnVideoId = ? AND $_columnIsValid = 1 AND $_columnExpiresAt > ?',
      whereArgs: [videoId, now],
      limit: 1,
    );

    if (result.isEmpty) return null;

    final row = result.first;
    
    // Actualizar last_used
    await db.update(
      _tableName,
      {_columnLastUsed: now},
      where: '$_columnId = ?',
      whereArgs: [row[_columnId]],
    );

    return CachedStream(
      videoId: row[_columnVideoId] as String,
      streamUrl: row[_columnStreamUrl] as String,
      itag: row[_columnItag] as int?,
      codec: row[_columnCodec] as String?,
      bitrate: row[_columnBitrate] as int?,
      size: row[_columnSize] as int?,
      duration: row[_columnDuration] as int?,
      loudnessDb: row[_columnLoudnessDb] as double?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row[_columnCreatedAt] as int),
      lastUsed: DateTime.fromMillisecondsSinceEpoch(row[_columnLastUsed] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(row[_columnExpiresAt] as int),
    );
  }

  /// Marca un stream como inválido
  Future<void> invalidateStream(String videoId) async {
    final db = await database;
    await db.update(
      _tableName,
      {_columnIsValid: 0},
      where: '$_columnVideoId = ?',
      whereArgs: [videoId],
    );
  }

  /// Valida si un stream sigue siendo válido haciendo una petición HEAD
  Future<bool> validateStream(String streamUrl) async {
    try {
      // print('🔍 [CACHE_DB] Validando stream: $streamUrl');
      final client = HttpClient();
      final request = await client.headUrl(Uri.parse(streamUrl));
      final response = await request.close();
      client.close();
      
      final isValid = response.statusCode >= 200 && response.statusCode < 300;
      // print('🔍 [CACHE_DB] Stream ${isValid ? 'válido' : 'inválido'} (Status: ${response.statusCode})');
      
      // Considerar válido si el status code es 200-299
      return isValid;
    } catch (e) {
      // print('❌ [CACHE_DB] Error validando stream: $e');
      return false;
    }
  }

  /// Valida y actualiza un stream si es necesario
  Future<CachedStream?> getValidatedStream(String videoId) async {
    final cached = await getStream(videoId);
    if (cached == null) {
      // print('🔍 [CACHE_DB] No hay stream en cache para videoId: $videoId');
      return null;
    }

    // print('🔍 [CACHE_DB] Stream encontrado en cache para videoId: $videoId');
    // print('🔍 [CACHE_DB] Creado: ${cached.createdAt}');
    // print('🔍 [CACHE_DB] Expira: ${cached.expiresAt}');
    
    // Validar el stream
    final isValid = await validateStream(cached.streamUrl);
    if (!isValid) {
      // print('❌ [CACHE_DB] Stream inválido, marcando como inválido en la DB');
      // Marcar como inválido y retornar null
      await invalidateStream(videoId);
      return null;
    }

    // print('✅ [CACHE_DB] Stream válido, usando desde cache');
    return cached;
  }

  /// Limpia streams expirados
  Future<int> cleanExpiredStreams() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    return await db.delete(
      _tableName,
      where: '$_columnExpiresAt < ? OR $_columnIsValid = 0',
      whereArgs: [now],
    );
  }

  /// Obtiene estadísticas del cache
  Future<CacheStats> getCacheStats() async {
    final db = await database;
    
    final totalResult = await db.rawQuery('SELECT COUNT(*) as count FROM $_tableName');
    final validResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableName WHERE $_columnIsValid = 1 AND $_columnExpiresAt > ?',
      [DateTime.now().millisecondsSinceEpoch],
    );
    final expiredResult = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableName WHERE $_columnExpiresAt <= ?',
      [DateTime.now().millisecondsSinceEpoch],
    );

    return CacheStats(
      totalStreams: totalResult.first['count'] as int,
      validStreams: validResult.first['count'] as int,
      expiredStreams: expiredResult.first['count'] as int,
    );
  }

  /// Limpia todo el cache
  Future<void> clearCache() async {
    final db = await database;
    await db.delete(_tableName);
  }

  /// Cierra la base de datos
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}

/// Modelo para representar un stream en cache
class CachedStream {
  final String videoId;
  final String streamUrl;
  final int? itag;
  final String? codec;
  final int? bitrate;
  final int? size;
  final int? duration;
  final double? loudnessDb;
  final DateTime createdAt;
  final DateTime lastUsed;
  final DateTime expiresAt;

  CachedStream({
    required this.videoId,
    required this.streamUrl,
    this.itag,
    this.codec,
    this.bitrate,
    this.size,
    this.duration,
    this.loudnessDb,
    required this.createdAt,
    required this.lastUsed,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toMap() {
    return {
      'videoId': videoId,
      'streamUrl': streamUrl,
      'itag': itag,
      'codec': codec,
      'bitrate': bitrate,
      'size': size,
      'duration': duration,
      'loudnessDb': loudnessDb,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'lastUsed': lastUsed.millisecondsSinceEpoch,
      'expiresAt': expiresAt.millisecondsSinceEpoch,
    };
  }
}

/// Estadísticas del cache
class CacheStats {
  final int totalStreams;
  final int validStreams;
  final int expiredStreams;

  CacheStats({
    required this.totalStreams,
    required this.validStreams,
    required this.expiredStreams,
  });

  double get hitRate => totalStreams > 0 ? validStreams / totalStreams : 0.0;
}
