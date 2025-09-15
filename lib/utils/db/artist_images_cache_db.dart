import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class ArtistImagesCacheDB {
  static Database? _database;
  static const String _tableName = 'artist_images_cache';
  
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = join(databasesPath, 'artist_images_cache.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        artist_name TEXT NOT NULL UNIQUE,
        thumb_url TEXT,
        browse_id TEXT,
        subscribers TEXT,
        cached_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL
      )
    ''');
    
    // Crear índice para búsquedas rápidas
    await db.execute('''
      CREATE INDEX idx_artist_name ON $_tableName(artist_name)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_expires_at ON $_tableName(expires_at)
    ''');
  }

  // Guardar imagen de artista en cache
  static Future<void> cacheArtistImage({
    required String artistName,
    String? thumbUrl,
    String? browseId,
    String? subscribers,
    Duration cacheDuration = const Duration(days: 7),
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = now + cacheDuration.inMilliseconds;

    await db.insert(
      _tableName,
      {
        'artist_name': artistName,
        'thumb_url': thumbUrl,
        'browse_id': browseId,
        'subscribers': subscribers,
        'cached_at': now,
        'expires_at': expiresAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Obtener imagen de artista desde cache
  static Future<Map<String, dynamic>?> getCachedArtistImage(String artistName) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final result = await db.query(
      _tableName,
      where: 'artist_name = ? AND expires_at > ?',
      whereArgs: [artistName, now],
      limit: 1,
    );

    if (result.isNotEmpty) {
      return {
        'name': result.first['artist_name'],
        'thumbUrl': result.first['thumb_url'],
        'browseId': result.first['browse_id'],
        'subscribers': result.first['subscribers'],
        'cachedAt': result.first['cached_at'],
        'expiresAt': result.first['expires_at'],
      };
    }

    return null;
  }

  // Obtener múltiples imágenes de artistas desde cache
  static Future<List<Map<String, dynamic>>> getCachedArtistImages(List<String> artistNames) async {
    if (artistNames.isEmpty) return [];
    
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final placeholders = artistNames.map((_) => '?').join(',');
    final result = await db.query(
      _tableName,
      where: 'artist_name IN ($placeholders) AND expires_at > ?',
      whereArgs: [...artistNames, now],
    );

    return result.map((row) => {
      'name': row['artist_name'],
      'thumbUrl': row['thumb_url'],
      'browseId': row['browse_id'],
      'subscribers': row['subscribers'],
      'cachedAt': row['cached_at'],
      'expiresAt': row['expires_at'],
    }).toList();
  }

  // Limpiar cache expirado
  static Future<int> cleanExpiredCache() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    return await db.delete(
      _tableName,
      where: 'expires_at <= ?',
      whereArgs: [now],
    );
  }

  // Limpiar todo el cache
  static Future<void> clearAllCache() async {
    final db = await database;
    await db.delete(_tableName);
  }

  // Obtener estadísticas del cache
  static Future<Map<String, int>> getCacheStats() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_tableName')) ?? 0;
    final expired = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM $_tableName WHERE expires_at <= ?',
      [now]
    )) ?? 0;
    final valid = total - expired;
    
    return {
      'total': total,
      'valid': valid,
      'expired': expired,
    };
  }

  // Verificar si un artista está en cache y es válido
  static Future<bool> isArtistCached(String artistName) async {
    final cached = await getCachedArtistImage(artistName);
    return cached != null;
  }

  // Actualizar solo la URL de imagen de un artista existente
  static Future<void> updateArtistImageUrl(String artistName, String thumbUrl) async {
    final db = await database;
    await db.update(
      _tableName,
      {'thumb_url': thumbUrl},
      where: 'artist_name = ?',
      whereArgs: [artistName],
    );
  }
}
