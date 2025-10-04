import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'album_art_cache_manager.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

AudioHandler? _audioHandler;

/// Verifica si el AudioService está funcionando correctamente
Future<bool> isAudioServiceHealthy() async {
  try {
    if (_audioHandler == null) return false;
    
    // Verificar que el handler responda a una operación básica
    _audioHandler!.playbackState.value;
    return true; // Si llegamos aquí sin excepción, está saludable
  } catch (e) {
    return false;
  }
}

/// Obtiene el AudioHandler de forma segura, reinicializando si es necesario
Future<AudioHandler> getAudioHandlerSafely() async {
  // Verificar si la instancia actual está saludable
  if (_audioHandler != null && await isAudioServiceHealthy()) {
    return _audioHandler!;
  }
  
  // Si no está saludable o no existe, reinicializar
  if (_audioHandler != null) {
    await reinitializeAudioHandler();
  }
  
  // Si aún no hay instancia, crear una nueva
  if (_audioHandler == null) {
    return await initAudioService();
  }
  
  return _audioHandler!;
}

Future<AudioHandler> initAudioService() async {
  if (_audioHandler != null) {
    return _audioHandler!;
  }

  // Intentar inicializar con reintentos
  for (int attempt = 1; attempt <= 3; attempt++) {
    try {
      _audioHandler = await AudioService.init(
        builder: () => MyAudioHandler(),
        config: AudioServiceConfig(
          androidNotificationIcon: 'mipmap/ic_stat_music_note',
          androidNotificationChannelId: 'com.aura.music.channel',
          androidNotificationChannelName: 'Aura Music',
          androidNotificationChannelDescription: 'Controles de reproducción de música',
          androidNotificationOngoing: true,
          androidNotificationClickStartsActivity: true,
          androidStopForegroundOnPause: false,
          androidResumeOnClick: true,
          preloadArtwork: true,
        ),
      );

      return _audioHandler!;
    } catch (e) {
      _audioHandler = null;
      
      if (attempt == 3) {
        // En el último intento, lanzar la excepción
        throw Exception('Error al inicializar AudioService después de 3 intentos: $e');
      }
      
      // Esperar antes del siguiente intento (backoff exponencial)
      final delayMs = 500 * (1 << (attempt - 1));
      await Future.delayed(Duration(milliseconds: delayMs));
    }
  }
  
  // Este punto nunca debería alcanzarse, pero por seguridad
  throw Exception('Error inesperado al inicializar AudioService');
}

/// Función para reinicializar completamente el AudioHandler
Future<void> reinitializeAudioHandler() async {
  try {
    // Si hay una instancia activa, intentar detenerla primero
    if (_audioHandler != null) {
      try {
        await _audioHandler!.stop();
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        // Error al detener, continuar con la limpieza
      }
    }
    
    // Limpiar la instancia global
    _audioHandler = null;

    // Pequeña pausa para asegurar limpieza completa
    await Future.delayed(const Duration(milliseconds: 200));

    // Reinicializar
    await initAudioService();
  } catch (e) {
    // Error silencioso - el servicio puede seguir funcionando con la instancia anterior
  }
}

// Cache Manager optimizado para carátulas
final AlbumArtCacheManager _albumArtCacheManager = AlbumArtCacheManager();

// OptimizedAlbumArtLoader obsoleto - ahora se usa AlbumArtCacheManager directamente

// Cache global para URIs de carátulas (compatibilidad) - DEPRECATED
// Se mantiene solo para compatibilidad, usar AlbumArtCacheManager
const int _artworkCacheMaxEntries = 300;
final LinkedHashMap<String, Uri?> _artworkCache = LinkedHashMap();
final Map<String, Future<Uri?>> _preloadCache = {};
String? _tempDirPath;

Map<String, Uri?> get artworkCache => _artworkCache;

Future<Uri?> getOrCacheArtwork(int songId, String songPath) async {
  try {
    // 1. Verificar cache en memoria primero (más rápido)
    if (_artworkCache.containsKey(songPath)) {
      final cached = _artworkCache[songPath];
      if (cached != null) {
        // Verificar que el archivo aún existe
        final file = File(cached.toFilePath());
        if (await file.exists() && await file.length() > 0) {
          return cached;
        } else {
          // Archivo eliminado o corrupto, remover del caché
          _artworkCache.remove(songPath);
        }
      }
    }

    // 2. Verificar si ya se está cargando
    if (_preloadCache.containsKey(songPath)) {
      return await _preloadCache[songPath]!;
    }

    // 3. Crear Future y almacenarlo para evitar duplicados
    final future = _loadArtworkWithCache(songId, songPath);
    _preloadCache[songPath] = future;

    try {
      final result = await future;
      return result;
    } finally {
      _preloadCache.remove(songPath);
    }
  } catch (e) {
    // print('❌ Error cargando carátula para $songId: $e');
    return null;
  }
}

Future<Uri?> _loadArtworkWithCache(int songId, String songPath) async {
  // Usar AlbumArtCacheManager para obtener bytes de carátula
  final artworkBytes = await _albumArtCacheManager.getAlbumArt(songId, songPath);
  
  if (artworkBytes == null) {
    return null;
  }
  
  // Convertir bytes a archivo temporal y retornar URI
  final tempDir = await getTemporaryDirectory();
  final artworkFile = File('${tempDir.path}/artwork_$songId.jpg');
  
  // Solo escribir si el archivo no existe o está corrupto
  if (!await artworkFile.exists() || await artworkFile.length() == 0) {
    await artworkFile.writeAsBytes(artworkBytes);
  }
  
  final uri = Uri.file(artworkFile.path);
  
  // Mantener compatibilidad con el cache anterior
  _artworkCache[songPath] = uri;
  
  // Limitar tamaño del caché (LRU)
  if (_artworkCache.length > _artworkCacheMaxEntries) {
    final firstKey = _artworkCache.keys.first;
    _artworkCache.remove(firstKey);
  }
  
  return uri;
}

// Función obsoleta eliminada - ahora se usa AlbumArtCacheManager directamente

/// Precarga carátulas para una lista de canciones de forma asíncrona
Future<void> preloadArtworks(
  List<SongModel> songs, {
  int maxConcurrent = 3,
}) async {
  // Usar AlbumArtCacheManager para precarga optimizada
  final songsData = songs
      .take(20) // Limitar a 20 canciones para no sobrecargar
      .map((song) => {'id': song.id, 'data': song.data})
      .toList();

  // Usar el sistema de precarga del AlbumArtCacheManager
  await _albumArtCacheManager.preloadAlbumArts(songsData, maxConcurrent: maxConcurrent);
}

// TESTING
/// Precarga todas las carátulas de la lista actual en la carpeta temporal de caché
Future<void> preloadAllArtworksToCache(List<SongModel> songs) async {
  try {
    if (songs.isEmpty) {
      // print('📋 No hay lista de canciones para precargar carátulas');
      return;
    }

    // print('🚀 Iniciando precarga de ${songs.length} carátulas en caché...');
    
    // Obtener directorio temporal
    final tempDir = await getTemporaryDirectory();
    final cacheDir = Directory('${tempDir.path}/artworks');
    
    // Crear directorio si no existe
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    int loadedCount = 0;
    // int skippedCount = 0;

    // Precargar todas las carátulas de la lista
    for (final song in songs) {
      try {
        final artworkFile = File('${cacheDir.path}/artwork_${song.id}.jpg');
        
        // Verificar si ya existe en caché
        if (await artworkFile.exists()) {
          // skippedCount++;
          continue;
        }

        // Cargar la carátula
        final bytes = await _albumArtCacheManager.getAlbumArt(song.id, song.data);
        
        if (bytes != null) {
          // Guardar en caché temporal
          await artworkFile.writeAsBytes(bytes);
          loadedCount++;
          
          // Actualizar caché en memoria
          _artworkCache[song.data] = Uri.file(artworkFile.path);
          
          if (loadedCount % 5 == 0) {
            // print('📸 Precargadas $loadedCount/${songs.length} carátulas...');
          }
        }
        
        // Pequeña pausa para no sobrecargar
        await Future.delayed(const Duration(milliseconds: 50));
        
      } catch (e) {
        // print('❌ Error precargando carátula ${song.id}: $e');
      }
    }

    // print('✅ Precarga completada: $loadedCount nuevas, $skippedCount ya existían');
    
  } catch (e) {
    // print('❌ Error en precarga masiva de carátulas: $e');
  }
}

// TESTING

/// Obtiene el tamaño actual del cache de carátulas
int get artworkCacheSize =>
    _artworkCache.length + _albumArtCacheManager.memoryCacheSize;

/// Limpia el cache de carátulas para liberar memoria
void clearArtworkCache() {
  _artworkCache.clear();
  _preloadCache.clear();
  _albumArtCacheManager.clearCache();
}

/// Limpia carátulas específicas del cache
void removeArtworkFromCache(String songPath) {
  _artworkCache.remove(songPath);
  _preloadCache.remove(songPath);
  // Nota: Para remover del cache optimizado necesitaríamos songId
}

/// Obtiene estadísticas del cache optimizado
Map<String, dynamic> getOptimizedCacheStats() {
  return _albumArtCacheManager.getCacheStats();
}

/// Cancela todas las cargas de carátulas activas
void cancelAllArtworkLoads() {
  // El AlbumArtCacheManager maneja la cancelación automáticamente
  // No necesita cancelación manual
}

