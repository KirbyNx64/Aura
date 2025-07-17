import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';

class SongsIndexDB {
  static final SongsIndexDB _instance = SongsIndexDB._internal();
  factory SongsIndexDB() => _instance;
  SongsIndexDB._internal();

  Database? _db;
  bool _isIndexed = false;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'songs_index.db');
    return await openDatabase(
      path,
      version: 2, // Incrementar versión para forzar actualización
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE songs_index(
            path TEXT PRIMARY KEY,
            folder_path TEXT NOT NULL
          );
        ''');
        await db.execute('CREATE INDEX idx_folder_path ON songs_index(folder_path);');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('DROP TABLE IF EXISTS songs_index');
          await db.execute('''
            CREATE TABLE songs_index(
              path TEXT PRIMARY KEY,
              folder_path TEXT NOT NULL
            );
          ''');
          await db.execute('CREATE INDEX idx_folder_path ON songs_index(folder_path);');
        }
      },
    );
  }

  String _getFolderPath(String filePath) {
    var normalizedPath = p.normalize(filePath);
    var dirPath = p.dirname(normalizedPath);
    dirPath = p.normalize(dirPath);
    if (dirPath.contains('/')) dirPath = dirPath.replaceAll('/', '\\');
    dirPath = dirPath.trim();
    if (dirPath.endsWith('\\') && dirPath.length > 3) {
      dirPath = dirPath.substring(0, dirPath.length - 1);
    }
    dirPath = dirPath.toLowerCase();
    return dirPath;
  }

  /// Verifica si la base de datos necesita ser indexada
  Future<bool> needsIndexing() async {
    if (_isIndexed) return false;
    
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM songs_index');
    final count = result.first['count'] as int;
    
    if (count == 0) {
      return true;
    }
    
    _isIndexed = true;
    return false;
  }

  /// Limpia archivos que ya no existen del índice
  Future<void> cleanNonExistentFiles() async {
    final db = await database;
    final rows = await db.query('songs_index');  
    final filesToDelete = <String>[];
    for (final row in rows) {      final path = row['path'] as String;
      final file = File(path);
      
      if (!await file.exists()) {     filesToDelete.add(path);
      }
    }
    
    if (filesToDelete.isNotEmpty) {
      await db.transaction((txn) async {
        for (final path in filesToDelete) {
          await txn.delete(
         'songs_index',
            where: 'path = ?',
            whereArgs: [path],
          );
        }
      });
    }
  }

  /// Sincroniza la base de datos con archivos nuevos y elimina los que ya no existen
  Future<void> syncDatabase() async {
    final db = await database;
    final OnAudioQuery audioQuery = OnAudioQuery();
    final allSongs = await audioQuery.querySongs();
    
    // Obtener todas las rutas actuales en la base de datos
    final dbRows = await db.query('songs_index');
    final dbPaths = dbRows.map((row) => row['path'] as String).toSet();
    
    // Obtener todas las rutas actuales del dispositivo
    final devicePaths = allSongs.map((song) => song.data).toSet();
    
    // Encontrar archivos a eliminar (están en DB pero no en dispositivo)
    final filesToDelete = dbPaths.difference(devicePaths);
    
    // Encontrar archivos a agregar (están en dispositivo pero no en DB)
    final filesToAdd = devicePaths.difference(dbPaths);
    
    await db.transaction((txn) async {
      // Eliminar archivos que ya no existen
      for (final path in filesToDelete) {
        await txn.delete(
          'songs_index',
          where: 'path = ?',
          whereArgs: [path],
        );
      }
      
      // Agregar archivos nuevos
      for (final song in allSongs) {
        if (filesToAdd.contains(song.data)) {
          final folderPath = _getFolderPath(song.data);
          await txn.insert('songs_index', {
            'path': song.data,
            'folder_path': folderPath,
          });
        }
      }
    });
  }

  /// Analiza el almacenamiento y actualiza el índice SOLO con rutas
  Future<void> indexAllSongs() async {
    // Verificar si ya está indexada
    if (!await needsIndexing()) {
      // Si ya está indexada, sincronizar en lugar de reindexar todo
      await syncDatabase();
      return;
    }

    final db = await database;
    final OnAudioQuery audioQuery = OnAudioQuery();
    final allSongs = await audioQuery.querySongs();

    await db.transaction((txn) async {
      await txn.delete('songs_index');
      for (final song in allSongs) {
        final folderPath = _getFolderPath(song.data);
        await txn.insert('songs_index', {
          'path': song.data,
          'folder_path': folderPath,
        });
      }
    });
    
    _isIndexed = true;
  }

  /// Fuerza la reindexación (útil para cuando se agregan/eliminan canciones)
  Future<void> forceReindex() async {
    _isIndexed = false;
    await indexAllSongs();
  }

  Future<List<String>> getFolders() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT DISTINCT folder_path FROM songs_index ORDER BY folder_path ASC');
    return rows.map((e) => e['folder_path'] as String).toList();
  }

  Future<List<String>> getSongsFromFolder(String folderPath) async {
    final db = await database;
    final rows = await db.query(
      'songs_index',
      where: 'folder_path = ?',
      whereArgs: [folderPath],
      orderBy: 'path ASC',
    );
    return rows.map((row) => row['path'] as String).toList();
  }
}