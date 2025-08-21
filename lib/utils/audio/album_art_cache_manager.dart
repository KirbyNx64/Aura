import 'dart:typed_data';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Cache Manager optimizado para carátulas de álbumes
///
/// Características:
/// - Cache en memoria con límite configurable
/// - Cache en disco para persistencia
/// - Expiración automática de entradas
/// - Precarga inteligente
/// - Gestión de memoria optimizada
/// - Concurrencia segura
class AlbumArtCacheManager {
  static final AlbumArtCacheManager _instance =
      AlbumArtCacheManager._internal();
  factory AlbumArtCacheManager() => _instance;
  AlbumArtCacheManager._internal();

  // Cache en memoria
  final Map<String, Uint8List> _memoryCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  final Map<String, Completer<Uint8List?>> _loadingCompleters = {};

  // Configuración
  static const int _maxMemoryCacheSize = 200;
  static const Duration _cacheExpiry = Duration(hours: 24);
  static const int _maxConcurrentLoads = 20;

  // Control de concurrencia
  int _activeLoads = 0;
  final List<Completer<void>> _waitingLoads = [];

  /// Obtiene la carátula del álbum con cache optimizado
  Future<Uint8List?> getAlbumArt(
    int songId,
    String songPath, {
    int? size,
  }) async {
    final cacheKey = _generateCacheKey(songId, songPath, size);

    // 1. Verificar cache en memoria
    final memoryResult = _getFromMemoryCache(cacheKey);
    if (memoryResult != null) {
      return memoryResult;
    }

    // 2. Verificar si ya se está cargando
    if (_loadingCompleters.containsKey(cacheKey)) {
      return await _loadingCompleters[cacheKey]!.future;
    }

    // 3. Control de concurrencia
    await _waitForSlot();

    // 4. Crear completer para esta carga
    final completer = Completer<Uint8List?>();
    _loadingCompleters[cacheKey] = completer;
    _activeLoads++;

    try {
      // 5. Cargar desde disco o generar
      final bytes = await _loadAlbumArtBytes(songId, songPath, size);

      // 6. Guardar en cache si es válido
      if (bytes != null) {
        _addToMemoryCache(cacheKey, bytes);
        await _saveToDiskCache(cacheKey, bytes);
      }

      completer.complete(bytes);
      return bytes;
    } catch (e) {
      completer.complete(null);
      return null;
    } finally {
      _loadingCompleters.remove(cacheKey);
      _activeLoads--;
      _processWaitingLoads();
    }
  }

  /// Precarga carátulas para una lista de canciones
  Future<void> preloadAlbumArts(
    List<Map<String, dynamic>> songs, {
    int maxConcurrent = 3,
  }) async {
    final songsToLoad = songs
        .where((song) {
          final songId = song['id'] as int;
          final songPath = song['data'] as String;
          final cacheKey = _generateCacheKey(songId, songPath, null);
          return !_memoryCache.containsKey(cacheKey) &&
              !_loadingCompleters.containsKey(cacheKey);
        })
        .take(20)
        .toList(); // Limitar a 20 canciones

    if (songsToLoad.isEmpty) return;

    // Cargar en paralelo con límite de concurrencia
    final semaphore = Completer<void>();
    int active = 0;

    for (final song in songsToLoad) {
      while (active >= maxConcurrent) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      active++;
      unawaited(() async {
        try {
          final songId = song['id'] as int;
          final songPath = song['data'] as String;
          await getAlbumArt(songId, songPath);
        } finally {
          active--;
          if (active == 0) {
            semaphore.complete();
          }
        }
      }());
    }

    await semaphore.future;
  }

  /// Limpia el cache expirado
  void _cleanupExpiredCache() {
    final now = DateTime.now();
    final expiredKeys = <String>[];

    for (final entry in _cacheTimestamps.entries) {
      if (now.difference(entry.value) > _cacheExpiry) {
        expiredKeys.add(entry.key);
      }
    }

    for (final key in expiredKeys) {
      _memoryCache.remove(key);
      _cacheTimestamps.remove(key);
    }
  }

