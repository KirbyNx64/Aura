import 'package:hive/hive.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

class SongsIndexDB {
  static final SongsIndexDB _instance = SongsIndexDB._internal();
  factory SongsIndexDB() => _instance;
  SongsIndexDB._internal();

  bool _isIndexed = false;
  Box<Map>? _box;

  Future<Box<Map>> get box async {
    if (_box != null) return _box!;
    _box = await Hive.openBox<Map>('songs_index');
    return _box!;
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
    final b = await box;
    if (b.isEmpty) {
      return true;
    }
    _isIndexed = true;
    return false;
  }

  /// Limpia archivos que ya no existen del índice
  Future<void> cleanNonExistentFiles() async {
    final b = await box;
    final filesToDelete = <String>[];
    for (final path in b.keys) {
      final file = File(path);
      if (!await file.exists()) {
        filesToDelete.add(path);
      }
    }
    if (filesToDelete.isNotEmpty) {
      await b.deleteAll(filesToDelete);
    }
  }

  /// Sincroniza la base de datos con archivos nuevos y elimina los que ya no existen
  Future<void> syncDatabase() async {
    final b = await box;
    final OnAudioQuery audioQuery = OnAudioQuery();
    final allSongs = await audioQuery.querySongs();

    // Obtener todas las rutas actuales en la base de datos
    final dbPaths = b.keys.cast<String>().toSet();

    // Obtener todas las rutas actuales del dispositivo
    final devicePaths = allSongs.map((song) => song.data).toSet();

    // Encontrar archivos a eliminar (están en DB pero no en dispositivo)
    final filesToDelete = dbPaths.difference(devicePaths);

    // Encontrar archivos a agregar (están en dispositivo pero no en DB)
    final filesToAdd = devicePaths.difference(dbPaths);

    // Eliminar archivos que ya no existen
    if (filesToDelete.isNotEmpty) {
      await b.deleteAll(filesToDelete);
    }

    // Agregar archivos nuevos
    for (final song in allSongs) {
      if (filesToAdd.contains(song.data)) {
        final folderPath = _getFolderPath(song.data);
        await b.put(song.data, {'folder_path': folderPath});
      }
    }
  }

  /// Analiza el almacenamiento y actualiza el índice SOLO con rutas
  Future<void> indexAllSongs() async {
    if (!await needsIndexing()) {
      await syncDatabase();
      return;
    }

    final b = await box;
    final OnAudioQuery audioQuery = OnAudioQuery();
    final allSongs = await audioQuery.querySongs();

    await b.clear();
    for (final song in allSongs) {
      final folderPath = _getFolderPath(song.data);
      await b.put(song.data, {'folder_path': folderPath});
    }
    _isIndexed = true;
  }

  /// Fuerza la reindexación (útil para cuando se agregan/eliminan canciones)
  Future<void> forceReindex() async {
    _isIndexed = false;
    await indexAllSongs();
  }

  Future<List<String>> getFolders() async {
    final b = await box;
    final folderSet = <String>{};
    for (final value in b.values) {
      folderSet.add(value['folder_path'] as String);
    }
    final folders = folderSet.toList();
    folders.sort();
    return folders;
  }

  Future<List<String>> getSongsFromFolder(String folderPath) async {
    final b = await box;
    final result = <String>[];
    for (final entry in b.toMap().entries) {
      if (entry.value['folder_path'] == folderPath) {
        result.add(entry.key as String);
      }
    }
    result.sort();
    return result;
  }

  /// Actualiza la ruta de una canción en la base de datos
  Future<void> updateSongPath(String oldPath, String newPath) async {
    final b = await box;
    final oldData = b.get(oldPath);
    if (oldData != null) {
      // Crear nueva entrada con la nueva ruta
      final newFolderPath = _getFolderPath(newPath);
      await b.put(newPath, {'folder_path': newFolderPath});
      
      // Eliminar la entrada antigua
      await b.delete(oldPath);
    }
  }

  /// Actualiza todas las rutas de canciones de una carpeta
  Future<void> updateFolderPaths(String oldFolderPath, String newFolderPath) async {
    final b = await box;
    final songsToUpdate = <String, Map>{};
    
    // Encontrar todas las canciones de la carpeta antigua
    for (final entry in b.toMap().entries) {
      if (entry.value['folder_path'] == oldFolderPath) {
        final oldSongPath = entry.key as String;
        songsToUpdate[oldSongPath] = entry.value;
      }
    }
    
    // Actualizar las rutas
    for (final entry in songsToUpdate.entries) {
      final oldPath = entry.key;
      final newPath = p.join(newFolderPath, p.basename(oldPath));
      final newFolderPathNormalized = _getFolderPath(newPath);
      
      // Agregar nueva entrada
      await b.put(newPath, {'folder_path': newFolderPathNormalized});
      
      // Eliminar entrada antigua
      await b.delete(oldPath);
    }
  }
}