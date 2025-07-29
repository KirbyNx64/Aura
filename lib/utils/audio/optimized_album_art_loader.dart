import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'album_art_cache_manager.dart';

/// Token de cancelación para cargas de carátulas
class CancellationToken {
  bool _isCancelled = false;
  final List<Completer<void>> _waiters = [];

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (!_isCancelled) {
      _isCancelled = true;
      for (final waiter in _waiters) {
        waiter.complete();
      }
      _waiters.clear();
    }
  }

  Future<void> waitForCancellation() async {
    if (_isCancelled) return;
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  void dispose() {
    cancel();
  }
}

/// Cargador optimizado de carátulas con cancelación
class OptimizedAlbumArtLoader {
  static final OptimizedAlbumArtLoader _instance = OptimizedAlbumArtLoader._internal();
  factory OptimizedAlbumArtLoader() => _instance;
  OptimizedAlbumArtLoader._internal();

  final Map<String, CancellationToken> _loadingTokens = {};
  final AlbumArtCacheManager _cacheManager = AlbumArtCacheManager();
  
  // Configuración
  static const int _maxConcurrentLoads = 3;
  static const Duration _loadTimeout = Duration(seconds: 10);
  
  // Control de concurrencia
  int _activeLoads = 0;
  final List<Completer<void>> _waitingLoads = [];

  /// Carga carátula con cancelación y optimizaciones
  Future<Uint8List?> loadAlbumArt(
    int songId, 
    String songPath, {
    double? size,
    CancellationToken? token,
  }) async {
    // Cancelar carga anterior si existe
    _loadingTokens[songId.toString()]?.cancel();
    
    final newToken = CancellationToken();
    _loadingTokens[songId.toString()] = newToken;
    
    try {
      // Verificar cancelación inicial
      if (token?.isCancelled == true || newToken.isCancelled) return null;
      
      // Control de concurrencia
      await _waitForSlot();
      _activeLoads++;
      
      // Verificar cancelación después de esperar
      if (token?.isCancelled == true || newToken.isCancelled) return null;
      
      // Usar cache primero
      final cachedBytes = await _cacheManager.getAlbumArt(songId, songPath);
      if (cachedBytes != null) {
        if (size != null) {
          return await _resizeImageBytes(cachedBytes, size);
        }
        return cachedBytes;
      }
      
      if (token?.isCancelled == true || newToken.isCancelled) return null;
      
      // Cargar desde OnAudioQuery con timeout
      final bytes = await _loadFromOnAudioQuery(songId, songPath, token ?? newToken);
      if (bytes != null) {
        if (size != null) {
          return await _resizeImageBytes(bytes, size);
        }
        return bytes;
      }
      
      return null;
    } catch (e) {
      // Error silencioso
      return null;
    } finally {
      _loadingTokens.remove(songId.toString());
      _activeLoads--;
      _processWaitingLoads();
    }
  }

  /// Carga múltiples carátulas con cancelación
  Future<List<Uint8List?>> loadMultipleAlbumArts(
    List<Map<String, dynamic>> songs, {
    double? size,
    CancellationToken? token,
  }) async {
    final results = <Uint8List?>[];
    final futures = <Future<Uint8List?>>[];
    
    for (final song in songs) {
      if (token?.isCancelled == true) break;
      
      final songId = song['id'] as int;
      final songPath = song['data'] as String;
      
      futures.add(loadAlbumArt(songId, songPath, size: size, token: token));
    }
    
    // Esperar todas las cargas con cancelación
    for (final future in futures) {
      if (token?.isCancelled == true) break;
      try {
        final result = await future;
        results.add(result);
      } catch (e) {
        results.add(null);
      }
    }
    
    return results;
  }

  /// Carga desde OnAudioQuery con timeout y cancelación
  Future<Uint8List?> _loadFromOnAudioQuery(
    int songId, 
    String songPath, 
    CancellationToken token,
  ) async {
    try {
      // Obtener tamaño desde preferencias
      int artworkSize = 410;
      try {
        final prefs = await SharedPreferences.getInstance();
        artworkSize = prefs.getInt('artwork_quality') ?? 410;
      } catch (_) {}
      
      // Cargar con timeout
      final bytes = await OnAudioQuery()
          .queryArtwork(songId, ArtworkType.AUDIO, size: artworkSize)
          .timeout(_loadTimeout)
          .catchError((_) => null);
      
      // Verificar cancelación antes de retornar
      if (token.isCancelled) return null;
      
      return bytes;
    } catch (e) {
      return null;
    }
  }

  /// Redimensiona bytes de imagen optimizado
  Future<Uint8List> _resizeImageBytes(Uint8List bytes, double size) async {
    try {
      // Crear codec de imagen
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: size.toInt(),
        targetHeight: size.toInt(),
      );
      
      // Obtener frame
      final frame = await codec.getNextFrame();
      
      // Convertir a bytes
      final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      
      return byteData!.buffer.asUint8List();
    } catch (e) {
      // Si falla el redimensionamiento, retornar bytes originales
      return bytes;
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

  /// Cancela todas las cargas activas
  void cancelAllLoads() {
    for (final token in _loadingTokens.values) {
      token.cancel();
    }
    _loadingTokens.clear();
  }

  /// Cancela carga específica
  void cancelLoad(int songId) {
    _loadingTokens[songId.toString()]?.cancel();
    _loadingTokens.remove(songId.toString());
  }

  /// Obtiene estadísticas del cargador
  Map<String, dynamic> getLoaderStats() {
    return {
      'activeLoads': _activeLoads,
      'waitingLoads': _waitingLoads.length,
      'loadingTokens': _loadingTokens.length,
      'maxConcurrentLoads': _maxConcurrentLoads,
    };
  }

  /// Limpia recursos
  void dispose() {
    cancelAllLoads();
    _waitingLoads.clear();
    _activeLoads = 0;
  }

  /// Verifica si hay cargas activas
  bool get hasActiveLoads => _activeLoads > 0;

  /// Obtiene el número de cargas activas
  int get activeLoadsCount => _activeLoads;
}

/// Helper para crear tokens de cancelación
class CancellationTokenSource {
  final CancellationToken _token = CancellationToken();

  CancellationToken get token => _token;

  void cancel() => _token.cancel();

  void dispose() => _token.dispose();
} 