/// Cancela carga específica de carátula
void cancelArtworkLoad(int songId) {
  // El AlbumArtCacheManager maneja la cancelación automáticamente
  // No necesita cancelación manual
}

/// Obtiene estadísticas del cargador optimizado
Map<String, dynamic> getOptimizedLoaderStats() {
  return _albumArtCacheManager.getCacheStats();
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  AudioPlayer _player = AudioPlayer();
  AndroidLoudnessEnhancer? _loudnessEnhancer; // Para volume boost
  final List<MediaItem> _mediaQueue = [];
  List<SongModel>? _originalSongList; // Guarda la lista original de SongModel
  List<SongModel> _currentSongList = [];
  final ValueNotifier<bool> isShuffleNotifier = ValueNotifier(false);
  // NOTE: ConcatenatingAudioSource está marcado como deprecated, pero es la única
  // manera estable de anexar elementos sin re-preparar toda la lista y sin cortes.
  // Usamos un ignore a nivel puntual.
  // ignore: deprecated_member_use
  ConcatenatingAudioSource? _concat;
  final ValueNotifier<bool> isQueueTransitioning = ValueNotifier(false);
  final ValueNotifier<bool> initializingNotifier = ValueNotifier(false);
  DateTime _lastShuffleToggle = DateTime.fromMillisecondsSinceEpoch(0);
  bool _initializing = true;
  Timer? _sleepTimer;
  Duration? _sleepDuration;
  Duration? _sleepStartPosition;
  bool _isSkipping = false;
  bool _isInitialized = false;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  // Control de operaciones pendientes para evitar sobrecarga
  String? _lastProcessedSongId;
  final Map<String, bool> _pendingArtworkOperations = {};

  // Control de notificaciones del sistema
  Timer? _notificationUpdateTimer;

  // Persistencia
  SharedPreferences? _prefs;
  bool _restoredSession = false;
  DateTime _lastPositionPersist = DateTime.fromMillisecondsSinceEpoch(0);

  // Variables para tracking de tiempo de escucha en segundo plano
  String? _currentTrackingId;
  DateTime? _trackingStartTime;
  Timer? _trackingTimer;
  bool _hasBeenTracked = false;
  Duration _elapsedTrackingTime = Duration.zero;

  // Control de pausa automática durante cambios de canción
  Timer? _songChangeResumeTimer;
  bool _wasPlayingBeforeChange = false;
  static const Duration _songChangeDelay = Duration(milliseconds: 800);

  // Claves de SharedPreferences
  static const String _kPrefQueuePaths = 'playback_queue_paths';
  static const String _kPrefQueueIndex = 'playback_queue_index';
  static const String _kPrefSongPositionSec = 'playback_song_position_sec';
  static const String _kPrefRepeatMode =
      'playback_repeat_mode'; // 0 none, 1 one, 2 all
  static const String _kPrefShuffleEnabled = 'playback_shuffle_enabled';
  static const String _kPrefWasPlaying = 'playback_was_playing';

  MyAudioHandler() {
    _initializePlayerWithEnhancer();
    _init();
  }

  // Inicializar el AudioPlayer con LoudnessEnhancer desde el principio
  void _initializePlayerWithEnhancer() {
    try {
      // print('🔊 Inicializando AudioPlayer con AndroidLoudnessEnhancer...');
      
      // Crear el LoudnessEnhancer
      _loudnessEnhancer = AndroidLoudnessEnhancer();
      _loudnessEnhancer!.setTargetGain(0.0); // Inicialmente sin boost
      _loudnessEnhancer!.setEnabled(true);
      
      // Crear el AudioPipeline con el enhancer
      final pipeline = AudioPipeline(androidAudioEffects: [_loudnessEnhancer!]);
      
      // Crear AudioPlayer con el pipeline
      _player = AudioPlayer(audioPipeline: pipeline);
      
      // print('🔊 AudioPlayer inicializado con AndroidLoudnessEnhancer exitosamente');
    } catch (e) {
      // print('⚠️ Error inicializando con LoudnessEnhancer, usando player normal: $e');
      // Fallback: crear player normal
      _player = AudioPlayer();
      _loudnessEnhancer = null;
    }
  }

  // Finalizar el AudioPlayer con AndroidLoudnessEnhancer

  int _initRetryCount = 0;
  static const int _initMaxRetries = 5;

  Future<void> _init() async {
    if (_isInitialized) return;

    try {
      _prefs ??= await SharedPreferences.getInstance();
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Cargar preferencias de volume boost
      await _loadVolumeBoostPreference();

      // Cancelar suscripciones anteriores si existen
      await _disposeListeners();

      _playbackEventSubscription = _player.playbackEventStream.listen((event) {
        // Transformar el evento de just_audio a audio_service siguiendo la documentación
        final transformedState = _transformPlaybackEvent(event);
        playbackState.add(transformedState);

        // Si se completó y está en loop one, lanza el seek/play en segundo plano
        if (event.processingState == ProcessingState.completed &&
            _player.loopMode == LoopMode.one) {
          unawaited(_player.seek(Duration.zero));
          unawaited(_player.play());
        }
        
        // Precarga inteligente: cuando quedan pocos segundos, precargar la siguiente
        _preloadNextSongArtwork();
        
        // Si se completó y es la última canción de la lista, pausar automáticamente
        if (event.processingState == ProcessingState.completed) {
          final currentIndex = _player.currentIndex;
          // print('🔍 DEBUG: Canción completada - Index: $currentIndex, Queue length: ${_mediaQueue.length}, Loop mode: ${_player.loopMode}');
          
          if (currentIndex != null && 
              currentIndex >= 0 && 
              currentIndex >= _mediaQueue.length - 1 &&
              _player.loopMode != LoopMode.all &&
              _mediaQueue.isNotEmpty) {
            // Debug: verificar que estamos en la última canción
            // print('❤️ DEBUG: Última canción completada - Index: $currentIndex, Queue length: ${_mediaQueue.length}, Loop mode: ${_player.loopMode}');
            
            // Es la última canción y no está en modo repeat all, pausar
            // Agregar un pequeño delay para asegurar que el estado se procese correctamente
            Timer(const Duration(milliseconds: 100), () {
              if (mounted && _player.playing) {
                // print('❤️ DEBUG: Pausando automáticamente la última canción');
                unawaited(pause());
              }
            });
          } else {
            // print('❌ DEBUG: No se cumplen las condiciones para pausar - Index válido: ${currentIndex != null}, Índice >= 0: ${currentIndex != null && currentIndex >= 0}, Es último: ${currentIndex != null && currentIndex >= _mediaQueue.length - 1}, No es loop all: ${_player.loopMode != LoopMode.all}, Queue no vacía: ${_mediaQueue.isNotEmpty}');
          }
        }
        
        // Verificar también cuando el estado cambia a completed y el player se detiene automáticamente
        if (event.processingState == ProcessingState.completed && 
            !_player.playing &&
            _player.loopMode == LoopMode.off) {
          final currentIndex = _player.currentIndex;
          if (currentIndex != null && 
              currentIndex >= _mediaQueue.length - 1) {
            // print('DEBUG: Player se detuvo automáticamente al final de la lista');
            // El player ya se pausó automáticamente, solo actualizar el estado
            playbackState.add(playbackState.value.copyWith(playing: false));
          }
        }
      });

      _currentIndexSubscription = _player.currentIndexStream.listen((index) {
        if (_initializing) return;
        if (index != null && index < _mediaQueue.length) {
          // Precargar carátula inmediatamente para transiciones automáticas
          _preloadArtworkForIndex(index);
          _updateCurrentMediaItem(index);
        }
      });

      _durationSubscription = _player.durationStream.listen((duration) {
        final index = _player.currentIndex;
        final newQueue = queue.value;
        if (index == null || newQueue.isEmpty) return;
        
        final oldMediaItem = newQueue[index];
        if (duration != null && oldMediaItem.duration != duration) {
          // Actualizar MediaItem con duración siguiendo el patrón de la documentación
          final newMediaItem = oldMediaItem.copyWith(duration: duration);
          newQueue[index] = newMediaItem;
          _mediaQueue[index] = newMediaItem;
          
          // Actualizar queue y mediaItem
          queue.add(newQueue);
          mediaItem.add(newMediaItem);
        }
      });

      _playingSubscription = _player.playingStream.listen((playing) {
        // No actualizar playbackState aquí - se maneja en playbackEventStream
        
        if (playing) {
          // Reanudar timer de tracking si hay una canción actual y no ha sido guardada
          if (_currentTrackingId != null && !_hasBeenTracked) {
            _trackingStartTime = DateTime.now();
            final currentItem = mediaItem.value;
            final songPath = currentItem?.extras?['data'] as String?;
            if (songPath != null) {
              _startTrackingPlaytime(_currentTrackingId!, songPath);
            }
          }
        } else {
          // Pausar timer cuando se pausa la reproducción (acumula tiempo transcurrido)
          _cancelTrackingTimer();
        }
        // Guardar estado de reproducción actual
        unawaited(() async {
          try {
            await _prefs?.setBool(_kPrefWasPlaying, playing);
          } catch (_) {}
        }());
      });

      _processingStateSubscription = _player.processingStateStream.listen((
        state,
      ) {
        // No actualizar playbackState aquí - se maneja en playbackEventStream
        // Solo mantener para debug si es necesario
        // print('⚙️ DEBUG: ProcessingState - State: $state, Index: ${_player.currentIndex}');
      });

      // Suscripción para persistir la posición cada ~2s
      _positionSubscription = _player.positionStream.listen((pos) {
        final now = DateTime.now();
        if (now.difference(_lastPositionPersist).inMilliseconds >= 2000) {
          _lastPositionPersist = now;
          unawaited(() async {
            try {
              await _prefs?.setInt(_kPrefSongPositionSec, pos.inSeconds);
            } catch (_) {}
          }());
        }
      });

      _isInitialized = true;
      _initRetryCount = 0;
      // Intentar restaurar sesión previa si no hay cola actual
      if (!_restoredSession && _mediaQueue.isEmpty) {
        unawaited(_attemptRestoreFromPrefs());
      }
    } catch (e) {
      // Si hay error en la inicialización, intentar reinicializar
      _isInitialized = false;
      if (_initRetryCount < _initMaxRetries) {
        _initRetryCount++;
        final delayMs = 100 * (1 << (_initRetryCount - 1));
        await Future.delayed(Duration(milliseconds: delayMs.clamp(100, 1600)));
        await _init();
      }
    }
  }

  /// Cancela todos los listeners para evitar duplicados
  Future<void> _disposeListeners() async {
    await _currentIndexSubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _playingSubscription?.cancel();
    await _processingStateSubscription?.cancel();
    await _positionSubscription?.cancel();

    // Cancelar timer de notificaciones
    _notificationUpdateTimer?.cancel();
    
    // Cancelar timer de cambio de canción
    _songChangeResumeTimer?.cancel();
    _songChangeResumeTimer = null;

    _currentIndexSubscription = null;
    _playbackEventSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _processingStateSubscription = null;
    _positionSubscription = null;

    // Resetear tracking completamente
    _resetTracking();
  }

  /// Función para actualizar más reproducidas desde el background
  Future<void> _updateMostPlayedAsync(String path) async {
    try {
      final query = OnAudioQuery();
      final allSongs = await query.querySongs();
      final match = allSongs.where((s) => s.data == path);
      if (match.isNotEmpty) {
        await MostPlayedDB().incrementPlayCount(match.first);
      } else {
        // Error de que la canción no se encontró en la base de datos
      }
    } catch (e) {
      // Error de que la canción no se encontró en la base de datos
    }
  }

  /// Función para guardar la canción después de 10 segundos
  void _startTrackingPlaytime(String trackId, String path) {
    _trackingTimer?.cancel();
    final remainingTime = const Duration(seconds: 10) - _elapsedTrackingTime;

    if (remainingTime <= Duration.zero) {
      // Ya pasó el tiempo, guardar inmediatamente
      if (_currentTrackingId == trackId && !_hasBeenTracked) {
        _hasBeenTracked = true;
        unawaited(RecentsDB().addRecentPath(path));
        unawaited(_updateMostPlayedAsync(path));
      }
    } else {
      _trackingTimer = Timer(remainingTime, () {
        if (_currentTrackingId == trackId && !_hasBeenTracked) {
          _hasBeenTracked = true;
          // Actualizar recientes de forma asíncrona
          unawaited(RecentsDB().addRecentPath(path));
          // Actualizar más reproducidas de forma asíncrona
          unawaited(_updateMostPlayedAsync(path));
        }
      });
    }
  }

  /// Función para cancelar el timer cuando se pausa o cambia la canción
  void _cancelTrackingTimer() {
    _trackingTimer?.cancel();
    // Solo acumular tiempo si no ha sido guardado aún
    if (_trackingStartTime != null && !_hasBeenTracked) {
      final timeToAdd = DateTime.now().difference(_trackingStartTime!);
      _elapsedTrackingTime += timeToAdd;
    }
    _trackingStartTime = null;
  }

  /// Función para resetear completamente el tracking (usado al cambiar de canción)
  void _resetTracking() {
    _trackingTimer?.cancel();
    _currentTrackingId = null;
    _trackingStartTime = null;
    _hasBeenTracked = false;
    _elapsedTrackingTime = Duration.zero;
  }

  /// Verifica si el handler está montado (para evitar actualizaciones después de dispose)
  bool get mounted => _isInitialized && !_initializing;

  /// Precarga la carátula de la siguiente canción cuando quedan pocos segundos
  void _preloadNextSongArtwork() {
    final duration = _player.duration;
    final position = _player.position;
    final currentIndex = _player.currentIndex;
    
    if (duration == null || currentIndex == null || _currentSongList.isEmpty) return;
    
    // Si quedan menos de 18 segundos, precargar la siguiente canción
    final remainingTime = duration - position;
    if (remainingTime.inSeconds <= 18 && remainingTime.inSeconds > 15) {
      final nextIndex = currentIndex + 1;
      if (nextIndex < _currentSongList.length) {
        final nextSong = _currentSongList[nextIndex];
        
        // Verificar si ya está en caché (memoria o archivo)
        bool isAlreadyCached = false;
        if (_artworkCache.containsKey(nextSong.data)) {
          isAlreadyCached = true;
        } else {
          // Verificar también en caché temporal (archivos) - hacer de forma asíncrona
          unawaited(() async {
            try {
              _tempDirPath ??= (await getTemporaryDirectory()).path;
              final cachedFile = File('$_tempDirPath/artwork_${nextSong.id}.jpg');
              if (await cachedFile.exists()) {
                // Agregar al caché en memoria para acceso inmediato
                _artworkCache[nextSong.data] = Uri.file(cachedFile.path);
              }
            } catch (e) {
              // Error silencioso
            }
          }());
        }
        
        // Solo precargar si no está ya en caché
        if (!isAlreadyCached) {
          unawaited(() async {
            try {
              final artUri = await getOrCacheArtwork(
                nextSong.id,
                nextSong.data,
              ).timeout(const Duration(milliseconds: 2000));
              
              // Verificar que el archivo existe antes de usar
              if (artUri != null) {
                final file = File(artUri.toFilePath());
                if (!await file.exists()) {
                  // Archivo no existe, remover del caché
                  _artworkCache.remove(nextSong.data);
                }
              }
            } catch (e) {
              // print('Error precargando carátula para ${nextSong.title}: $e');
            }
          }());
        }
      }
    }
  }

  /// Transform a just_audio event into an audio_service state.
  /// Sigue exactamente el patrón de la documentación oficial de audio_service
  PlaybackState _transformPlaybackEvent(PlaybackEvent event) {
    // Sincronizar el estado del shuffle con el notifier
    _syncShuffleState();
    
    // Determinar el modo de repetición basado en el loop mode del player
    AudioServiceRepeatMode repeatMode;
    switch (_player.loopMode) {
      case LoopMode.one:
        repeatMode = AudioServiceRepeatMode.one;
        break;
      case LoopMode.all:
        repeatMode = AudioServiceRepeatMode.all;
        break;
      case LoopMode.off:
        repeatMode = AudioServiceRepeatMode.none;
        break;
    }

    // Determinar el modo shuffle basado en el estado del player
    AudioServiceShuffleMode shuffleMode = _player.shuffleModeEnabled 
        ? AudioServiceShuffleMode.all 
        : AudioServiceShuffleMode.none;

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      repeatMode: repeatMode,
      shuffleMode: shuffleMode,
    );
  }

  /// Actualiza solo el MediaItem cuando cambia el índice siguiendo las mejores prácticas de audio_service
  void _updateCurrentMediaItem(int index) {
    if (index < 0 || index >= _mediaQueue.length) return;
    
    var currentMediaItem = _mediaQueue[index];
    final songPath = currentMediaItem.extras?['data'] as String?;
    final songId = currentMediaItem.extras?['songId'] as int?;
    final currentSongId = currentMediaItem.id;

    // print('🎵 Actualizando MediaItem - Índice: $index, Canción: ${currentMediaItem.title}');

    // Cancelar operaciones pendientes de canciones anteriores
    if (_lastProcessedSongId != null && _lastProcessedSongId != currentSongId) {
      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();
    }
    _lastProcessedSongId = currentSongId;

    // Persistir índice actual
    unawaited(() async {
      try {
        await _prefs?.setInt(_kPrefQueueIndex, index);
      } catch (_) {}
    }());

    // Tracking de tiempo de escucha
    if (currentMediaItem.id.isNotEmpty && currentMediaItem.id != _currentTrackingId) {
      _resetTracking();
      _currentTrackingId = currentMediaItem.id;
      _trackingStartTime = DateTime.now();

      if (songPath != null) {
        _startTrackingPlaytime(currentMediaItem.id, songPath);
      }
    }

    // Verificar si tenemos carátula inmediata en caché
    if (songPath != null && songId != null && _artworkCache.containsKey(songPath)) {
      final immediateArtUri = _artworkCache[songPath];
      if (immediateArtUri != null) {
        // print('⚡ Carátula encontrada en caché de memoria para: ${currentMediaItem.title}');
        
        // Verificar que el archivo existe de forma síncrona
        final file = File(immediateArtUri.toFilePath());
        if (file.existsSync()) {
          // print('✅ Archivo de carátula existe: ${file.path}');
          
          // Verificar que el archivo no esté vacío
          final fileSize = file.lengthSync();
          if (fileSize > 0) {
            // print('✅ Archivo de carátula válido (${fileSize} bytes)');
            
            // Asegurar que el URI esté correctamente formateado
            final validUri = Uri.file(file.path);
            final finalMediaItem = currentMediaItem.copyWith(artUri: validUri);
            _mediaQueue[index] = finalMediaItem;
            
            // print('📱 Enviando MediaItem con carátula inmediata - ArtUri: ${validUri.toString()}');
            // print('📱 MediaItem completo: ${finalMediaItem.toString()}');
            
            // Enviar la notificación inmediatamente
            mediaItem.add(finalMediaItem);
            
            // Verificar que se envió correctamente
            // print('✅ MediaItem enviado a notificación');
            
            // Re-enviar la notificación después de un pequeño delay para asegurar que se procese
            unawaited(() async {
              await Future.delayed(const Duration(milliseconds: 200));
              if (_lastProcessedSongId == currentSongId && mounted) {
                // print('🔄 Re-enviando MediaItem para asegurar carátula');
                mediaItem.add(finalMediaItem);
                
                // Segundo retry después de más tiempo
                await Future.delayed(const Duration(milliseconds: 500));
                if (_lastProcessedSongId == currentSongId && mounted) {
                  // print('🔄 Segundo retry para asegurar carátula');
                  mediaItem.add(finalMediaItem);
                }
              }
            }());
            
            return;
          } else {
            // print('❌ Archivo de carátula vacío (0 bytes), removiendo del caché');
            _artworkCache.remove(songPath);
          }
        } else {
          // print('❌ Archivo de carátula no existe, removiendo del caché');
          _artworkCache.remove(songPath);
        }
      }
    }
    
    // Verificar también en caché temporal (archivos) antes de cargar en background
    if (songPath != null && songId != null && !_artworkCache.containsKey(songPath)) {
      unawaited(() async {
        try {
          _tempDirPath ??= (await getTemporaryDirectory()).path;
          final cachedFile = File('$_tempDirPath/artwork_$songId.jpg');
          
          if (await cachedFile.exists()) {
            final fileSize = await cachedFile.length();
            if (fileSize > 0) {
              // Archivo válido encontrado, agregar al caché de memoria
              final validUri = Uri.file(cachedFile.path);
              _artworkCache[songPath] = validUri;
              
              // Actualizar MediaItem inmediatamente
              final finalMediaItem = currentMediaItem.copyWith(artUri: validUri);
              _mediaQueue[index] = finalMediaItem;
              mediaItem.add(finalMediaItem);
              
              // print('⚡ Carátula encontrada en caché temporal para: ${currentMediaItem.title}');
              return;
            }
          }
        } catch (e) {
          // Error silencioso
        }
      }());
    }

    // Si no hay carátula inmediata, enviar sin carátula y cargar en background
    // print('📱 Enviando MediaItem sin carátula - se cargará en background');
    mediaItem.add(currentMediaItem);
    
    // Cargar carátula en background
    unawaited(_updateCurrentMediaItemAsync(index));
  }

  /// Función asíncrona para cargar carátulas en background
  Future<void> _updateCurrentMediaItemAsync(int index) async {
    if (index < 0 || index >= _mediaQueue.length) return;
    
    var currentMediaItem = _mediaQueue[index];
    final songPath = currentMediaItem.extras?['data'] as String?;
    final songId = currentMediaItem.extras?['songId'] as int?;
    final currentSongId = currentMediaItem.id;

    // print('🔄 Cargando carátula en background para: ${currentMediaItem.title}');

    if (songPath != null && songId != null) {
      // Verificar si ya se está cargando
      if (_pendingArtworkOperations.containsKey(currentSongId)) {
        // print('⏳ Carátula ya se está cargando para: ${currentMediaItem.title}');
        return;
      }

      _pendingArtworkOperations[currentSongId] = true;
      
      try {
        // print('🔄 Iniciando carga de carátula en background');
        final artUri = await getOrCacheArtwork(songId, songPath)
            .timeout(const Duration(milliseconds: 2000));

        // Verificar que aún estamos en la misma canción
        if (_lastProcessedSongId == currentSongId &&
            mounted &&
            _player.currentIndex == index) {
          
          if (artUri != null) {
            // Asegurar que el URI esté correctamente formateado
            final validUri = Uri.file(artUri.toFilePath());
            final updatedMediaItem = _mediaQueue[index].copyWith(artUri: validUri);
            _mediaQueue[index] = updatedMediaItem;
            
            // print('✅ Carátula cargada en background: ${artUri.path}');
            // print('🔗 URI de carátula background formateado: $validUri');
            // print('📱 Actualizando notificación con carátula');
            
            // Actualizar notificación con la carátula
            mediaItem.add(updatedMediaItem);
          } else {
            // print('⚠️ No se pudo cargar carátula en background para: ${currentMediaItem.title}');
          }
        } else {
          // print('⚠️ Canción cambió, cancelando actualización de carátula');
        }
      } catch (e) {
        // print('❌ Error cargando carátula en background: $e');
      } finally {
        _pendingArtworkOperations.remove(currentSongId);
      }
    }
  }

  int _loadVersion = 0;

  /// Función mejorada para crear MediaItems iniciales siguiendo las mejores prácticas de audio_service
  Future<List<MediaItem>> _createMediaItemsWithArtwork(List<SongModel> songs, {int? priorityIndex}) async {
    final mediaItems = <MediaItem>[];
    
    // print('🎵 Creando ${songs.length} MediaItems con carátulas');
    
    // Crear MediaItems básicos primero para mantener el orden
    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;

      // Verificar si ya tenemos la carátula en caché antes de crear el MediaItem
      Uri? cachedArtUri;
      if (_artworkCache.containsKey(song.data)) {
        cachedArtUri = _artworkCache[song.data];
      }

      mediaItems.add(
        MediaItem(
          id: song.data,
          album: song.album ?? '',
          title: song.title,
          artist: song.artist ?? '',
          duration: dur,
          artUri: cachedArtUri, // Usar carátula del caché si está disponible
          extras: {
            'songId': song.id,
            'albumId': song.albumId,
            'data': song.data,
            'queueIndex': i,
          },
        ),
      );
    }
    
    // Determinar qué canciones cargar primero
    final Set<int> indicesToLoad = {};
    
    // Si hay un índice prioritario (canción actual), cargarlo primero
    if (priorityIndex != null && priorityIndex >= 0 && priorityIndex < songs.length) {
      indicesToLoad.add(priorityIndex);
    }
    
    // Agregar las primeras 3 canciones si no están ya incluidas
    for (int i = 0; i < 3 && i < songs.length; i++) {
      indicesToLoad.add(i);
    }
    
    // Cargar carátulas para las canciones prioritarias de forma síncrona
    if (indicesToLoad.isNotEmpty) {
      // print('🔄 Cargando carátulas para canciones prioritarias: ${indicesToLoad.toList()}');
      
      for (final i in indicesToLoad) {
        final song = songs[i];
        try {
          // print('🖼️ Cargando carátula para: ${song.title} (índice: $i)');
          final artUri = await getOrCacheArtwork(song.id, song.data)
              .timeout(const Duration(milliseconds: 800));
          
          if (artUri != null) {
            // print('✅ Carátula cargada para: ${song.title} - ${artUri.path}');
            // Asegurar que el URI esté correctamente formateado
            final validUri = Uri.file(artUri.toFilePath());
            final updatedMediaItem = mediaItems[i].copyWith(artUri: validUri);
            mediaItems[i] = updatedMediaItem;
            // print('🔗 URI de carátula inicial formateado: $validUri');
          } else {
           //  print('⚠️ No se pudo cargar carátula para: ${song.title}');
          }
        } catch (e) {
          // print('❌ Error cargando carátula para ${song.title}: $e');
        }
      }
    }
    
    // print('✅ MediaItems creados con carátulas: ${mediaItems.where((m) => m.artUri != null).length}/${mediaItems.length}');
    
    return mediaItems;
  }

  bool _areSongListsEqual(List<SongModel> a, List<SongModel> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].data != b[i].data) return false;
    }
    return true;
  }

  Future<void> setQueueFromSongs(
    List<SongModel> songs, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool resetShuffle = true,
  }) async {
    return setQueueFromSongsWithPosition(
      songs,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
      autoPlay: autoPlay,
      resetShuffle: resetShuffle,
    );
  }

  Future<void> setQueueFromSongsWithPosition(
    List<SongModel> songs, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool resetShuffle = true,
  }) async {
    // Filtrar canciones que ya no existen en disco para evitar ENOENT
    final List<SongModel> validSongs = [];
    for (final s in songs) {
      try {
        if (await File(s.data).exists()) {
          validSongs.add(s);
        }
      } catch (_) {}
    }
    if (validSongs.isEmpty) {
      // Si no hay canciones válidas, limpiar estado y salir
      try {
        await _player.stop();
      } catch (_) {}
      _mediaQueue.clear();
      _currentSongList.clear();
      _originalSongList = null;
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      return;
    }

    // Verificar si el handler está inicializado correctamente
    if (!_isInitialized) {
      await _init();
    }

    // Solo desactiva shuffle si la lista realmente cambia y resetShuffle es true
    bool shouldResetShuffle = false;
    if (resetShuffle &&
        (_originalSongList == null ||
            !_areSongListsEqual(_originalSongList!, validSongs))) {
      shouldResetShuffle = true;
    }
    if (shouldResetShuffle) {
      isShuffleNotifier.value = false;
      _originalSongList = null;
    }
    _currentSongList = List<SongModel>.from(validSongs);
    isQueueTransitioning.value = true;
    initializingNotifier.value = true;
    _initializing = true;
    _loadVersion++;
    final int currentVersion = _loadVersion;

    // Guardar la lista original solo la primera vez
    if (_originalSongList == null || _originalSongList!.isEmpty) {
      _originalSongList = List<SongModel>.from(validSongs);
    }

    // Validar el índice inicial
    if (initialIndex < 0 || initialIndex >= validSongs.length) {
      initialIndex = 0;
    }

    // 1. Crear MediaItems con carátulas para las primeras canciones
    _mediaQueue.clear();
    final mediaItems = await _createMediaItemsWithArtwork(validSongs, priorityIndex: initialIndex);
    _mediaQueue.addAll(mediaItems);
    queue.add(List<MediaItem>.from(_mediaQueue));
    // Persistir cola inmediatamente (lista de rutas)
    unawaited(() async {
      try {
        final paths = _mediaQueue.map((m) => m.id).toList();
        await _prefs?.setStringList(_kPrefQueuePaths, paths);
      } catch (_) {}
    }());

    // 2. Crear AudioSources sin verificación de archivos (just_audio maneja errores)
    // ignore: deprecated_member_use
    _concat = ConcatenatingAudioSource(
      children: [
        for (final song in validSongs) AudioSource.uri(Uri.file(song.data)),
      ],
    );

    // 3. Cargar fuentes en el reproductor de forma asíncrona con timeout
    Future.delayed(Duration.zero, () async {
      try {
        // ignore: deprecated_member_use
        await _player
            .setAudioSource(
              _concat!,
              initialIndex: initialIndex,
              initialPosition: initialPosition,
            )
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw Exception('Timeout al cargar fuentes de audio');
              },
            );

        if (currentVersion != _loadVersion) return;

        // Establecer el MediaItem actual inmediatamente
        if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
          final selectedMediaItem = _mediaQueue[initialIndex];
          // Solo emitir si la canción realmente cambia
          if (mediaItem.value?.id != selectedMediaItem.id) {
            // Verificar si la carátula está en caché antes de actualizar
            final songPath = selectedMediaItem.extras?['data'] as String?;
            MediaItem finalSelectedItem = selectedMediaItem;

            if (songPath != null && _artworkCache.containsKey(songPath)) {
              final artUri = _artworkCache[songPath];
              if (artUri != null) {
                finalSelectedItem = selectedMediaItem.copyWith(artUri: artUri);
                _mediaQueue[initialIndex] = finalSelectedItem;
              }
            }

            mediaItem.add(finalSelectedItem);
            playbackState.add(
              playbackState.value.copyWith(queueIndex: initialIndex),
            );
            // Persistir índice y posición inicial
            unawaited(() async {
              try {
                await _prefs?.setInt(_kPrefQueueIndex, initialIndex);
                await _prefs?.setInt(
                  _kPrefSongPositionSec,
                  initialPosition.inSeconds,
                );
              } catch (_) {}
            }());

            // Si la carátula está en caché, actualizar inmediatamente
            if (songPath != null && _artworkCache.containsKey(songPath)) {
              final artUri = _artworkCache[songPath];
              if (artUri != null && selectedMediaItem.artUri != artUri) {
                final updatedMediaItem = selectedMediaItem.copyWith(
                  artUri: artUri,
                );
                _mediaQueue[initialIndex] = updatedMediaItem;
                mediaItem.add(updatedMediaItem);
              }
            }
          }
        }

        // Finalizar la inicialización
        _initializing = false;
        initializingNotifier.value = false;
        isQueueTransitioning.value = false;

        // Sincronizar el estado del shuffle
        _syncShuffleState();

        if (autoPlay) {
          await play();
        }
        // Precargar próximas carátulas tras restaurar/establecer cola
        if (initialIndex >= 0) {
          _preloadNextArtworks(initialIndex);
        }
        
        // Precargar todas las carátulas en background SIN actualizar MediaItem
        unawaited(_preloadAllArtworksInBackground(validSongs));
      } catch (e) {
        // Si falla, intentar con una sola canción
        try {
          await SongsIndexDB().cleanNonExistentFiles();
        } catch (_) {}
        if (validSongs.isNotEmpty) {
          try {
            final firstSong = validSongs.first;
            // Validar nuevamente por si cambió entre tanto
            if (!await File(firstSong.data).exists()) {
              throw Exception('First song missing');
            }
            final firstSource = AudioSource.uri(Uri.file(firstSong.data));
            // ignore: deprecated_member_use
            await _player.setAudioSource(
              // ignore: deprecated_member_use
              ConcatenatingAudioSource(children: [firstSource]),
            );
            if (_mediaQueue.isNotEmpty) {
              mediaItem.add(_mediaQueue.first);
              playbackState.add(playbackState.value.copyWith(queueIndex: 0));
            }
          } catch (e2) {
            // Error crítico, limpiar todo
            _mediaQueue.clear();
            queue.add([]);
            mediaItem.add(null);
          }
        }

        // Finalizar la inicialización incluso si hay error
        _initializing = false;
        initializingNotifier.value = false;
        isQueueTransitioning.value = false;
      }
    });

    // Precargar carátulas de las primeras canciones de forma asíncrona
    if (songs.isNotEmpty) {
      unawaited(() async {
        try {
          await preloadArtworks(songs.take(5).toList());
        } catch (e) {
          // Error silencioso
        }
      }());
    }
  }

  AudioPlayer get player => _player;

  // Inicializar el AudioPlayer con AndroidLoudnessEnhancer

  // Variable para almacenar el nivel de volume boost
  double _volumeBoost = 1.0;
  final ValueNotifier<double> _volumeBoostNotifier = ValueNotifier<double>(1.0);

  // Getter para obtener el volume boost actual
  double get volumeBoost => _volumeBoost;
  
  // Getter para el notifier (para la UI)
  ValueNotifier<double> get volumeBoostNotifier => _volumeBoostNotifier;

  // Método para establecer el volume boost usando AndroidLoudnessEnhancer
  Future<void> setVolumeBoost(double boostLevel) async {
    try {
      // print('🔊 === INICIANDO setVolumeBoost ===');
      // print('🔊 Boost level recibido: $boostLevel');
      
      // Limitar el boost entre 1.0 y 3.0 para evitar distorsión excesiva
      _volumeBoost = boostLevel.clamp(1.0, 3.0);
      
      // print('🔊 Volume boost limitado a: ${_volumeBoost}x');
      
      // Mantener volumen normal del player
      await _player.setVolume(1.0);
      
      // Usar AndroidLoudnessEnhancer para el boost
      if (_loudnessEnhancer != null) {
        if (_volumeBoost == 1.0) {
          // Desactivar enhancer
          _loudnessEnhancer!.setTargetGain(0.0);
          _loudnessEnhancer!.setEnabled(false);
          // ('🔊 LoudnessEnhancer desactivado (volumen normal)');
        } else {
          // Calcular gain en dB
          // boostLevel 1.5 = 5dB, 2.0 = 10dB, 3.0 = 20dB
          final gainInDb = ((_volumeBoost - 1.0) * 10).clamp(0.0, 20.0);
          _loudnessEnhancer!.setTargetGain(gainInDb);
          _loudnessEnhancer!.setEnabled(true);
          // print('🔊 LoudnessEnhancer aplicado: ${gainInDb}dB (${_volumeBoost}x boost)');
        }
      } else {
        // Fallback a setVolume si no hay enhancer
        await _player.setVolume(_volumeBoost);
        // print('🔊 Fallback: setVolume a ${_volumeBoost}x (LoudnessEnhancer no disponible)');
      }
      
      // print('🔊 Actualizando notifier...');
      // Actualizar notifier para la UI
      _volumeBoostNotifier.value = _volumeBoost;
      
      // print('🔊 Guardando preferencia...');
      // Guardar preferencia
      await _saveVolumeBoostPreference();
      
      // print('🔊 === setVolumeBoost COMPLETADO ===');
      
    } catch (e) {
      // print('❌ Error al establecer volume boost: $e');
      // print('❌ Stack trace: ${StackTrace.current}');
    }
  }

  // Cargar preferencia de volume boost
  Future<void> _loadVolumeBoostPreference() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final savedBoost = _prefs?.getDouble('volume_boost') ?? 1.0;
      _volumeBoost = savedBoost;
      _volumeBoostNotifier.value = savedBoost;
      
      // Aplicar el volume boost usando LoudnessEnhancer
      await _player.setVolume(1.0);
      
      if (_loudnessEnhancer != null) {
        if (_volumeBoost == 1.0) {
          _loudnessEnhancer!.setTargetGain(0.0);
          _loudnessEnhancer!.setEnabled(false);
          // print('🔊 Volume boost cargado: normal (LoudnessEnhancer desactivado)');
        } else {
          final gainInDb = ((_volumeBoost - 1.0) * 10).clamp(0.0, 20.0);
          _loudnessEnhancer!.setTargetGain(gainInDb);
          _loudnessEnhancer!.setEnabled(true);
          // print('🔊 Volume boost cargado: ${_volumeBoost}x (${gainInDb}dB)');
        }
      } else {
        // Fallback
        await _player.setVolume(_volumeBoost);
        // print('🔊 Volume boost cargado: ${_volumeBoost}x (fallback)');
      }
    } catch (e) {
      // print('Error al cargar preferencia de volume boost: $e');
    }
  }

  // Guardar preferencia de volume boost
  Future<void> _saveVolumeBoostPreference() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      await _prefs?.setDouble('volume_boost', _volumeBoost);
    } catch (e) {
      // print('Error al guardar preferencia de volume boost: $e');
    }
  }

  // Finalizar el AudioPlayer con AndroidLoudnessEnhancer

  @override
  Future<void> play() async {
    // Verificar si hay canciones disponibles
    if (_mediaQueue.isEmpty) {
      return;
    }

    // Si estamos inicializando fuentes, espera brevemente a que termine
    if (_initializing) {
      final int maxWaitMs = 1500;
      int waited = 0;
      while (_initializing && waited < maxWaitMs) {
        await Future.delayed(const Duration(milliseconds: 50));
        waited += 50;
      }
    }

    try {
      await _player.play();
    } catch (e) {
      // Reintentar una vez tras pequeña espera si seguía inicializando
      if (_initializing) {
        await Future.delayed(const Duration(milliseconds: 200));
        try {
          await _player.play();
          return;
        } catch (_) {}
      }

      // Último recurso: re-crear el player y reconstruir la cola actual
      try {
        final int fallbackIndex = _player.currentIndex ?? 0;
        await _reinitializePlayer();
        if (_currentSongList.isNotEmpty) {
          await setQueueFromSongsWithPosition(
            _currentSongList,
            initialIndex: fallbackIndex.clamp(0, _currentSongList.length - 1),
            autoPlay: true,
            resetShuffle: false,
          );
        }
      } catch (e2) {
        // Error silencioso
      }
    }
  }

  @override
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      // Manejo de errores al intentar pausar
    }
  }

  @override
  Future<void> stop() async {
    try {
      // Cancelar todos los listeners
      await _disposeListeners();
      // Cancelar temporizador de sueño si está activo
      cancelSleepTimer();

      // Cancelar timer de notificaciones
      _notificationUpdateTimer?.cancel();

      // Detener y limpiar el reproductor completamente
      await _player.stop();
      await _player.dispose();

      // Limpiar la sesión de audio
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
      } catch (e) {
        // Error silencioso
      }

      // Limpiar el estado del reproductor
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      // Limpiar la instancia global
      // clearAudioHandlerInstance();
    } catch (e) {
      // Manejo de errores al intentar detener
    }
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    // Ejecuta el seek de forma asíncrona para no bloquear la UI
    unawaited(_player.seek(position));
    // Actualiza el temporizador cuando se cambia la posición
    _updateSleepTimer();
  }

  /// Controla la pausa automática durante cambios de canción
  void _handleSongChangePause() {
    // Solo establecer el estado original en el primer cambio
    if (_songChangeResumeTimer == null) {
      _wasPlayingBeforeChange = _player.playing;
    }
    
    // Cancelar timer anterior si existe
    _songChangeResumeTimer?.cancel();
    
    // Si estaba reproduciéndose originalmente y no está pausado, pausar
    if (_wasPlayingBeforeChange && _player.playing) {
      _player.pause();
    }
    
    // Configurar timer para reanudar después del delay
    _songChangeResumeTimer = Timer(_songChangeDelay, () {
      if (_wasPlayingBeforeChange && !_player.playing) {
        _player.play();
      }
      _wasPlayingBeforeChange = false;
      _songChangeResumeTimer = null; // Limpiar referencia al timer
    });
  }

  @override
  Future<void> skipToNext() async {
    if (_initializing || _isSkipping) return;

    _isSkipping = true;

    try {
      // Pausar automáticamente durante el cambio de canción
      _handleSongChangePause();
      
      // Cancelar operaciones pendientes antes de cambiar
      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();

      await _player.seekToNext();
      _updateSleepTimer();

      // La nueva carátula se cargará automáticamente por el currentIndexStream listener
    } catch (e) {
      // Error silencioso
    } finally {
      _isSkipping = false;
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_initializing || _isSkipping) return;

    _isSkipping = true;
    try {
      // Pausar automáticamente durante el cambio de canción
      _handleSongChangePause();
      
      // Cancelar operaciones pendientes antes de cambiar
      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();

      if (_player.position.inMilliseconds > 5000) {
        await _player.seek(Duration.zero);
      } else {
        await _player.seekToPrevious();
      }
      _updateSleepTimer();

      // La nueva carátula se cargará automáticamente por el currentIndexStream listener
    } catch (e) {
      // Error silencioso
    } finally {
      _isSkipping = false;
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_initializing) return;
    if (index >= 0 && index < _mediaQueue.length) {
      try {
        // Cancelar operaciones pendientes antes de cambiar
        _pendingArtworkOperations.clear();
        cancelAllArtworkLoads();

        final wasPlaying = _player.playing;

        // Ejecutar el seek de forma asíncrona
        unawaited(() async {
          try {
            await _player.seek(Duration.zero, index: index);
            _updateSleepTimer();

            if (wasPlaying && !_player.playing) {
              await _player.play();
            }
          } catch (e) {
            // Error silencioso
          }
        }());
      } catch (e) {
        // Error silencioso
      }
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enable = shuffleMode == AudioServiceShuffleMode.all;
    await toggleShuffle(enable);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (repeatMode == AudioServiceRepeatMode.one) {
      await _player.setLoopMode(LoopMode.one);
    } else if (repeatMode == AudioServiceRepeatMode.all) {
      await _player.setLoopMode(LoopMode.all);
    } else {
      await _player.setLoopMode(LoopMode.off);
    }
    
    // Actualizar el estado de playback con ambos modos para sincronización completa
    playbackState.add(playbackState.value.copyWith(
      repeatMode: repeatMode,
      shuffleMode: _player.shuffleModeEnabled 
          ? AudioServiceShuffleMode.all 
          : AudioServiceShuffleMode.none,
    ));
    
    // Persistir repeat mode como entero
    unawaited(() async {
      try {
        final int modeInt = repeatMode == AudioServiceRepeatMode.one
            ? 1
            : repeatMode == AudioServiceRepeatMode.all
            ? 2
            : 0;
        await _prefs?.setInt(_kPrefRepeatMode, modeInt);
      } catch (_) {}
    }());
  }

  /// Sincroniza el estado del isShuffleNotifier con el estado real del player
  void _syncShuffleState() {
    isShuffleNotifier.value = _player.shuffleModeEnabled;
  }

  /// Activa o desactiva el modo aleatorio usando shuffle nativo de just_audio
  /// Esto evita completamente las pausas de audio
  Future<void> toggleShuffle(bool enable) async {
    // Intervalo mínimo de 1 segundo entre toques
    final now = DateTime.now();
    if (now.difference(_lastShuffleToggle).inMilliseconds < 1000) return;
    _lastShuffleToggle = now;
    if (_mediaQueue.isEmpty) return;

    try {
      if (enable) {
        isShuffleNotifier.value = true;
        
        // Usar el shuffle nativo de just_audio - sin pausas de audio
        await _player.setShuffleModeEnabled(true);
        await _player.shuffle();
        
        // Actualizar el estado de audio_service con ambos modos para sincronización completa
        playbackState.add(playbackState.value.copyWith(
          shuffleMode: AudioServiceShuffleMode.all,
          repeatMode: _player.loopMode == LoopMode.one
              ? AudioServiceRepeatMode.one
              : _player.loopMode == LoopMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none,
        ));
      } else {
        isShuffleNotifier.value = false;
        
        // Desactivar shuffle nativo de just_audio
        await _player.setShuffleModeEnabled(false);
        
        // Actualizar el estado de audio_service con ambos modos para sincronización completa
        playbackState.add(playbackState.value.copyWith(
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: _player.loopMode == LoopMode.one
              ? AudioServiceRepeatMode.one
              : _player.loopMode == LoopMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none,
        ));
      }
      
      // Persistir flag de shuffle
      unawaited(() async {
        try {
          await _prefs?.setBool(_kPrefShuffleEnabled, enable);
        } catch (_) {}
      }());
    } catch (e) {
      // En caso de error, revertir el estado
      isShuffleNotifier.value = !enable;
      playbackState.add(playbackState.value.copyWith(
        shuffleMode: enable ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all,
        repeatMode: _player.loopMode == LoopMode.one
            ? AudioServiceRepeatMode.one
            : _player.loopMode == LoopMode.all
            ? AudioServiceRepeatMode.all
            : AudioServiceRepeatMode.none,
      ));
    }
  }

  Stream<Duration> get positionStream => _player.positionStream;

  /// Añade una o varias canciones al final de la cola actual, preservando la
  /// canción en reproducción, su posición y el estado de reproducción.
  Future<void> addSongsToQueueEnd(List<SongModel> songsToAppend) async {
    if (songsToAppend.isEmpty) return;

    // Si no hay cola actual, establece la cola con estas canciones
    if (_currentSongList.isEmpty || _mediaQueue.isEmpty) {
      await setQueueFromSongs(
        songsToAppend,
        initialIndex: 0,
        autoPlay: false,
        resetShuffle: false,
      );
      return;
    }

    // Filtrar canciones inválidas (archivos inexistentes)
    final List<SongModel> validToAppend = [];
    for (final s in songsToAppend) {
      try {
        if (await File(s.data).exists()) {
          validToAppend.add(s);
        }
      } catch (_) {}
    }
    if (validToAppend.isEmpty) return;

    // Modo recomendado para evitar cortes: anexar directamente al concatenating source
    // ignore: deprecated_member_use
    if (_concat != null) {
      try {
        final newSources = validToAppend
            .map((s) => AudioSource.uri(Uri.file(s.data)))
            .toList();
        // ignore: deprecated_member_use
        await _concat!.addAll(newSources);

        // Actualizar estructuras y emitir cola sin tocar índice/posición
        for (final s in validToAppend) {
          final index = _mediaQueue.length;
          _currentSongList.add(s);
          final mediaItem = MediaItem(
            id: s.data,
            album: s.album ?? '',
            title: s.title,
            artist: s.artist ?? '',
            duration: (s.duration != null && s.duration! > 0)
                ? Duration(milliseconds: s.duration!)
                : null,
            extras: {
              'songId': s.id,
              'albumId': s.albumId,
              'data': s.data,
              'queueIndex': index,
            },
          );
          _mediaQueue.add(mediaItem);
        }
        queue.add(List<MediaItem>.from(_mediaQueue));
        // Persistir cola actualizada
        unawaited(() async {
          try {
            final paths = _mediaQueue.map((m) => m.id).toList();
            await _prefs?.setStringList(_kPrefQueuePaths, paths);
          } catch (_) {}
        }());
        return;
      } catch (_) {
        // Fallback a reconstrucción si llegara a fallar el append
      }
    }

    // Fallback: reconstrucción manteniendo estado
    final int? currentIndex = _player.currentIndex;
    final Duration currentPosition = _player.position;
    final bool wasPlaying = _player.playing;
    final List<SongModel> newSongs = List<SongModel>.from(_currentSongList)
      ..addAll(validToAppend);
    final int safeIndex = (currentIndex ?? 0).clamp(0, newSongs.length - 1);
    await setQueueFromSongsWithPosition(
      newSongs,
      initialIndex: safeIndex,
      initialPosition: currentPosition,
      autoPlay: wasPlaying,
      resetShuffle: false,
    );
    // Persistir cola reconstruida
    unawaited(() async {
      try {
        final paths = _mediaQueue.map((m) => m.id).toList();
        await _prefs?.setStringList(_kPrefQueuePaths, paths);
        final idx = _player.currentIndex ?? safeIndex;
        await _prefs?.setInt(_kPrefQueueIndex, idx);
      } catch (_) {}
    }());
  }

  /// Inicia el temporizador de apagado automático.
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepDuration = duration;
    _sleepStartPosition = _player.position;

    // Calcula el tiempo restante basado en la posición actual
    final remainingTime = _calculateRemainingTime();
    if (remainingTime != null && remainingTime.inMilliseconds > 0) {
      _sleepTimer = Timer(remainingTime, () async {
        await pause();
        _sleepDuration = null;
        _sleepStartPosition = null;
      });
    } else if (remainingTime != null && remainingTime.inMilliseconds == 0) {
      // Si el tiempo restante es 0, pausa inmediatamente
      pause();
      _sleepDuration = null;
      _sleepStartPosition = null;
    }
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDuration = null;
    _sleepStartPosition = null;
  }

  /// Actualiza el temporizador cuando cambia la posición de reproducción
  void _updateSleepTimer() {
    if (_sleepDuration == null || _sleepStartPosition == null) return;

    _sleepTimer?.cancel();
    final remainingTime = _calculateRemainingTime();

    if (remainingTime != null && remainingTime.inMilliseconds > 0) {
      _sleepTimer = Timer(remainingTime, () async {
        await pause();
        _sleepDuration = null;
        _sleepStartPosition = null;
      });
    } else if (remainingTime != null && remainingTime.inMilliseconds == 0) {
      // Si el tiempo restante es 0, pausa inmediatamente
      pause();
      _sleepDuration = null;
      _sleepStartPosition = null;
    } else {
      // Si el tiempo restante es negativo, cancela el temporizador
      _sleepDuration = null;
      _sleepStartPosition = null;
    }
  }

  /// Calcula el tiempo restante basado en la posición actual
  Duration? _calculateRemainingTime() {
    if (_sleepDuration == null || _sleepStartPosition == null) return null;

    final currentPosition = _player.position;
    final songDuration = _player.duration;

    // Si no tenemos la duración de la canción, usa la lógica original
    if (songDuration == null) {
      final elapsedSinceStart = currentPosition - _sleepStartPosition!;
      final remaining = _sleepDuration! - elapsedSinceStart;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    // Calcula cuándo debe pausar (1 segundo antes del final de la canción)
    final pauseTime = songDuration - const Duration(seconds: 1);

    // Si ya pasamos el tiempo de pausa, pausa inmediatamente
    if (currentPosition >= pauseTime) {
      return Duration.zero;
    }

    // Calcula el tiempo restante hasta el momento de pausa
    return pauseTime - currentPosition;
  }

  /// Devuelve el tiempo restante o null si no hay temporizador activo.
  Duration? get sleepTimeRemaining => _calculateRemainingTime();

  bool get isSleepTimerActive => _sleepDuration != null;

  /// Precarga todas las carátulas en background SIN actualizar MediaItem para evitar parpadeos
  Future<void> _preloadAllArtworksInBackground(List<SongModel> songs) async {
    try {
      if (songs.isEmpty) return;

      // print('🚀 Iniciando precarga masiva de ${songs.length} carátulas en background...');
      
      // Filtrar canciones que no están ya en caché
      final songsToLoad = songs
          .where((song) => 
              !_artworkCache.containsKey(song.data) &&
              !_preloadCache.containsKey(song.data))
          .take(20) // Limitar a 20 canciones para no sobrecargar
          .toList();

      if (songsToLoad.isEmpty) return;

      // Cargar carátulas en lotes pequeños para no bloquear la UI
      const int batchSize = 3;
      for (int i = 0; i < songsToLoad.length; i += batchSize) {
        final batch = songsToLoad.skip(i).take(batchSize).toList();
        
        // Cargar lote en paralelo
        await Future.wait(
          batch.map((song) async {
            try {
              // Solo cargar al caché, SIN actualizar MediaItem
              await getOrCacheArtwork(song.id, song.data);
              // print('✅ Precargada: ${song.title}');
            } catch (e) {
              // Error silencioso
            }
          }),
        );
        
        // Pequeña pausa entre lotes para no sobrecargar
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      // print('🎉 Precarga masiva completada: ${songsToLoad.length} carátulas');
    } catch (e) {
      // Error silencioso
    }
  }

  /// Precarga carátulas de canciones próximas (simplificada para mejor rendimiento)
  Timer? _preloadDebounceTimer;
  void _preloadNextArtworks(int currentIndex) {
    if (_currentSongList.isEmpty) return;

    _preloadDebounceTimer?.cancel();
    _preloadDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      // Precargar solo las próximas 2 canciones para no sobrecargar
      final indicesToPreload = <int>[];

      // Solo siguientes 2 canciones (reducido drásticamente)
      for (int i = 1; i <= 2; i++) {
        final nextIndex = currentIndex + i;
        if (nextIndex < _currentSongList.length) {
          indicesToPreload.add(nextIndex);
        }
      }

      // Precargar de forma muy simple sin lotes ni concurrencia excesiva
      if (indicesToPreload.isNotEmpty) {
        unawaited(() async {
          try {
            for (final index in indicesToPreload) {
              final song = _currentSongList[index];
              if (!_artworkCache.containsKey(song.data) &&
                  !_preloadCache.containsKey(song.data)) {
                // Cargar con timeout muy corto
                try {
                  await getOrCacheArtwork(
                    song.id,
                    song.data,
                  ).timeout(const Duration(milliseconds: 500));
                } catch (e) {
                  // Error silencioso - continuar con la siguiente
                }
              }
              // Pequeña pausa entre cargas
              await Future.delayed(const Duration(milliseconds: 100));
            }
          } catch (e) {
            // Error silencioso
          }
        }());
      }
    });
  }

  /// Reinicializa el reproductor cuando es necesario
  Future<void> _reinitializePlayer() async {
    try {
      await _player.stop();
      await _player.dispose();

      final newPlayer = AudioPlayer();
      _player = newPlayer;
      await _init();
    } catch (e) {
      _player = AudioPlayer();
    }
  }

  // Guarda toda la sesión actual en SharedPreferences
  Future<void> _saveSessionToPrefs() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      final paths = _mediaQueue.map((m) => m.id).toList();
      await prefs.setStringList(_kPrefQueuePaths, paths);
      final idx = _player.currentIndex ?? 0;
      await prefs.setInt(_kPrefQueueIndex, idx);
      await prefs.setInt(_kPrefSongPositionSec, _player.position.inSeconds);
      final repeat = playbackState.value.repeatMode;
      final repeatInt = repeat == AudioServiceRepeatMode.one
          ? 1
          : repeat == AudioServiceRepeatMode.all
          ? 2
          : 0;
      await prefs.setInt(_kPrefRepeatMode, repeatInt);
      final shuffleEnabled =
          playbackState.value.shuffleMode == AudioServiceShuffleMode.all ||
          isShuffleNotifier.value;
      await prefs.setBool(_kPrefShuffleEnabled, shuffleEnabled);
      await prefs.setBool(_kPrefWasPlaying, _player.playing);
    } catch (_) {}
  }

  // Restaura la sesión previa si es posible
  Future<void> _attemptRestoreFromPrefs() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      final savedPaths = prefs.getStringList(_kPrefQueuePaths) ?? const [];
      if (savedPaths.isEmpty) {
        _restoredSession = true;
        return;
      }

      // Consultar todas las canciones y mapear por ruta
      final query = OnAudioQuery();
      final allSongs = await query.querySongs();
      if (allSongs.isEmpty) {
        _restoredSession = true;
        return;
      }
      final Map<String, SongModel> byPath = {
        for (final s in allSongs) s.data: s,
      };
      final List<SongModel> songs = [];
      for (final p in savedPaths) {
        final s = byPath[p];
        if (s != null) songs.add(s);
      }
      if (songs.isEmpty) {
        _restoredSession = true;
        return;
      }

      final savedIndex = (prefs.getInt(_kPrefQueueIndex) ?? 0).clamp(
        0,
        songs.length - 1,
      );
      final posSec = prefs.getInt(_kPrefSongPositionSec) ?? 0;
      final repeatInt = prefs.getInt(_kPrefRepeatMode) ?? 0;
      final shuffleEnabled = prefs.getBool(_kPrefShuffleEnabled) ?? false;

      await setQueueFromSongsWithPosition(
        songs,
        initialIndex: savedIndex,
        initialPosition: Duration(seconds: posSec),
        autoPlay: false,
        resetShuffle: false,
      );

      // Aplicar repeat
      final repeatMode = repeatInt == 1
          ? AudioServiceRepeatMode.one
          : repeatInt == 2
          ? AudioServiceRepeatMode.all
          : AudioServiceRepeatMode.none;
      await setRepeatMode(repeatMode);

      // Aplicar shuffle propio si estaba activo
      if (shuffleEnabled) {
        unawaited(toggleShuffle(true));
      }
      
      // Asegurar que la carátula de la canción actual se cargue inmediatamente
      if (savedIndex >= 0 && savedIndex < _mediaQueue.length) {
        final currentMediaItem = _mediaQueue[savedIndex];
        final songPath = currentMediaItem.extras?['data'] as String?;
        final songId = currentMediaItem.extras?['songId'] as int?;
        
        if (songPath != null && songId != null) {
          // Verificar si ya está en caché
          if (!_artworkCache.containsKey(songPath)) {
            // Cargar inmediatamente en background
            unawaited(() async {
              try {
                final artUri = await getOrCacheArtwork(songId, songPath)
                    .timeout(const Duration(milliseconds: 1500));
                
                if (artUri != null && mounted) {
                  final validUri = Uri.file(artUri.toFilePath());
                  final updatedMediaItem = currentMediaItem.copyWith(artUri: validUri);
                  _mediaQueue[savedIndex] = updatedMediaItem;
                  
                  // Actualizar la notificación con la carátula
                  mediaItem.add(updatedMediaItem);
                }
              } catch (e) {
                // Error silencioso
              }
            }());
          }
        }
      }
      
      _preloadNextArtworks(savedIndex);
    } catch (_) {
      // Ignorar errores de restauración
    } finally {
      _restoredSession = true;
    }
  }

  @override
  Future customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == "saveSession") {
      await _saveSessionToPrefs();
    }
    return super.customAction(name, extras);
  }

  /// Elimina una o varias canciones de la cola por su ruta absoluta (song.data).
  /// Si la canción actual está incluida, se pasa a la siguiente disponible.
  Future<void> removeSongsByPath(List<String> songPathsToRemove) async {
    if (songPathsToRemove.isEmpty) return;
    if (_currentSongList.isEmpty && _mediaQueue.isEmpty) return;

    final Set<String> toRemove = songPathsToRemove.toSet();

    final int? currentIndex = _player.currentIndex;
    final bool wasPlaying = _player.playing;
    String? currentPath;
    if (currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < _mediaQueue.length) {
      currentPath = _mediaQueue[currentIndex].id;
    }

    final bool currentIsBeingRemoved =
        currentPath != null && toRemove.contains(currentPath);

    // Construir nueva lista de canciones sin las que se van a eliminar
    final List<SongModel> newSongs = _currentSongList
        .where((s) => !toRemove.contains(s.data))
        .toList();

    // Limpiar carátulas del cache para las rutas eliminadas
    for (final path in toRemove) {
      removeArtworkFromCache(path);
    }

    // Mantener la lista original coherente para el modo shuffle
    if (_originalSongList != null) {
      _originalSongList!.removeWhere((s) => toRemove.contains(s.data));
    }

    if (newSongs.isEmpty) {
      // No queda nada que reproducir: limpiar la cola y estado, pero sin
      // destruir el reproductor para evitar problemas al reproducir después.
      try {
        await _player.stop();
      } catch (_) {}
      // Cancelar listeners actuales para evitar estados colgados
      try {
        await _disposeListeners();
      } catch (_) {}
      _mediaQueue.clear();
      _currentSongList.clear();
      _originalSongList = null;
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      // Forzar re-inicialización suave en el próximo setQueue
      _isInitialized = false;
      return;
    }

    int initialIndex = 0;
    var initialPosition = Duration.zero;

    bool hasValidNextAfterRemoval = false;

    if (!currentIsBeingRemoved && currentPath != null) {
      // Mantener la canción actual y su posición si no fue eliminada
      final idx = newSongs.indexWhere((s) => s.data == currentPath);
      if (idx >= 0) {
        initialIndex = idx;
        initialPosition = _player.position;
        hasValidNextAfterRemoval = true;
      }
    } else if (currentIsBeingRemoved) {
      // Buscar la siguiente canción disponible después de la actual en la lista anterior
      int? nextIndexInOld;
      if (currentIndex != null) {
        for (int i = currentIndex + 1; i < _currentSongList.length; i++) {
          if (!toRemove.contains(_currentSongList[i].data)) {
            nextIndexInOld = i;
            break;
          }
        }
      }
      if (nextIndexInOld != null) {
        final nextPath = _currentSongList[nextIndexInOld].data;
        final idxInNew = newSongs.indexWhere((s) => s.data == nextPath);
        if (idxInNew >= 0) {
          initialIndex = idxInNew;
          hasValidNextAfterRemoval = true;
        }
      } else {
        // No hay siguiente; no auto-reproducir si antes estaba reproduciendo
        // (comportamiento similar a saltar al final de la lista)
      }
    }

    // Reconstruir la cola; autoPlay solo si seguía reproduciendo y hay un destino válido
    final bool shouldAutoplay =
        wasPlaying && (!currentIsBeingRemoved || hasValidNextAfterRemoval);
    await setQueueFromSongsWithPosition(
      newSongs,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      autoPlay: shouldAutoplay,
      resetShuffle: false,
    );
    // Persistir nueva cola tras eliminar
    unawaited(() async {
      try {
        final paths = _mediaQueue.map((m) => m.id).toList();
        await _prefs?.setStringList(_kPrefQueuePaths, paths);
        final idx = _player.currentIndex ?? initialIndex;
        await _prefs?.setInt(_kPrefQueueIndex, idx);
      } catch (_) {}
    }());
  }

  /// Helper para eliminar una sola canción por ruta
  Future<void> removeSongByPath(String songPath) async {
    await removeSongsByPath([songPath]);
  }

  /// Precarga inmediatamente la carátula para un índice específico
  /// Optimizado para transiciones automáticas de canciones
  void _preloadArtworkForIndex(int index) {
    if (index < 0 || index >= _currentSongList.length) return;
    
    final song = _currentSongList[index];
    final songId = song.id;
    final songPath = song.data;
    
    // Verificar si ya está en caché en memoria
    if (_artworkCache.containsKey(songPath)) {
      // print('⚡ TRANSICIÓN: Carátula ya en caché de memoria - ID: $songId');
      return;
    }
    
    // Precargar inmediatamente en background
    unawaited(() async {
      try {
        // print('🚀 TRANSICIÓN: Precargando carátula para transición automática - ID: $songId');
        
        // Verificar si existe en caché temporal
        _tempDirPath ??= (await getTemporaryDirectory()).path;
        final cachedFile = File('$_tempDirPath/artwork_$songId.jpg');
        
        if (await cachedFile.exists()) {
          // Ya existe en caché, agregar a memoria
          _artworkCache[songPath] = Uri.file(cachedFile.path);
          // print('✅ TRANSICIÓN: Carátula agregada a caché de memoria desde archivo - ID: $songId');
          return;
        }
        
        // Si no existe, cargar y guardar
        final bytes = await _albumArtCacheManager.getAlbumArt(songId, songPath);
        if (bytes != null && bytes.isNotEmpty) {
          await cachedFile.writeAsBytes(bytes);
          final uri = Uri.file(cachedFile.path);
          _artworkCache[songPath] = uri;
          
          // Verificar que el archivo se guardó correctamente
          if (await cachedFile.exists() && await cachedFile.length() > 0) {
            // print('💾 TRANSICIÓN: Carátula cargada y guardada para transición - ID: $songId');
          } else {
            // Archivo corrupto, remover del caché
            _artworkCache.remove(songPath);
            await cachedFile.delete();
          }
        }
      } catch (e) {
        // print('❌ TRANSICIÓN: Error precargando carátula - ID: $songId, Error: $e');
      }
    }());
  }
}