  /// Obtiene desde cache en memoria
  Uint8List? _getFromMemoryCache(String key) {
    _cleanupExpiredCache();

    if (_memoryCache.containsKey(key)) {
      final timestamp = _cacheTimestamps[key];
      if (timestamp != null &&
          DateTime.now().difference(timestamp) < _cacheExpiry) {
        return _memoryCache[key];
      } else {
        // Remover entrada expirada
        _memoryCache.remove(key);
        _cacheTimestamps.remove(key);
      }
    }
    return null;
  }

  /// Agrega al cache en memoria
  void _addToMemoryCache(String key, Uint8List bytes) {
    // Limpiar cache si está lleno
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      _evictOldestEntry();
    }

    _memoryCache[key] = bytes;
    _cacheTimestamps[key] = DateTime.now();
  }

  /// Elimina la entrada más antigua del cache
  void _evictOldestEntry() {
    if (_cacheTimestamps.isEmpty) return;

    final oldestKey = _cacheTimestamps.entries
        .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
        .key;

    _memoryCache.remove(oldestKey);
    _cacheTimestamps.remove(oldestKey);
  }

  /// Genera clave única para el cache
  String _generateCacheKey(int songId, String songPath, int? size) {
    final sizeStr = size?.toString() ?? 'default';
    return '$songId-$songPath-$sizeStr';
  }

  /// Carga bytes de carátula desde OnAudioQuery
  Future<Uint8List?> _loadAlbumArtBytes(
    int songId,
    String songPath,
    int? size,
  ) async {
    try {
      // Obtener tamaño desde preferencias
      int artworkSize = size ?? 410;
      if (size == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          artworkSize = prefs.getInt('artwork_quality') ?? 410;
        } catch (_) {}
      }

      final albumArt = await OnAudioQuery().queryArtwork(
        songId,
        ArtworkType.AUDIO,
        size: artworkSize,
      );

      return albumArt;
    } catch (e) {
      return null;
    }
  }

  /// Guarda en cache de disco
  Future<void> _saveToDiskCache(String key, Uint8List bytes) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final cacheFile = File('${cacheDir.path}/artwork_cache_$key.dat');
      await cacheFile.writeAsBytes(bytes);
    } catch (e) {
      // Error silencioso
    }
  }

  /// Control de concurrencia - espera por un slot disponible
  Future<void> _waitForSlot() async {
    if (_activeLoads < _maxConcurrentLoads) return;

    final completer = Completer<void>();
    _waitingLoads.add(completer);
    await completer.future;
  }

  /// Procesa cargas en espera
  void _processWaitingLoads() {
    while (_waitingLoads.isNotEmpty && _activeLoads < _maxConcurrentLoads) {
      final completer = _waitingLoads.removeAt(0);
      completer.complete();
    }
  }

  /// Obtiene estadísticas del cache
  Map<String, dynamic> getCacheStats() {
    return {
      'memoryCacheSize': _memoryCache.length,
      'maxMemoryCacheSize': _maxMemoryCacheSize,
      'activeLoads': _activeLoads,
      'waitingLoads': _waitingLoads.length,
      'loadingCompleters': _loadingCompleters.length,
    };
  }

  /// Limpia todo el cache
  void clearCache() {
    _memoryCache.clear();
    _cacheTimestamps.clear();
    _loadingCompleters.clear();
    _activeLoads = 0;
    _waitingLoads.clear();
  }

  /// Limpia cache de disco
  Future<void> clearDiskCache() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final files = cacheDir.listSync();

      for (final file in files) {
        if (file is File && file.path.contains('artwork_cache_')) {
          await file.delete();
        }
      }
    } catch (e) {
      // Error silencioso
    }
  }

  /// Obtiene el tamaño del cache en memoria
  int get memoryCacheSize => _memoryCache.length;

  /// Verifica si una carátula está en cache
  bool isCached(int songId, String songPath, {int? size}) {
    final cacheKey = _generateCacheKey(songId, songPath, size);
    return _memoryCache.containsKey(cacheKey);
  }

  /// Elimina una entrada específica del cache
  void removeFromCache(int songId, String songPath, {int? size}) {
    final cacheKey = _generateCacheKey(songId, songPath, size);
    _memoryCache.remove(cacheKey);
    _cacheTimestamps.remove(cacheKey);
    _loadingCompleters.remove(cacheKey);
  }
}
