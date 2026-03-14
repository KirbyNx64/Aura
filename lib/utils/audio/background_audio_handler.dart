import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'album_art_cache_manager.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/encoding_utils.dart';
import 'package:music/utils/yt_search/service.dart' as yt_service;
import 'package:music/utils/yt_search/stream_provider.dart';

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
          androidNotificationChannelDescription:
              'Controles de reproducción de música',
          androidNotificationOngoing: true,
          androidNotificationClickStartsActivity: true,
          // androidStopForegroundOnPause: false,
          androidResumeOnClick: true,
          preloadArtwork: true,
        ),
      );

      return _audioHandler!;
    } catch (e) {
      _audioHandler = null;

      if (attempt == 3) {
        // En el último intento, lanzar la excepción
        throw Exception(
          'Error al inicializar AudioService después de 3 intentos: $e',
        );
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
  final artworkBytes = await _albumArtCacheManager.getAlbumArt(
    songId,
    songPath,
  );

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
  await _albumArtCacheManager.preloadAlbumArts(
    songsData,
    maxConcurrent: maxConcurrent,
  );
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
        final bytes = await _albumArtCacheManager.getAlbumArt(
          song.id,
          song.data,
        );

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
  late Stream<Duration> _positionStream;
  late Stream<Duration?> _durationStream;
  AndroidLoudnessEnhancer? _loudnessEnhancer; // Para volume boost
  AndroidEqualizer? _equalizer; // Para ecualizador
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
  StreamSubscription? _sleepTimerSub;
  Duration? _sleepDuration;
  Duration? _sleepStartPosition;
  int? _lastSleepIndex;
  bool _stopAtEndOfSong = false;
  bool _isSkipping = false;
  bool _queuedSkipNext = false;
  bool _queuedSkipPrevious = false;
  bool _isPreloadingNext = false;
  bool _isInitialized = false;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<AudioInterruptionEvent>? _audioInterruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  // Control de operaciones pendientes para evitar sobrecarga
  String? _lastProcessedSongId;
  final Map<String, bool> _pendingArtworkOperations = {};
  final Set<String> _favoriteIds = {};

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

  // Claves de SharedPreferences
  static const String _kPrefQueuePaths = 'playback_queue_paths';
  static const String _kPrefQueueIndex = 'playback_queue_index';
  static const String _kPrefSongPositionSec = 'playback_song_position_sec';
  static const String _kPrefRepeatMode =
      'playback_repeat_mode'; // 0 none, 1 one, 2 all
  static const String _kPrefShuffleEnabled = 'playback_shuffle_enabled';
  static const String _kPrefWasPlaying = 'playback_was_playing';
  static const String _kPrefRestoreLastSessionOnStartup =
      'restore_last_session_on_startup';

  // Control para evitar pausar automáticamente cuando el usuario selecciona una canción
  bool _userInitiatedPlayback = false;

  // Estado de radio automática para sesiones de streaming YouTube
  bool _streamRadioEnabled = false;
  String? _streamRadioSeedVideoId;
  String? _streamRadioContinuationParams;
  bool _streamRadioAppendInProgress = false;
  bool _streamRadioInitialBatchLoaded = false;
  bool _deferredStreamingQueueMode = false;
  int _deferredStreamingQueueIndex = 0;
  final Random _random = Random();
  List<int> _deferredShuffleOrder = const <int>[];
  int _deferredShuffleCursor = 0;
  final Set<String> _streamQueuedVideoIds = <String>{};
  final Map<String, Future<String?>> _streamUrlPrefetchTasks = {};
  final Map<String, Future<Uri?>> _streamArtworkPreloadTasks = {};
  final LinkedHashMap<String, Uri> _streamArtworkFileCache = LinkedHashMap();
  int _streamSessionVersion = 0;
  int _resolveGeneration =
      0; // Se incrementa en cada skip para cancelar resoluciones anteriores.
  int _artworkGeneration =
      0; // Se incrementa en cada skip para cancelar descargas de carátulas intermedias.
  int _activeArtworkDownloads =
      0; // Contador de descargas concurrentes activas.
  static const int _maxConcurrentArtworkDownloads = 2;
  static const int _streamRadioPrefetchThreshold = 2;
  static const int _streamRadioFixedQueueSize = 50;
  static const int _streamRadioOverscanCount = 12;
  static const int _streamArtworkPrefetchCount = 1;
  static const int _streamArtworkCacheMaxEntries = 120;

  MyAudioHandler() {
    _initializePlayerWithEnhancer();
    _init();
  }

  // Inicializar el AudioPlayer con LoudnessEnhancer y Equalizer desde el principio
  void _initializePlayerWithEnhancer() {
    try {
      // print('🔊 Inicializando AudioPlayer con AndroidLoudnessEnhancer y AndroidEqualizer...');

      final List<AndroidAudioEffect> effects = [];

      // Crear el LoudnessEnhancer
      _loudnessEnhancer = AndroidLoudnessEnhancer();
      _loudnessEnhancer!.setTargetGain(0.0); // Inicialmente sin boost
      _loudnessEnhancer!.setEnabled(true);
      effects.add(_loudnessEnhancer!);

      // Crear el Equalizer
      _equalizer = AndroidEqualizer();
      _equalizer!.setEnabled(false); // Inicialmente deshabilitado
      effects.add(_equalizer!);

      // Crear el AudioPipeline con los efectos
      final pipeline = AudioPipeline(androidAudioEffects: effects);

      // Crear AudioPlayer con el pipeline
      _player = AudioPlayer(audioPipeline: pipeline);
      _bindPlayerStreams();

      // print('🔊 AudioPlayer inicializado con AndroidLoudnessEnhancer y AndroidEqualizer exitosamente');
    } catch (e) {
      // print('⚠️ Error inicializando con LoudnessEnhancer y Equalizer, usando player normal: $e');
      // Fallback: crear player normal
      _player = AudioPlayer();
      _bindPlayerStreams();
      _loudnessEnhancer = null;
      _equalizer = null;
    }
  }

  void _bindPlayerStreams() {
    // Algunos streams del player pueden ser single-subscription según versión.
    // Exponemos wrappers broadcast para permitir múltiples listeners de UI.
    _positionStream = _player.positionStream.asBroadcastStream();
    _durationStream = _player.durationStream.asBroadcastStream();
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

      // Escuchar interrupciones de audio (llamadas, alarmas, etc.)
      _audioInterruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        if (event.begin) {
          // Interrupción comenzó (llamada entrante, alarma, etc.)
          switch (event.type) {
            case AudioInterruptionType.pause:
              // Pausar reproducción
              if (_player.playing) {
                unawaited(pause());
              }
              break;
            case AudioInterruptionType.duck:
              // Reducir volumen temporalmente (no hacer nada, el sistema lo maneja)
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        } else {
          // Interrupción terminó - restaurar configuración de audio
          _restoreAudioConfiguration();
        }
      });

      // Escuchar cuando se desconectan los auriculares
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        // Pausar cuando se desconectan los auriculares
        if (_player.playing) {
          unawaited(pause());
        }
      });

      // Cargar preferencias de volume boost
      await _loadVolumeBoostPreference();
      await _applyEqualizerSettingsFromPrefs();

      // Cancelar suscripciones anteriores si existen
      await _disposeListeners();

      _playbackEventSubscription = _player.playbackEventStream.listen(
        (event) {
          // Transformar el evento de just_audio a audio_service siguiendo la documentación
          final transformedState = _transformPlaybackEvent(event);
          playbackState.add(transformedState);

          // Si se completó y está en loop one, lanza el seek/play en segundo plano
          if (event.processingState == ProcessingState.completed &&
              !_stopAtEndOfSong &&
              _player.loopMode == LoopMode.one) {
            unawaited(_player.seek(Duration.zero));
            unawaited(_player.play());
          }

          // Precarga inteligente: cuando quedan pocos segundos, precargar la siguiente
          _preloadNextSongArtwork();

          // Si se completó y es la última canción de la lista, pausar automáticamente
          if (event.processingState == ProcessingState.completed) {
            if (_stopAtEndOfSong) {
              unawaited(() async {
                await pause();
                cancelSleepTimer();
              }());
              return;
            }
            if (_deferredStreamingQueueMode && _mediaQueue.isNotEmpty) {
              final nextIdx = _nextDeferredQueueIndex();
              if (nextIdx != null) {
                unawaited(_resolveAndPlayDeferredStreamingIndex(nextIdx));
                return;
              }

              if (_streamRadioEnabled) {
                unawaited(() async {
                  await _ensureStreamingRadioQueue(force: true);
                  final fetchedNextIndex = _nextDeferredQueueIndex();
                  if (fetchedNextIndex != null) {
                    await _resolveAndPlayDeferredStreamingIndex(
                      fetchedNextIndex,
                    );
                    return;
                  }
                  if (mounted && _player.playing && !_userInitiatedPlayback) {
                    await pause();
                  }
                }());
                return;
              }

              Timer(const Duration(milliseconds: 100), () {
                if (mounted && _player.playing && !_userInitiatedPlayback) {
                  unawaited(pause());
                }
              });
              return;
            }

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
                // No pausar si el usuario acaba de seleccionar una canción
                if (mounted && _player.playing && !_userInitiatedPlayback) {
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
        },
        onError: (Object e, StackTrace stackTrace) {
          // print('❌ Error en playbackStream: $e');
          // Intentar recuperar saltando a la siguiente canción si es posible
          if (mounted && _mediaQueue.isNotEmpty) {
            skipToNext();
          }
        },
      );

      _currentIndexSubscription = _player.currentIndexStream.listen((index) {
        if (_initializing) return;
        if (_deferredStreamingQueueMode) {
          if (_mediaQueue.isEmpty) return;
          final effectiveIndex = _deferredStreamingQueueIndex.clamp(
            0,
            _mediaQueue.length - 1,
          );
          _updateCurrentMediaItem(effectiveIndex);
          return;
        }
        if (index != null && index < _mediaQueue.length) {
          // Precargar carátula inmediatamente para transiciones automáticas
          _preloadArtworkForIndex(index);
          _preloadNextStreamingArtworks(index);
          _updateCurrentMediaItem(index);
          if (_streamRadioEnabled &&
              _isStreamingMediaItem(_mediaQueue[index])) {
            unawaited(_ensureStreamingRadioQueue());
          }
        }
      });

      _durationSubscription = _durationStream.listen((duration) {
        final index = _deferredStreamingQueueMode
            ? _deferredStreamingQueueIndex
            : _player.currentIndex;
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
            if (currentItem != null) {
              _startTrackingPlaytime(_currentTrackingId!, currentItem);
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
      _positionSubscription = _positionStream.listen((pos) {
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
        final restoreEnabled =
            _prefs?.getBool(_kPrefRestoreLastSessionOnStartup) ?? true;
        if (restoreEnabled) {
          unawaited(_attemptRestoreFromPrefs());
        } else {
          _restoredSession = true;
        }
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
    await _audioInterruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();

    // Cancelar timer de notificaciones
    _notificationUpdateTimer?.cancel();

    _currentIndexSubscription = null;
    _playbackEventSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _processingStateSubscription = null;
    _positionSubscription = null;
    _audioInterruptionSubscription = null;
    _becomingNoisySubscription = null;

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
  void _startTrackingPlaytime(String trackId, MediaItem currentItem) {
    final songPath = currentItem.extras?['data']?.toString().trim();
    final isStreaming = _isStreamingMediaItem(currentItem);
    final recentKey = (songPath != null && songPath.isNotEmpty)
        ? songPath
        : currentItem.id;
    if (recentKey.isEmpty) return;

    _trackingTimer?.cancel();
    final remainingTime = const Duration(seconds: 10) - _elapsedTrackingTime;

    if (remainingTime <= Duration.zero) {
      // Ya pasó el tiempo, guardar inmediatamente
      if (_currentTrackingId == trackId && !_hasBeenTracked) {
        _hasBeenTracked = true;
        unawaited(_saveRecentFromMediaItem(currentItem, recentKey));
        if (!isStreaming) {
          unawaited(_updateMostPlayedAsync(recentKey));
        }
      }
    } else {
      _trackingTimer = Timer(remainingTime, () {
        if (_currentTrackingId == trackId && !_hasBeenTracked) {
          _hasBeenTracked = true;
          // Actualizar recientes de forma asíncrona
          unawaited(_saveRecentFromMediaItem(currentItem, recentKey));
          // Actualizar más reproducidas de forma asíncrona
          if (!isStreaming) {
            unawaited(_updateMostPlayedAsync(recentKey));
          }
        }
      });
    }
  }

  Future<void> _saveRecentFromMediaItem(
    MediaItem item,
    String recentKey,
  ) async {
    if (_isStreamingMediaItem(item)) {
      final extras = item.extras;
      final videoId = extras?['videoId']?.toString().trim();
      final artUri =
          extras?['displayArtUri']?.toString().trim().isNotEmpty == true
          ? extras!['displayArtUri'].toString().trim()
          : item.artUri?.toString();
      await RecentsDB().addRecentPath(
        recentKey,
        title: item.title,
        artist: item.artist,
        videoId: (videoId != null && videoId.isNotEmpty) ? videoId : null,
        artUri: (artUri != null && artUri.trim().isNotEmpty)
            ? artUri.trim()
            : null,
        durationMs: item.duration?.inMilliseconds,
      );
      return;
    }

    await RecentsDB().addRecentPath(recentKey);
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
    if (_isPreloadingNext) return;

    final duration = _player.duration;
    final position = _player.position;
    final currentIndex = _player.currentIndex;

    if (duration == null || currentIndex == null || _currentSongList.isEmpty) {
      return;
    }

    // Si quedan menos de 18 segundos, precargar la siguiente canción
    final remainingTime = duration - position;
    if (remainingTime.inSeconds <= 18 && remainingTime.inSeconds > 15) {
      _isPreloadingNext = true;

      unawaited(() async {
        try {
          final nextIndex = currentIndex + 1;
          if (nextIndex < _currentSongList.length) {
            final nextSong = _currentSongList[nextIndex];

            // Verificar si ya está en caché (memoria o archivo)
            bool isAlreadyCached = false;
            if (_artworkCache.containsKey(nextSong.data)) {
              isAlreadyCached = true;
            } else {
              // Verificar también en caché temporal (archivos)
              try {
                _tempDirPath ??= (await getTemporaryDirectory()).path;
                final cachedFile = File(
                  '$_tempDirPath/artwork_${nextSong.id}.jpg',
                );
                if (await cachedFile.exists()) {
                  // Agregar al caché en memoria para acceso inmediato
                  _artworkCache[nextSong.data] = Uri.file(cachedFile.path);
                  isAlreadyCached =
                      true; // No need to load if found in file cache
                }
              } catch (e) {
                // Error silencioso
              }
            }

            // Solo precargar si no está ya en caché
            if (!isAlreadyCached) {
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
            }
          }
        } finally {
          // Permitir nueva precarga después de 5 segundos para evitar repeticiones en el mismo rango
          await Future.delayed(const Duration(seconds: 5));
          _isPreloadingNext = false;
        }
      }());
    }
  }

  Future<bool> isFavorite(String songId) async {
    return await FavoritesDB().isFavorite(songId);
  }

  String _favoritePathForMediaItem(MediaItem item) {
    final dataPath = item.extras?['data']?.toString().trim();
    if (dataPath != null && dataPath.isNotEmpty) {
      return dataPath;
    }
    final videoId = item.extras?['videoId']?.toString().trim();
    if (videoId != null && videoId.isNotEmpty) {
      return 'yt:$videoId';
    }
    return item.id.trim();
  }

  String? _streamingVideoIdForMediaItem(MediaItem item) {
    final rawVideoId = item.extras?['videoId']?.toString().trim();
    if (rawVideoId != null && rawVideoId.isNotEmpty) {
      return rawVideoId;
    }
    if (item.id.startsWith('yt:')) {
      final id = item.id.replaceFirst('yt:', '').trim();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  String? _extractVideoIdFromFavoritePath(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return null;

    if (path.startsWith('yt:')) {
      final id = path.substring(3).trim();
      return id.isEmpty ? null : id;
    }

    final uri = Uri.tryParse(path);
    if (uri != null) {
      final queryVideoId = uri.queryParameters['v']?.trim();
      if (queryVideoId != null && queryVideoId.isNotEmpty) {
        return queryVideoId;
      }
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        final shortId = uri.pathSegments.first.trim();
        if (shortId.isNotEmpty) {
          return shortId;
        }
      }
    }

    final idLike = RegExp(r'^[a-zA-Z0-9_-]{11}$');
    if (idLike.hasMatch(path)) {
      return path;
    }

    return null;
  }

  Future<String?> _findExistingFavoriteStorageKey(MediaItem item) async {
    final canonicalPath = _favoritePathForMediaItem(item);
    if (canonicalPath.isNotEmpty &&
        await FavoritesDB().isFavorite(canonicalPath)) {
      return canonicalPath;
    }

    final videoId = _streamingVideoIdForMediaItem(item);
    if (videoId == null || videoId.isEmpty) return null;

    final favoritePaths = await FavoritesDB().getFavoritePaths();
    for (final raw in favoritePaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (path == 'yt:$videoId' || path == videoId) {
        return path;
      }
    }

    for (final raw in favoritePaths) {
      final path = raw.trim();
      if (path.isEmpty) continue;

      final meta = await FavoritesDB().getFavoriteMeta(path);
      final metaVideoId = meta?['videoId']?.toString().trim();
      if (metaVideoId != null &&
          metaVideoId.isNotEmpty &&
          metaVideoId == videoId) {
        return path;
      }

      final extractedVideoId = _extractVideoIdFromFavoritePath(path);
      if (extractedVideoId != null && extractedVideoId == videoId) {
        return path;
      }
    }

    return null;
  }

  Future<void> _syncFavoriteFlagForItem(
    MediaItem item, {
    bool notifyPlaybackState = true,
  }) async {
    final favoriteKey = await _findExistingFavoriteStorageKey(item);
    if (favoriteKey != null) {
      _favoriteIds.add(item.id);
    } else {
      _favoriteIds.remove(item.id);
    }
    if (notifyPlaybackState) {
      // Refresca el control custom de favorito en la notificación.
      playbackState.add(_transformPlaybackEvent(_player.playbackEvent));
    }
  }

  /// Transform a just_audio event into an audio_service state.
  /// Sigue exactamente el patrón de la documentación oficial de audio_service
  PlaybackState _transformPlaybackEvent(PlaybackEvent event) {
    // Sincronizar el estado del shuffle con el notifier
    _syncShuffleState();

    final currentMediaItem = mediaItem.value;
    final isFav =
        currentMediaItem != null && _favoriteIds.contains(currentMediaItem.id);

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

    // En streaming diferido no dependemos del shuffle nativo del player.
    final bool shuffleEnabled = _deferredStreamingQueueMode
        ? isShuffleNotifier.value
        : _player.shuffleModeEnabled;
    final AudioServiceShuffleMode shuffleMode = shuffleEnabled
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none;

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl(
          androidIcon: isFav
              ? 'drawable/ic_isfavorite'
              : 'drawable/ic_favorite',
          label: 'Favorito',
          action: MediaAction.custom,
          customAction: CustomMediaAction(name: 'favorite'),
        ),
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
      queueIndex: _deferredStreamingQueueMode
          ? _deferredStreamingQueueIndex
          : event.currentIndex,
      repeatMode: repeatMode,
      shuffleMode: shuffleMode,
    );
  }

  /// Actualiza solo el MediaItem cuando cambia el índice siguiendo las mejores prácticas de audio_service
  Future<void> _updateCurrentMediaItem(int index) async {
    if (index < 0 || index >= _mediaQueue.length) return;

    var currentMediaItem = _mediaQueue[index];
    final songPath = currentMediaItem.extras?['data']?.toString().trim();
    unawaited(_syncFavoriteFlagForItem(currentMediaItem));

    final songId = currentMediaItem.extras?['songId'] as int?;
    final currentSongId = currentMediaItem.id;

    // Tracking de tiempo de escucha para local y streaming.
    if (currentMediaItem.id.isNotEmpty &&
        currentMediaItem.id != _currentTrackingId) {
      _resetTracking();
      _currentTrackingId = currentMediaItem.id;
      _trackingStartTime = DateTime.now();
      _startTrackingPlaytime(currentMediaItem.id, currentMediaItem);
    }

    if (_isStreamingMediaItem(currentMediaItem)) {
      mediaItem.add(currentMediaItem);
      unawaited(
        _updateCurrentStreamingArtwork(
          index: index,
          currentMediaItem: currentMediaItem,
          currentSongId: currentSongId,
        ),
      );
      return;
    }

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

    // Verificar si tenemos carátula inmediata en caché
    if (songPath != null &&
        songId != null &&
        _artworkCache.containsKey(songPath)) {
      final immediateArtUri = _artworkCache[songPath];
      if (immediateArtUri != null) {
        // print('⚡ Carátula encontrada en caché de memoria para: ${currentMediaItem.title}');

        // Verificar que el archivo existe de forma asíncrona
        final file = File(immediateArtUri.toFilePath());
        if (await file.exists()) {
          // print('✅ Archivo de carátula existe: ${file.path}');

          // Verificar que el archivo no esté vacío
          final fileSize = await file.length();
          if (fileSize > 0) {
            // print('✅ Archivo de carátula válido (${fileSize} bytes)');

            // Asegurar que el URI esté correctamente formateado
            final validUri = Uri.file(file.path);
            final finalMediaItem = currentMediaItem.copyWith(artUri: validUri);

            if (index < _mediaQueue.length) {
              _mediaQueue[index] = finalMediaItem;
            }

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
    if (songPath != null &&
        songId != null &&
        !_artworkCache.containsKey(songPath)) {
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
              final finalMediaItem = currentMediaItem.copyWith(
                artUri: validUri,
              );
              if (index < _mediaQueue.length) {
                _mediaQueue[index] = finalMediaItem;
              }
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
        final artUri = await getOrCacheArtwork(
          songId,
          songPath,
        ).timeout(const Duration(milliseconds: 2000));

        // Verificar que aún estamos en la misma canción
        if (_lastProcessedSongId == currentSongId &&
            mounted &&
            _player.currentIndex == index) {
          if (artUri != null) {
            // Asegurar que el URI esté correctamente formateado
            final validUri = Uri.file(artUri.toFilePath());
            final updatedMediaItem = _mediaQueue[index].copyWith(
              artUri: validUri,
            );
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
  List<MediaItem> _createMediaItemsWithoutArtwork(List<SongModel> songs) {
    final mediaItems = <MediaItem>[];

    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;

      mediaItems.add(
        MediaItem(
          id: song.data,
          album: song.displayAlbum,
          title: song.displayTitle,
          artist: song.displayArtist,
          duration: dur,
          artUri: null,
          extras: {
            'songId': song.id,
            'albumId': song.albumId,
            'data': song.data,
            'queueIndex': i,
          },
        ),
      );
    }

    return mediaItems;
  }

  Future<void> _loadArtworksInBackground(
    List<SongModel> songs, {
    int? priorityIndex,
    int? requestVersion,
  }) async {
    if (requestVersion != null && requestVersion != _loadVersion) {
      return;
    }

    final Set<int> indicesToLoad = {};

    if (priorityIndex != null &&
        priorityIndex >= 0 &&
        priorityIndex < songs.length) {
      indicesToLoad.add(priorityIndex);
    }

    for (int i = 0; i < 3 && i < songs.length; i++) {
      indicesToLoad.add(i);
    }

    if (indicesToLoad.isEmpty) return;

    await Future.wait(
      indicesToLoad.map((i) async {
        if (requestVersion != null && requestVersion != _loadVersion) return;
        if (i < 0 || i >= songs.length) return;
        final song = songs[i];
        try {
          final artUri = await getOrCacheArtwork(
            song.id,
            song.data,
          ).timeout(const Duration(milliseconds: 600));

          if (requestVersion != null && requestVersion != _loadVersion) return;
          if (artUri != null && i < _mediaQueue.length) {
            final validUri = Uri.file(artUri.toFilePath());
            _mediaQueue[i] = _mediaQueue[i].copyWith(artUri: validUri);
          }
        } catch (_) {}
      }),
    );

    if (requestVersion != null && requestVersion != _loadVersion) {
      return;
    }

    if (_mediaQueue.isNotEmpty) {
      queue.add(List<MediaItem>.from(_mediaQueue));
    }
  }

  /*
  Future<List<MediaItem>> _createMediaItemsWithArtwork(
    List<SongModel> songs, {
    int? priorityIndex,
  }) async {
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
          album: song.displayAlbum,
          title: song.displayTitle,
          artist: song.displayArtist,
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
    if (priorityIndex != null &&
        priorityIndex >= 0 &&
        priorityIndex < songs.length) {
      indicesToLoad.add(priorityIndex);
    }

    // Agregar las primeras 3 canciones si no están ya incluidas
    for (int i = 0; i < 3 && i < songs.length; i++) {
      indicesToLoad.add(i);
    }

    // Cargar carátulas para las canciones prioritarias en paralelo
    if (indicesToLoad.isNotEmpty) {
      await Future.wait(
        indicesToLoad.map((i) async {
          if (i < 0 || i >= songs.length) return;
          final song = songs[i];
          try {
            final artUri = await getOrCacheArtwork(
              song.id,
              song.data,
            ).timeout(const Duration(milliseconds: 600));

            if (artUri != null && i < mediaItems.length) {
              final validUri = Uri.file(artUri.toFilePath());
              mediaItems[i] = mediaItems[i].copyWith(artUri: validUri);
            }
          } catch (_) {
            // Ignorar errores de carga individual
          }
        }),
      );
    }
    // print('✅ MediaItems creados con carátulas: ${mediaItems.where((m) => m.artUri != null).length}/${mediaItems.length}');

    return mediaItems;
  }
  */

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
    _deferredStreamingQueueMode = false;
    _deferredStreamingQueueIndex = 0;

    // Obtener la canción objetivo antes de filtrar para poder recalcular el índice
    final String? targetSongPath =
        (initialIndex >= 0 && initialIndex < songs.length)
        ? songs[initialIndex].data
        : null;

    // Filtrar canciones que ya no existen en disco para evitar ENOENT (Optimizado)
    List<SongModel> validSongs;
    if (songs.length > 100) {
      // Para listas grandes, asumimos que existen para evitar miles de operaciones de E/S bloqueantes
      // Solo verificamos la canción objetivo
      validSongs = songs;
      if (initialIndex >= 0 && initialIndex < songs.length) {
        try {
          if (!(await File(songs[initialIndex].data).exists())) {
            // Si la elegida no existe, usamos la lista tal cual y el reproductor manejará el error
          }
        } catch (_) {}
      }
    } else {
      // Para listas pequeñas, el filtrado paralelo es eficiente
      final exists = await Future.wait(
        songs.map((s) => File(s.data).exists().catchError((_) => false)),
      );
      validSongs = [];
      for (int i = 0; i < songs.length; i++) {
        if (exists[i]) validSongs.add(songs[i]);
      }
    }

    // Recalcular el índice inicial para apuntar a la canción correcta en validSongs
    if (targetSongPath != null &&
        validSongs.isNotEmpty &&
        validSongs.length != songs.length) {
      final newIndex = validSongs.indexWhere((s) => s.data == targetSongPath);
      if (newIndex != -1) {
        initialIndex = newIndex;
      } else {
        initialIndex = 0;
      }
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

    // Al cargar cola local, desactivar cualquier estado de radio streaming.
    _resetStreamingSessionState(clearQueuedVideos: true);

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

    // 1. Crear MediaItems primero (sin carátulas para no bloquear UI)
    _mediaQueue.clear();
    final mediaItems = _createMediaItemsWithoutArtwork(validSongs);
    _mediaQueue.addAll(mediaItems);
    queue.add(List<MediaItem>.from(_mediaQueue));

    // Cargar carátulas en background sin bloquear
    _loadArtworksInBackground(
      validSongs,
      priorityIndex: initialIndex,
      requestVersion: currentVersion,
    );
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
            unawaited(_syncFavoriteFlagForItem(finalSelectedItem));
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
        unawaited(
          _preloadAllArtworksInBackground(
            validSongs,
            requestVersion: currentVersion,
          ),
        );
      } catch (e) {
        // Si falla, intentar con una sola canción
        try {
          // No esperar la limpieza de DB para no bloquear la recuperación
          unawaited(SongsIndexDB().cleanNonExistentFiles());
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
          if (currentVersion != _loadVersion) return;
          await preloadArtworks(songs.take(5).toList());
          if (currentVersion != _loadVersion) return;
        } catch (e) {
          // Error silencioso
        }
      }());
    }
  }

  Future<void> playSingleStream({
    required String streamUrl,
    required MediaItem item,
    Duration initialPosition = Duration.zero,
    bool autoPlay = true,
  }) async {
    if (!_isInitialized) {
      await _init();
    }

    _loadVersion++;
    _initializing = true;
    initializingNotifier.value = true;
    isQueueTransitioning.value = true;

    try {
      final requestedRadioMode = item.extras?['radioMode'] != false;
      final rawSeedVideoId = item.extras?['videoId']?.toString().trim();
      final seedVideoId = (rawSeedVideoId != null && rawSeedVideoId.isNotEmpty)
          ? rawSeedVideoId
          : item.id.replaceFirst('yt:', '').trim();
      final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
        preferred: item.extras?['displayArtUri']?.toString(),
        artUri: item.artUri,
        videoId: seedVideoId,
      );
      final normalizedExtras = <String, dynamic>{
        ...?item.extras,
        'isStreaming': true,
        'radioMode': requestedRadioMode,
        'queueIndex': 0,
        'videoId': seedVideoId,
        'displayArtUri': resolvedDisplayArtUri,
      };
      var streamItem = item.copyWith(
        artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
        extras: normalizedExtras,
      );

      _resetStreamingSessionState(clearQueuedVideos: true);
      // Asignar DESPUÉS del reset para que no se sobreescriban
      _deferredStreamingQueueMode = requestedRadioMode;
      _deferredStreamingQueueIndex = 0;
      _streamRadioEnabled = requestedRadioMode;
      if (seedVideoId.isNotEmpty) {
        _streamRadioSeedVideoId = seedVideoId;
        _streamQueuedVideoIds.add(seedVideoId);
      }

      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();
      _preloadDebounceTimer?.cancel();
      _isPreloadingNext = false;
      _resetTracking();

      _currentSongList.clear();
      _originalSongList = null;

      _mediaQueue
        ..clear()
        ..add(streamItem);
      _ensureDeferredShuffleOrder(currentIndex: 0);
      queue.add(List<MediaItem>.from(_mediaQueue));
      mediaItem.add(streamItem);
      unawaited(_syncFavoriteFlagForItem(streamItem));
      unawaited(
        _updateCurrentStreamingArtwork(
          index: 0,
          currentMediaItem: streamItem,
          currentSongId: streamItem.id,
        ),
      );

      // ignore: deprecated_member_use
      _concat = ConcatenatingAudioSource(
        children: [AudioSource.uri(Uri.parse(streamUrl))],
      );

      await _player
          .setAudioSource(
            _concat!,
            initialIndex: 0,
            initialPosition: initialPosition,
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Timeout al cargar stream de audio');
            },
          );

      // El stream ya está disponible en el reproductor: apagar loader global.
      playLoadingNotifier.value = false;

      playbackState.add(
        playbackState.value.copyWith(
          queueIndex: 0,
          updatePosition: initialPosition,
        ),
      );

      unawaited(() async {
        try {
          await _prefs?.setStringList(_kPrefQueuePaths, const []);
          await _prefs?.setInt(_kPrefQueueIndex, 0);
          await _prefs?.setInt(
            _kPrefSongPositionSec,
            initialPosition.inSeconds,
          );
        } catch (_) {}
      }());

      _initializing = false;
      initializingNotifier.value = false;
      isQueueTransitioning.value = false;

      if (_streamRadioEnabled) {
        await _ensureStreamingRadioQueue(force: true);
      }

      if (autoPlay) {
        await play();
      }
    } finally {
      if (_initializing) {
        _initializing = false;
        initializingNotifier.value = false;
        isQueueTransitioning.value = false;
      }
    }
  }

  bool _isStreamingMediaItem(MediaItem item) {
    if (item.extras?['isStreaming'] == true) return true;
    return item.id.startsWith('yt:') || item.id.startsWith('yt_stream_');
  }

  String? _fallbackStreamingDisplayArtUri(String? videoId) {
    final id = videoId?.trim();
    if (id == null || id.isEmpty) return null;
    return 'https://i.ytimg.com/vi/$id/maxresdefault.jpg';
  }

  String? _toHighestQualityYtThumb(String? url, String? videoId) {
    final raw = url?.trim();
    if (raw == null || raw.isEmpty) {
      return _fallbackStreamingDisplayArtUri(videoId);
    }

    final lower = raw.toLowerCase();

    // Mantener la fuente original de YT Music (googleusercontent) para
    // preservar el encuadre cuadrado consistente con overlay.
    if (lower.contains('lh3.googleusercontent.com') ||
        lower.contains('googleusercontent.com')) {
      return raw;
    }

    // Para thumbnails de video de YouTube, respetar URL original para evitar
    // introducir franjas laterales en algunos contenidos.
    return raw;
  }

  String? _resolveStreamingDisplayArtUri({
    String? preferred,
    Uri? artUri,
    String? videoId,
  }) {
    final p = preferred?.trim();
    if (p != null && p.isNotEmpty) {
      return _toHighestQualityYtThumb(p, videoId);
    }
    final a = artUri?.toString().trim();
    if (a != null && a.isNotEmpty) {
      return _toHighestQualityYtThumb(a, videoId);
    }
    return _fallbackStreamingDisplayArtUri(videoId);
  }

  void _resetStreamingSessionState({bool clearQueuedVideos = false}) {
    _streamSessionVersion++;
    _artworkGeneration++; // Cancelar descargas de carátulas en vuelo.
    _activeArtworkDownloads = 0;
    _streamRadioEnabled = false;
    _streamRadioInitialBatchLoaded = false;
    _streamRadioSeedVideoId = null;
    _streamRadioContinuationParams = null;
    _streamRadioAppendInProgress = false;
    _deferredStreamingQueueMode = false;
    _deferredStreamingQueueIndex = 0;
    _deferredShuffleOrder = const <int>[];
    _deferredShuffleCursor = 0;
    _streamArtworkPreloadTasks.clear();
    _streamUrlPrefetchTasks.clear();
    if (clearQueuedVideos) {
      _streamQueuedVideoIds.clear();
      _streamArtworkFileCache.clear();
    }
  }

  Future<bool> _resolveAndPlayDeferredStreamingIndex(
    int targetIndex, {
    bool playAfterResolve = false,
    int? expectedGeneration,
  }) async {
    if (!_deferredStreamingQueueMode) return false;
    if (targetIndex < 0 || targetIndex >= _mediaQueue.length) return false;

    // Capturar la generación actual. Si el usuario salta de nuevo antes de que
    // terminemos, _resolveGeneration habrá cambiado y abortamos gracefully.
    // Cuando viene de un skip manual, expectedGeneration ya fue incrementada
    // antes para cancelar de inmediato cualquier carga en curso.
    if (expectedGeneration == null) {
      _resolveGeneration++;
    } else if (expectedGeneration != _resolveGeneration) {
      return false;
    }
    _artworkGeneration++;
    final myGeneration = _resolveGeneration;

    bool isSuperseded() =>
        myGeneration != _resolveGeneration || !_deferredStreamingQueueMode;

    final currentItem = _mediaQueue[targetIndex];

    // 1) Publicar metadatos de inmediato para que la UI cambie instantáneamente.
    _deferredStreamingQueueIndex = targetIndex;
    _ensureDeferredShuffleOrder(currentIndex: targetIndex);
    mediaItem.add(currentItem);
    unawaited(_syncFavoriteFlagForItem(currentItem));
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: targetIndex,
        processingState: AudioProcessingState.loading,
      ),
    );

    unawaited(
      _updateCurrentStreamingArtwork(
        index: targetIndex,
        currentMediaItem: currentItem,
        currentSongId: currentItem.id,
        trackGeneration: true,
      ),
    );

    // 2) Resolver stream URL y cargar audio después.
    final rawVideoId = currentItem.extras?['videoId']?.toString().trim();
    final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : currentItem.id.replaceFirst('yt:', '').trim();
    if (videoId.isEmpty) return false;

    var streamUrl = currentItem.extras?['streamUrl']?.toString().trim();
    if (streamUrl == null || streamUrl.isEmpty) {
      // Reusar prefetch en curso si lo hay, para no lanzar una petición de red duplicada.
      final inFlight = _streamUrlPrefetchTasks[videoId];
      if (inFlight != null) {
        streamUrl = await inFlight.timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
      }
      // Si el prefetch no tenía nada o no había empezado, resolver ahora.
      if (streamUrl == null || streamUrl.isEmpty) {
        streamUrl = await StreamService.getBestAudioUrl(
          videoId,
        ).timeout(const Duration(seconds: 5), onTimeout: () => null);
      }
    }

    // Verificar que no hayamos sido superados mientras esperábamos la URL.
    if (isSuperseded()) return false;

    if (streamUrl == null || streamUrl.isEmpty) {
      playLoadingNotifier.value = false;
      return false;
    }

    final updatedExtras = <String, dynamic>{
      ...?currentItem.extras,
      'streamUrl': streamUrl,
      'queueIndex': targetIndex,
      'videoId': videoId,
      'isStreaming': true,
      'radioMode': false,
    };
    final updatedItem = currentItem.copyWith(extras: updatedExtras);
    _mediaQueue[targetIndex] = updatedItem;
    queue.add(List<MediaItem>.from(_mediaQueue));

    mediaItem.add(updatedItem);

    try {
      // Verificar una última vez antes de cargar el audio en el player.
      if (isSuperseded()) return false;
      await _player
          .setUrl(streamUrl, initialPosition: Duration.zero)
          .timeout(const Duration(seconds: 6));
    } on PlayerInterruptedException {
      // El player fue interrumpido por un skip más reciente — es esperado, ignorar.
      return false;
    } catch (_) {
      // Timeout, error de red u otro fallo al cargar el stream — no relanzar
      // porque esta función se llama con unawaited y causaría una excepción no capturada.
      return false;
    }

    // Verificar nuevamente después del setUrl.
    if (isSuperseded()) return false;

    // En cola streaming diferida, liberar loader después de enlazar el stream
    // para evitar que se apague antes de que PlayerScreen llegue a pintarlo.
    if (playLoadingNotifier.value) {
      Timer(const Duration(milliseconds: 180), () {
        playLoadingNotifier.value = false;
      });
    }

    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: targetIndex,
        updatePosition: Duration.zero,
      ),
    );

    unawaited(
      _updateCurrentStreamingArtwork(
        index: targetIndex,
        currentMediaItem: updatedItem,
        currentSongId: updatedItem.id,
      ),
    );

    if (playAfterResolve) {
      await _player.play();
    }

    // Prefetch ligero: solo resuelve URL del siguiente item en background.
    unawaited(_prefetchDeferredNextStreamUrl(targetIndex));

    return true;
  }

  Future<void> _prefetchDeferredNextStreamUrl(int currentIndex) async {
    if (!_deferredStreamingQueueMode) return;
    final myGeneration = _resolveGeneration;
    // Prefetchear las 2 siguientes canciones para reducir esperas al saltar rápido.
    for (int offset = 1; offset <= 2; offset++) {
      // Si el usuario saltó de nuevo, abortar prefetch.
      if (myGeneration != _resolveGeneration) return;
      final nextIndex = currentIndex + offset;
      if (nextIndex < 0 || nextIndex >= _mediaQueue.length) break;
      unawaited(_prefetchSingleDeferredStreamUrl(nextIndex, myGeneration));
    }
  }

  Future<void> _prefetchSingleDeferredStreamUrl(
    int nextIndex,
    int generation,
  ) async {
    if (!_deferredStreamingQueueMode) return;
    if (nextIndex < 0 || nextIndex >= _mediaQueue.length) return;
    if (generation != _resolveGeneration) return;

    final nextItem = _mediaQueue[nextIndex];
    final existingUrl = nextItem.extras?['streamUrl']?.toString().trim();
    if (existingUrl != null && existingUrl.isNotEmpty) return;

    final rawVideoId = nextItem.extras?['videoId']?.toString().trim();
    final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : nextItem.id.replaceFirst('yt:', '').trim();
    if (videoId.isEmpty) return;

    if (_streamUrlPrefetchTasks.containsKey(videoId)) return;

    final task = StreamService.getBestAudioUrl(
      videoId,
    ).timeout(const Duration(seconds: 8), onTimeout: () => null);
    _streamUrlPrefetchTasks[videoId] = task;

    try {
      final prefetchedUrl = await task;
      // Verificar que la generación no cambió mientras esperábamos.
      if (generation != _resolveGeneration) return;
      if (prefetchedUrl == null || prefetchedUrl.isEmpty) return;
      if (nextIndex < 0 || nextIndex >= _mediaQueue.length) return;

      final current = _mediaQueue[nextIndex];
      if (current.id != nextItem.id) return;

      final updatedExtras = <String, dynamic>{
        ...?current.extras,
        'streamUrl': prefetchedUrl,
      };
      _mediaQueue[nextIndex] = current.copyWith(extras: updatedExtras);
      queue.add(List<MediaItem>.from(_mediaQueue));
    } catch (_) {
      // Error silencioso para no afectar reproducción.
    } finally {
      _streamUrlPrefetchTasks.remove(videoId);
    }
  }

  void _ensureDeferredShuffleOrder({int? currentIndex}) {
    if (!_deferredStreamingQueueMode || !isShuffleNotifier.value) {
      _deferredShuffleOrder = const <int>[];
      _deferredShuffleCursor = 0;
      return;
    }
    if (_mediaQueue.isEmpty) {
      _deferredShuffleOrder = const <int>[];
      _deferredShuffleCursor = 0;
      return;
    }

    final fallback = _deferredStreamingQueueIndex.clamp(
      0,
      _mediaQueue.length - 1,
    );
    final effectiveCurrent = (currentIndex ?? fallback).clamp(
      0,
      _mediaQueue.length - 1,
    );
    final needsRebuild =
        _deferredShuffleOrder.length != _mediaQueue.length ||
        !_deferredShuffleOrder.contains(effectiveCurrent);

    if (needsRebuild) {
      final rest = List<int>.generate(_mediaQueue.length, (i) => i)
        ..remove(effectiveCurrent)
        ..shuffle(_random);
      _deferredShuffleOrder = <int>[effectiveCurrent, ...rest];
      _deferredShuffleCursor = 0;
      return;
    }

    final currentPos = _deferredShuffleOrder.indexOf(effectiveCurrent);
    if (currentPos >= 0) {
      _deferredShuffleCursor = currentPos;
    }
  }

  int? _nextDeferredQueueIndex() {
    if (_mediaQueue.isEmpty) return null;
    final current = _deferredStreamingQueueIndex.clamp(
      0,
      _mediaQueue.length - 1,
    );

    if (!isShuffleNotifier.value) {
      if (current < _mediaQueue.length - 1) return current + 1;
      if (_player.loopMode == LoopMode.all && _mediaQueue.isNotEmpty) return 0;
      return null;
    }

    _ensureDeferredShuffleOrder(currentIndex: current);
    if (_deferredShuffleOrder.isEmpty) return null;

    if (_deferredShuffleCursor < _deferredShuffleOrder.length - 1) {
      _deferredShuffleCursor++;
      return _deferredShuffleOrder[_deferredShuffleCursor];
    }

    if (_player.loopMode != LoopMode.all) return null;

    final currentIndex = _deferredShuffleOrder[_deferredShuffleCursor];
    final rest = List<int>.generate(_mediaQueue.length, (i) => i)
      ..remove(currentIndex)
      ..shuffle(_random);
    _deferredShuffleOrder = <int>[currentIndex, ...rest];
    _deferredShuffleCursor = _deferredShuffleOrder.length > 1 ? 1 : 0;

    if (_deferredShuffleOrder.length > 1) {
      return _deferredShuffleOrder[_deferredShuffleCursor];
    }
    return null;
  }

  int? _previousDeferredQueueIndex() {
    if (_mediaQueue.isEmpty) return null;
    final current = _deferredStreamingQueueIndex.clamp(
      0,
      _mediaQueue.length - 1,
    );

    if (!isShuffleNotifier.value) {
      if (current > 0) return current - 1;
      return null;
    }

    _ensureDeferredShuffleOrder(currentIndex: current);
    if (_deferredShuffleOrder.isEmpty) return null;
    if (_deferredShuffleCursor > 0) {
      _deferredShuffleCursor--;
      return _deferredShuffleOrder[_deferredShuffleCursor];
    }
    return null;
  }

  void _preloadNextStreamingArtworks(int currentIndex) {
    if (_streamArtworkPrefetchCount <= 0) return;
    if (_mediaQueue.isEmpty) return;
    if (!_isStreamingMediaItem(_mediaQueue.first)) return;
    // No precargar si ya hay descargas activas al máximo — evitar saturar.
    if (_activeArtworkDownloads >= _maxConcurrentArtworkDownloads) return;

    for (int offset = 1; offset <= _streamArtworkPrefetchCount; offset++) {
      final idx = currentIndex + offset;
      if (idx < 0 || idx >= _mediaQueue.length) break;

      final item = _mediaQueue[idx];
      if (!_isStreamingMediaItem(item)) continue;

      final artUri = item.artUri;
      if (artUri == null) continue;
      final scheme = artUri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') continue;

      final rawVideoId = item.extras?['videoId']?.toString().trim();
      final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
          ? rawVideoId
          : item.id.replaceFirst('yt:', '').trim();
      if (videoId.isEmpty) continue;

      // Verificar si ya está cacheada — si no, no forzar descarga aquí.
      if (_streamArtworkFileCache.containsKey(videoId)) continue;

      unawaited(() async {
        final localUri = await _getOrCacheStreamingArtwork(videoId, artUri);
        if (localUri == null) return;
        if (!mounted || idx >= _mediaQueue.length) return;
        final current = _mediaQueue[idx];
        if (current.id != item.id) return;
        if (current.artUri == localUri) return;
      }());
    }
  }

  Future<void> _updateCurrentStreamingArtwork({
    required int index,
    required MediaItem currentMediaItem,
    required String currentSongId,
    bool trackGeneration = false,
  }) async {
    if (index < 0 || index >= _mediaQueue.length) return;
    final artUri = currentMediaItem.artUri;
    if (artUri == null) return;

    final scheme = artUri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return;

    final rawVideoId = currentMediaItem.extras?['videoId']?.toString().trim();
    final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : currentMediaItem.id.replaceFirst('yt:', '').trim();
    if (videoId.isEmpty) return;

    // Para notificación: usar versión local recortada cuando esté disponible.
    // Pasar la generación actual para que descargas obsoletas se cancelen.
    final localUri = await _getOrCacheStreamingArtwork(
      videoId,
      artUri,
      artworkGen: trackGeneration ? _artworkGeneration : null,
    );

    if (!mounted || index >= _mediaQueue.length) return;
    final current = _mediaQueue[index];
    if (current.id != currentSongId) return;
    var updated = current;
    if (localUri != null && current.artUri != localUri) {
      updated = current.copyWith(artUri: localUri);
      _mediaQueue[index] = updated;
    }
    if ((_player.currentIndex ?? -1) == index ||
        mediaItem.value?.id == updated.id) {
      mediaItem.add(updated);
    }
  }

  Future<Uri?> _getOrCacheStreamingArtwork(
    String videoId,
    Uri remoteUri, {
    int? artworkGen,
  }) async {
    // Función para verificar si esta operación fue superada por un skip más reciente.
    bool isStale() => artworkGen != null && artworkGen != _artworkGeneration;

    final cachedUri = _streamArtworkFileCache[videoId];
    if (cachedUri != null) {
      try {
        final file = File(cachedUri.toFilePath());
        if (await file.exists() && await file.length() > 0) {
          return cachedUri;
        }
      } catch (_) {
        _streamArtworkFileCache.remove(videoId);
      }
    }

    // Abortar si ya no es la canción actual.
    if (isStale()) return null;

    // Migración puntual desde cache legado (v1) a v3 recortado.
    try {
      final tempDir = await getTemporaryDirectory();
      final v3File = File('${tempDir.path}/yt_stream_art_v3_$videoId.jpg');
      if (await v3File.exists() && await v3File.length() > 0) {
        final uri = Uri.file(v3File.path);
        _streamArtworkFileCache[videoId] = uri;
        return uri;
      }

      if (isStale()) return null;

      final legacyFile = File('${tempDir.path}/yt_stream_art_$videoId.jpg');
      if (await legacyFile.exists() && await legacyFile.length() > 0) {
        final bytes = await legacyFile.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final square = _buildStreamingSquareCrop(
            image: decoded,
            imageUrl: remoteUri.toString(),
          );
          await v3File.writeAsBytes(
            img.encodeJpg(square, quality: 88),
            flush: false,
          );
          final uri = Uri.file(v3File.path);
          _streamArtworkFileCache[videoId] = uri;
          return uri;
        }
      }
    } catch (_) {}

    // Abortar antes de iniciar descarga de red si ya es obsoleta.
    if (isStale()) return null;

    final pending = _streamArtworkPreloadTasks[videoId];
    if (pending != null) {
      return await pending;
    }

    // Limitar descargas concurrentes para evitar saturar red e I/O.
    if (_activeArtworkDownloads >= _maxConcurrentArtworkDownloads) {
      return null;
    }

    _activeArtworkDownloads++;
    final future = _downloadStreamingArtworkToFile(
      videoId,
      remoteUri,
      artworkGen: artworkGen,
    );
    _streamArtworkPreloadTasks[videoId] = future;
    try {
      final result = await future;
      if (result != null) {
        _streamArtworkFileCache[videoId] = result;
        if (_streamArtworkFileCache.length > _streamArtworkCacheMaxEntries) {
          final firstKey = _streamArtworkFileCache.keys.first;
          _streamArtworkFileCache.remove(firstKey);
        }
      }
      return result;
    } finally {
      _activeArtworkDownloads--;
      _streamArtworkPreloadTasks.remove(videoId);
    }
  }

  img.Image _buildStreamingSquareCrop({
    required img.Image image,
    required String imageUrl,
  }) {
    final w = image.width;
    final h = image.height;
    if (w <= 0 || h <= 0) return image;

    final ratio = w / h;
    final isHqLike =
        imageUrl.contains('hqdefault') || imageUrl.contains('sddefault');

    // Forzar recorte físico: para horizontales aplicamos recorte vertical tipo preview.
    if (isHqLike || ratio > 1.1) {
      final contentHeight = (h * 0.75).round();
      final offsetY = (h - contentHeight) ~/ 2;
      final side = w < contentHeight ? w : contentHeight;
      final offsetX = (w - side) ~/ 2;
      return img.copyCrop(
        image,
        x: offsetX,
        y: offsetY,
        width: side,
        height: side,
      );
    }

    final side = w < h ? w : h;
    final offsetX = (w - side) ~/ 2;
    final offsetY = (h - side) ~/ 2;
    return img.copyCrop(
      image,
      x: offsetX,
      y: offsetY,
      width: side,
      height: side,
    );
  }

  Future<Uri?> _downloadStreamingArtworkToFile(
    String videoId,
    Uri remoteUri, {
    int? artworkGen,
  }) async {
    // Verificar si esta descarga sigue siendo relevante.
    bool isStale() => artworkGen != null && artworkGen != _artworkGeneration;

    HttpClient? client;
    try {
      if (isStale()) return null;

      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final request = await client.getUrl(remoteUri);
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      // Verificar antes de descargar bytes completos.
      if (isStale()) return null;

      final bytes = await consolidateHttpClientResponseBytes(response);
      if (bytes.isEmpty) return null;

      // Verificar antes de procesamiento de imagen (CPU-intensivo).
      if (isStale()) return null;

      List<int> outputBytes = bytes;
      try {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          // Último check antes de la operación más costosa (crop + encode).
          if (isStale()) return null;
          final square = _buildStreamingSquareCrop(
            image: decoded,
            imageUrl: remoteUri.toString(),
          );
          outputBytes = img.encodeJpg(square, quality: 88);
        }
      } catch (_) {
        outputBytes = bytes;
      }

      if (isStale()) return null;

      final tempDir = await getTemporaryDirectory();
      // v3 invalida archivos previos no recortados que Android pudo cachear.
      final file = File('${tempDir.path}/yt_stream_art_v3_$videoId.jpg');
      await file.writeAsBytes(outputBytes, flush: true);
      return Uri.file(file.path);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _resolveStreamingRadioTrack({
    required Map<String, dynamic> rawTrack,
    required int sessionVersion,
  }) async {
    final videoId = rawTrack['videoId']?.toString().trim();
    if (videoId == null || videoId.isEmpty) return null;
    if (sessionVersion != _streamSessionVersion) return null;

    final rawDuration = rawTrack['durationMs'];
    int? durationMs;
    if (rawDuration is int) {
      durationMs = rawDuration;
    } else if (rawDuration is String) {
      durationMs = int.tryParse(rawDuration);
    }

    final title = rawTrack['title']?.toString().trim();
    final artist = rawTrack['artist']?.toString().trim();
    final artUriRaw = rawTrack['thumbUrl']?.toString().trim();

    final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
      preferred: artUriRaw,
      artUri: (artUriRaw != null && artUriRaw.isNotEmpty)
          ? Uri.tryParse(artUriRaw)
          : null,
      videoId: videoId,
    );

    final item = MediaItem(
      id: 'yt:$videoId',
      title: (title != null && title.isNotEmpty) ? title : 'Unknown title',
      artist: (artist != null && artist.isNotEmpty) ? artist : null,
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
      extras: {
        'videoId': videoId,
        'isStreaming': true,
        'radioMode': true,
        'streamUrl': rawTrack['streamUrl']?.toString().trim(),
        'displayArtUri': resolvedDisplayArtUri,
      },
    );

    return {'videoId': videoId, 'item': item};
  }

  Future<void> _ensureStreamingRadioQueue({bool force = false}) async {
    if (!_streamRadioEnabled ||
        _streamRadioAppendInProgress ||
        _streamRadioInitialBatchLoaded) {
      return;
    }
    if (_mediaQueue.isEmpty || !_isStreamingMediaItem(_mediaQueue.first)) {
      return;
    }
    final int sessionVersion = _streamSessionVersion;
    final int currentIndex =
        (_deferredStreamingQueueMode
                ? _deferredStreamingQueueIndex
                : (_player.currentIndex ?? 0))
            .clamp(0, _mediaQueue.length - 1);
    final int remaining = (_mediaQueue.length - 1) - currentIndex;
    final int missingItems = _streamRadioFixedQueueSize - remaining;
    if (missingItems <= 0) {
      _streamRadioInitialBatchLoaded = true;
      return;
    }
    if (!force && remaining > _streamRadioPrefetchThreshold) return;

    final currentItem = _mediaQueue[currentIndex];
    final currentVideoId = currentItem.extras?['videoId']?.toString().trim();
    final seedVideoId = (currentVideoId != null && currentVideoId.isNotEmpty)
        ? currentVideoId
        : _streamRadioSeedVideoId;
    if (seedVideoId == null || seedVideoId.isEmpty) return;
    final continuationForRequest =
        (_streamRadioSeedVideoId == null ||
            _streamRadioSeedVideoId == seedVideoId)
        ? _streamRadioContinuationParams
        : null;
    _streamRadioSeedVideoId = seedVideoId;
    if (continuationForRequest == null) {
      _streamRadioContinuationParams = null;
    }

    _streamRadioAppendInProgress = true;
    // En modo radio fijo, hacemos un único intento de carga para esta sesión.
    var shouldLockRadioQueue = force;
    try {
      final requestLimit = missingItems + _streamRadioOverscanCount;
      final radioPayload = await yt_service.getWatchRadioTracks(
        videoId: seedVideoId,
        limit: requestLimit,
        additionalParamsNext: continuationForRequest,
      );
      if (sessionVersion != _streamSessionVersion) return;
      final nextParams = radioPayload['additionalParamsForNext']
          ?.toString()
          .trim();
      if (nextParams != null && nextParams.isNotEmpty) {
        _streamRadioContinuationParams = nextParams;
      }

      final rawTracks = radioPayload['tracks'];
      if (rawTracks is! List || rawTracks.isEmpty) {
        shouldLockRadioQueue = true;
        return;
      }

      final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
      final Set<String> scheduledVideoIds = <String>{};
      for (final rawTrack in rawTracks) {
        if (candidates.length >= missingItems) break;
        if (rawTrack is! Map) continue;

        final videoId = rawTrack['videoId']?.toString().trim();
        if (videoId == null || videoId.isEmpty) continue;
        if (_streamQueuedVideoIds.contains(videoId)) continue;
        if (!scheduledVideoIds.add(videoId)) continue;

        candidates.add(Map<String, dynamic>.from(rawTrack));
      }
      if (candidates.isEmpty) {
        shouldLockRadioQueue = true;
        return;
      }

      final resolvedCandidates = <Map<String, dynamic>>[];
      for (int i = 0; i < candidates.length; i++) {
        final resolved = await _resolveStreamingRadioTrack(
          rawTrack: candidates[i],
          sessionVersion: sessionVersion,
        );
        if (resolved == null) continue;
        resolvedCandidates.add(<String, dynamic>{'order': i, ...resolved});
      }

      if (resolvedCandidates.isEmpty) {
        shouldLockRadioQueue = true;
        return;
      }
      if (sessionVersion != _streamSessionVersion) return;

      resolvedCandidates.sort(
        (a, b) => (a['order'] as int).compareTo(b['order'] as int),
      );

      final batchItems = <MediaItem>[];
      for (final resolved in resolvedCandidates) {
        final videoId = resolved['videoId'] as String?;
        final item = resolved['item'] as MediaItem?;
        if (videoId == null ||
            videoId.isEmpty ||
            item == null ||
            !_streamQueuedVideoIds.add(videoId)) {
          continue;
        }
        batchItems.add(item);
      }

      if (batchItems.isNotEmpty) {
        await _appendResolvedStreamingTracks(
          items: batchItems,
          sessionVersion: sessionVersion,
        );
      }
      shouldLockRadioQueue = true;
    } catch (_) {
      // Mantener la reproducción estable ante errores de red/parsing.
    } finally {
      if (shouldLockRadioQueue && sessionVersion == _streamSessionVersion) {
        _streamRadioInitialBatchLoaded = true;
      }
      _streamRadioAppendInProgress = false;
    }
  }

  Future<void> _appendResolvedStreamingTracks({
    required List<MediaItem> items,
    required int sessionVersion,
  }) async {
    if (items.isEmpty) return;
    if (sessionVersion != _streamSessionVersion) return;
    if (_mediaQueue.isEmpty) return;
    if (!_isStreamingMediaItem(_mediaQueue.first)) return;

    final int baseIndex = _mediaQueue.length;
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final extras = <String, dynamic>{
        ...?item.extras,
        'queueIndex': baseIndex + i,
        'displayArtUri': _resolveStreamingDisplayArtUri(
          preferred: item.extras?['displayArtUri']?.toString(),
          artUri: item.artUri,
          videoId: item.extras?['videoId']?.toString(),
        ),
      };
      _mediaQueue.add(item.copyWith(extras: extras));
    }
    queue.add(List<MediaItem>.from(_mediaQueue));

    if (_deferredStreamingQueueMode) {
      // En modo diferido, resolver la URL del siguiente en background para
      // reducir espera en el próximo cambio sin cargar audio adicional.
      unawaited(_prefetchDeferredNextStreamUrl(_deferredStreamingQueueIndex));
    }

    // En streaming, precargar la carátula de la siguiente pista en caché
    // apenas se anexan nuevos elementos de radio.
    final currentIndex = _player.currentIndex;
    if (currentIndex != null && currentIndex >= 0) {
      _preloadNextStreamingArtworks(currentIndex);
    }
  }

  Future<Map<String, dynamic>> _startStreamingRadioFromCurrent({
    bool replaceQueue = true,
  }) async {
    if (_mediaQueue.isEmpty) {
      return {'ok': false, 'reason': 'empty_queue'};
    }

    final int currentIndex =
        (_deferredStreamingQueueMode
                ? _deferredStreamingQueueIndex
                : (_player.currentIndex ?? 0))
            .clamp(0, _mediaQueue.length - 1);
    final currentItem = _mediaQueue[currentIndex];
    if (!_isStreamingMediaItem(currentItem)) {
      return {'ok': false, 'reason': 'not_streaming'};
    }

    final rawVideoId = currentItem.extras?['videoId']?.toString().trim();
    final seedVideoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : (currentItem.id.startsWith('yt:')
              ? currentItem.id.replaceFirst('yt:', '').trim()
              : '');
    if (seedVideoId.isEmpty) {
      return {'ok': false, 'reason': 'missing_video_id'};
    }

    _streamSessionVersion++;
    _resolveGeneration++;
    _artworkGeneration++;
    _activeArtworkDownloads = 0;
    _streamRadioAppendInProgress = false;
    _streamRadioInitialBatchLoaded = false;
    _streamRadioEnabled = true;
    _streamRadioSeedVideoId = seedVideoId;
    _streamRadioContinuationParams = null;
    _streamArtworkPreloadTasks.clear();
    _streamUrlPrefetchTasks.clear();

    if (replaceQueue && currentIndex < _mediaQueue.length - 1) {
      _mediaQueue.removeRange(currentIndex + 1, _mediaQueue.length);
    }

    _deferredStreamingQueueMode = true;
    _deferredStreamingQueueIndex = currentIndex;

    _streamQueuedVideoIds.clear();
    for (int i = 0; i < _mediaQueue.length; i++) {
      final item = _mediaQueue[i];
      if (!_isStreamingMediaItem(item)) {
        continue;
      }

      final itemRawVideoId = item.extras?['videoId']?.toString().trim();
      final itemVideoId = (itemRawVideoId != null && itemRawVideoId.isNotEmpty)
          ? itemRawVideoId
          : (item.id.startsWith('yt:')
                ? item.id.replaceFirst('yt:', '').trim()
                : '');
      final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
        preferred: item.extras?['displayArtUri']?.toString(),
        artUri: item.artUri,
        videoId: itemVideoId,
      );
      if (itemVideoId.isNotEmpty) {
        _streamQueuedVideoIds.add(itemVideoId);
      }

      final normalizedExtras = <String, dynamic>{
        ...?item.extras,
        'isStreaming': true,
        'radioMode': true,
        'queueIndex': i,
        if (itemVideoId.isNotEmpty) 'videoId': itemVideoId,
        'displayArtUri': resolvedDisplayArtUri,
      };
      _mediaQueue[i] = item.copyWith(
        artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
        extras: normalizedExtras,
      );
    }

    _streamQueuedVideoIds.add(seedVideoId);

    queue.add(List<MediaItem>.from(_mediaQueue));
    mediaItem.add(_mediaQueue[currentIndex]);
    unawaited(_syncFavoriteFlagForItem(_mediaQueue[currentIndex]));
    playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));

    await _ensureStreamingRadioQueue(force: true);
    return {'ok': true, 'queue_size': _mediaQueue.length};
  }

  Future<Map<String, dynamic>> _addYtStreamToQueue(
    Map<String, dynamic>? extras,
  ) async {
    final videoId = extras?['videoId']?.toString().trim();
    if (videoId == null || videoId.isEmpty) {
      return {'ok': false, 'reason': 'missing_video_id'};
    }

    final alreadyQueued = _mediaQueue.any((queuedItem) {
      final queuedVideoId = queuedItem.extras?['videoId']?.toString().trim();
      if (queuedVideoId != null && queuedVideoId.isNotEmpty) {
        return queuedVideoId == videoId;
      }
      return queuedItem.id == 'yt:$videoId';
    });
    if (alreadyQueued) {
      return {'ok': true, 'queued': false, 'reason': 'already_in_queue'};
    }

    final rawDuration = extras?['durationMs'];
    int? durationMs;
    if (rawDuration is int) {
      durationMs = rawDuration;
    } else if (rawDuration is String) {
      durationMs = int.tryParse(rawDuration);
    }

    final artUriRaw = extras?['artUri']?.toString().trim();
    final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
      preferred: extras?['displayArtUri']?.toString(),
      artUri: artUriRaw != null && artUriRaw.isNotEmpty
          ? Uri.tryParse(artUriRaw)
          : null,
      videoId: videoId,
    );
    final title = extras?['title']?.toString().trim();
    final artist = extras?['artist']?.toString().trim();
    var streamUrl = extras?['streamUrl']?.toString().trim();

    MediaItem buildQueueItem({
      required int queueIndex,
      String? effectiveStreamUrl,
    }) {
      return MediaItem(
        id: 'yt:$videoId',
        title: (title != null && title.isNotEmpty) ? title : 'Unknown title',
        artist: (artist != null && artist.isNotEmpty) ? artist : null,
        duration: (durationMs != null && durationMs > 0)
            ? Duration(milliseconds: durationMs)
            : null,
        artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
        extras: {
          'videoId': videoId,
          'isStreaming': true,
          'radioMode': _streamRadioEnabled,
          'streamUrl': effectiveStreamUrl,
          'displayArtUri': resolvedDisplayArtUri,
          'queueIndex': queueIndex,
        },
      );
    }

    if (_mediaQueue.isEmpty) {
      _resetStreamingSessionState(clearQueuedVideos: true);
      _deferredStreamingQueueMode = true;
      _deferredStreamingQueueIndex = 0;
      _streamRadioEnabled = false;
      _streamRadioInitialBatchLoaded = false;

      final firstItem = buildQueueItem(queueIndex: 0);
      _mediaQueue
        ..clear()
        ..add(firstItem);
      _streamQueuedVideoIds
        ..clear()
        ..add(videoId);
      queue.add(List<MediaItem>.from(_mediaQueue));
      mediaItem.add(firstItem);
      unawaited(_syncFavoriteFlagForItem(firstItem));

      final ok = await _resolveAndPlayDeferredStreamingIndex(0);
      if (!ok) {
        return {'ok': false, 'reason': 'missing_stream_url'};
      }
      return {'ok': true, 'queued': true, 'queueIndex': 0};
    }

    if (_deferredStreamingQueueMode) {
      final queueIndex = _mediaQueue.length;
      final newItem = buildQueueItem(queueIndex: queueIndex);
      _mediaQueue.add(newItem);
      _streamQueuedVideoIds.add(videoId);
      queue.add(List<MediaItem>.from(_mediaQueue));

      final currentIndex = _deferredStreamingQueueIndex.clamp(
        0,
        _mediaQueue.length - 1,
      );
      unawaited(_prefetchDeferredNextStreamUrl(currentIndex));
      _preloadNextStreamingArtworks(currentIndex);
      return {'ok': true, 'queued': true, 'queueIndex': queueIndex};
    }

    // En colas no diferidas, anexamos como AudioSource real al concatenating
    // para que quede disponible en la navegación normal del reproductor.
    if (streamUrl == null || streamUrl.isEmpty) {
      streamUrl = await StreamService.getBestAudioUrl(
        videoId,
      ).timeout(const Duration(seconds: 6), onTimeout: () => null);
    }
    if (streamUrl == null || streamUrl.isEmpty) {
      return {'ok': false, 'reason': 'missing_stream_url'};
    }
    if (_concat == null) {
      return {'ok': false, 'reason': 'missing_concat'};
    }

    try {
      // ignore: deprecated_member_use
      await _concat!.add(AudioSource.uri(Uri.parse(streamUrl)));
    } catch (_) {
      return {'ok': false, 'reason': 'append_failed'};
    }

    final queueIndex = _mediaQueue.length;
    final newItem = buildQueueItem(
      queueIndex: queueIndex,
      effectiveStreamUrl: streamUrl,
    );
    _mediaQueue.add(newItem);
    _streamQueuedVideoIds.add(videoId);
    queue.add(List<MediaItem>.from(_mediaQueue));

    unawaited(() async {
      try {
        final paths = _mediaQueue.map((m) => m.id).toList();
        await _prefs?.setStringList(_kPrefQueuePaths, paths);
      } catch (_) {}
    }());

    return {'ok': true, 'queued': true, 'queueIndex': queueIndex};
  }

  AudioPlayer get player => _player;

  AndroidEqualizer? get equalizer => _equalizer;

  AndroidLoudnessEnhancer? get loudnessEnhancer => _loudnessEnhancer;

  // Inicializar el AudioPlayer con AndroidLoudnessEnhancer

  // Variable para almacenar el nivel de volume boost
  double _volumeBoost = 1.0;
  final ValueNotifier<double> _volumeBoostNotifier = ValueNotifier<double>(1.0);
  bool _equalizerSettingsApplied = false;
  Future<void>? _equalizerApplyTask;

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
        // Calcular gain en dB
        // boostLevel 1.0 = 0dB, 1.5 = 5dB, 2.0 = 10dB, 3.0 = 20dB
        final gainInDb = ((_volumeBoost - 1.0) * 10).clamp(0.0, 20.0);

        // Mantener el enhancer siempre habilitado para compatibilidad con equalizer
        _loudnessEnhancer!.setEnabled(true);
        _loudnessEnhancer!.setTargetGain(gainInDb);

        // print('🔊 LoudnessEnhancer aplicado: ${gainInDb}dB (${_volumeBoost}x boost)');
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
        final gainInDb = ((_volumeBoost - 1.0) * 10).clamp(0.0, 20.0);

        // Mantener el enhancer siempre habilitado para compatibilidad con equalizer
        _loudnessEnhancer!.setEnabled(true);
        _loudnessEnhancer!.setTargetGain(gainInDb);

        // print('🔊 Volume boost cargado: ${_volumeBoost}x (${gainInDb}dB)');
      } else {
        // Fallback
        await _player.setVolume(_volumeBoost);
        // print('🔊 Volume boost cargado: ${_volumeBoost}x (fallback)');
      }
    } catch (e) {
      // print('Error al cargar preferencia de volume boost: $e');
    }
  }

  Future<void> _applyEqualizerSettingsFromPrefs() async {
    if (!Platform.isAndroid || _equalizer == null) return;
    if (_equalizerApplyTask != null) {
      await _equalizerApplyTask;
      return;
    }

    final task = () async {
      try {
        _prefs ??= await SharedPreferences.getInstance();
        final parameters = await _equalizer!.parameters.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw TimeoutException(
            'Timeout obteniendo parámetros del equalizer',
          ),
        );

        for (int i = 0; i < parameters.bands.length; i++) {
          final gain = _prefs?.getDouble('equalizer_band_$i') ?? 0.0;
          try {
            await parameters.bands[i].setGain(gain);
          } catch (_) {
            // Ignorar errores puntuales de banda para no bloquear la reproducción.
          }
        }

        final enabled = _prefs?.getBool('equalizer_enabled') ?? false;
        await _equalizer!.setEnabled(enabled);
        _equalizerSettingsApplied = true;
      } catch (_) {
        // No bloquear el arranque por errores del ecualizador.
      }
    }();

    _equalizerApplyTask = task;
    try {
      await task;
    } finally {
      _equalizerApplyTask = null;
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

  /// Restaura la configuración de audio después de una interrupción
  /// También disponible como método público para restaurar desde fuera del handler
  void _restoreAudioConfiguration() {
    try {
      // Re-aplicar volume boost si está habilitado
      if (_loudnessEnhancer != null && _volumeBoost > 1.0) {
        final gainInDb = ((_volumeBoost - 1.0) * 10).clamp(0.0, 20.0);
        _loudnessEnhancer!.setEnabled(true);
        _loudnessEnhancer!.setTargetGain(gainInDb);
      } else if (_loudnessEnhancer != null) {
        // Asegurar que el enhancer esté en estado correcto aunque no haya boost
        _loudnessEnhancer!.setEnabled(true);
        _loudnessEnhancer!.setTargetGain(0.0);
      }

      // Re-aplicar volumen del player a 1.0 (nivel máximo del sistema)
      // Esto es crucial después de estar en segundo plano por mucho tiempo
      // ya que Android puede haber reducido el volumen del audio stream
      unawaited(_player.setVolume(1.0));

      // Re-aplicar equalizer si está activo
      if (_equalizer != null && _equalizer!.enabled) {
        // El equalizer mantiene su configuración, solo asegurar que esté habilitado
        _equalizer!.setEnabled(true);
      }
      if (!_equalizerSettingsApplied) {
        unawaited(_applyEqualizerSettingsFromPrefs());
      }
    } catch (e) {
      // Error silencioso - continuar reproducción
    }
  }

  /// Método público para restaurar la configuración de audio
  /// Debe llamarse cuando la app vuelve del segundo plano
  void restoreAudioConfiguration() {
    _restoreAudioConfiguration();
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
      // Restaurar configuración de audio proactivamente al reanudar
      // Esto asegura que el volumen sea correcto después de estar en segundo plano
      _restoreAudioConfiguration();
      if (!_equalizerSettingsApplied) {
        await _applyEqualizerSettingsFromPrefs();
      }

      // Si la lista terminó (estado completed), reiniciar la canción actual
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
        //delay de 200 ms
        await Future.delayed(const Duration(milliseconds: 200));
        await _player.play();
        return;
      }

      await _player.play();
    } catch (e) {
      // Intentar saltar a la siguiente canción si la actual falla (e.g. archivo corrupto)
      try {
        if (_mediaQueue.isNotEmpty &&
            _player.currentIndex != null &&
            _player.currentIndex! < _mediaQueue.length - 1) {
          // print('⚠️ Error al reproducir, intentando saltar a la siguiente...');
          await skipToNext();
          await _player.play();
          return;
        }
      } catch (_) {
        // Si falla el salto, continuar con la reinicialización
      }

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

        // Si falló la reproducción, intentar avanzar el índice para el fallback
        // para no quedar atascado en la misma canción corrupta
        int nextIndex = fallbackIndex;
        if (fallbackIndex < _currentSongList.length - 1) {
          nextIndex = fallbackIndex + 1;
        }

        await _reinitializePlayer();
        if (_currentSongList.isNotEmpty) {
          await setQueueFromSongsWithPosition(
            _currentSongList,
            initialIndex: nextIndex.clamp(0, _currentSongList.length - 1),
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
      _resetStreamingSessionState(clearQueuedVideos: true);
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

  @override
  Future<void> skipToNext() async {
    // Safety check: Si está reproduciendo, no debería estar inicializando.
    // Esto corrige el estado "zombie" donde _initializing se queda pegado.
    if (_player.playing && _initializing) {
      _initializing = false;
      initializingNotifier.value = false;
    }

    if (_initializing) return;
    if (_isSkipping) {
      _queuedSkipNext = true;
      _queuedSkipPrevious = false;
      return;
    }

    _isSkipping = true;

    try {
      // Cancelar operaciones pendientes antes de cambiar
      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();

      if (_deferredStreamingQueueMode) {
        final nextIndex = _nextDeferredQueueIndex();
        if (nextIndex == null) {
          if (_streamRadioEnabled) {
            unawaited(() async {
              await _ensureStreamingRadioQueue(force: true);
              final fetchedNextIndex = _nextDeferredQueueIndex();
              if (fetchedNextIndex != null) {
                await _resolveAndPlayDeferredStreamingIndex(
                  fetchedNextIndex,
                  playAfterResolve: true,
                );
                _updateSleepTimer();
              }
            }());
          }
          return;
        }
        _isSkipping = false;
        _consumeQueuedSkip();
        _scheduleStreamingSkip(nextIndex, playAfterResolve: true);
        return;
      }

      final int currentIndex = (_player.currentIndex ?? 0).clamp(
        0,
        _mediaQueue.isEmpty ? 0 : _mediaQueue.length - 1,
      );
      final bool isStreamingQueue =
          _streamRadioEnabled &&
          _mediaQueue.isNotEmpty &&
          _isStreamingMediaItem(_mediaQueue.first);
      final int remaining = (_mediaQueue.length - 1) - currentIndex;

      // No bloquear el gesto por red cuando falta el siguiente en streaming.
      if (isStreamingQueue && remaining <= 0) {
        unawaited(_ensureStreamingRadioQueue(force: true));
        return;
      } else if (isStreamingQueue &&
          remaining <= _streamRadioPrefetchThreshold) {
        unawaited(_ensureStreamingRadioQueue());
      }

      final shouldAutoPlayLocal = !isStreamingQueue && !_player.playing;

      // En reproducción local (o colas no diferidas), avanzar índice real.
      await _player.seekToNext().timeout(const Duration(milliseconds: 300));
      if (shouldAutoPlayLocal && !_player.playing) {
        await _player.play();
      }
      _updateSleepTimer();

      // La nueva carátula se cargará automáticamente por el currentIndexStream listener
    } catch (e) {
      // print('⚠️ Error en skipToNext: $e');
    } finally {
      _isSkipping = false;
      _consumeQueuedSkip();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // Safety check
    if (_player.playing && _initializing) {
      _initializing = false;
      initializingNotifier.value = false;
    }

    if (_initializing) return;
    if (_isSkipping) {
      _queuedSkipPrevious = true;
      _queuedSkipNext = false;
      return;
    }

    _isSkipping = true;
    try {
      // Cancelar operaciones pendientes antes de cambiar
      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();

      if (_deferredStreamingQueueMode) {
        if (_player.position.inMilliseconds > 5000) {
          await _player
              .seek(Duration.zero)
              .timeout(const Duration(milliseconds: 650));
        } else {
          final previousIndex = _previousDeferredQueueIndex();
          if (previousIndex != null) {
            _isSkipping = false;
            _consumeQueuedSkip();
            _scheduleStreamingSkip(previousIndex, playAfterResolve: true);
            return;
          } else {
            await _player
                .seek(Duration.zero)
                .timeout(const Duration(milliseconds: 650));
          }
        }
        _updateSleepTimer();
        return;
      }

      final bool isStreamingQueue =
          _streamRadioEnabled &&
          _mediaQueue.isNotEmpty &&
          _isStreamingMediaItem(_mediaQueue.first);
      final shouldAutoPlayLocal = !isStreamingQueue && !_player.playing;

      if (_player.position.inMilliseconds > 5000) {
        await _player
            .seek(Duration.zero)
            .timeout(const Duration(milliseconds: 650));
      } else {
        await _player.seekToPrevious().timeout(
          const Duration(milliseconds: 650),
        );
      }
      if (shouldAutoPlayLocal && !_player.playing) {
        await _player.play();
      }
      _updateSleepTimer();

      // La nueva carátula se cargará automáticamente por el currentIndexStream listener
    } catch (e) {
      // print('⚠️ Error en skipToPrevious: $e');
    } finally {
      _isSkipping = false;
      _consumeQueuedSkip();
    }
  }

  /// Actualiza la UI inmediatamente y resuelve el stream de la canción destino.
  /// Si el usuario salta de nuevo, la resolución anterior se cancela
  /// automáticamente por el sistema de generación (_resolveGeneration).
  void _scheduleStreamingSkip(
    int targetIndex, {
    bool playAfterResolve = false,
  }) {
    if (!_deferredStreamingQueueMode) return;
    if (targetIndex < 0 || targetIndex >= _mediaQueue.length) return;

    // Cancelar inmediatamente cualquier resolución previa en curso.
    _resolveGeneration++;
    final requestGeneration = _resolveGeneration;
    // Refuerzo en capa de servicio: cancelar resolución de DB/red en curso
    // y reiniciar el cliente de youtube_explode_dart para abortar requests viejas.
    StreamService.cancelPendingResolves(resetClient: true);

    // Incrementar generación de artwork para cancelar descargas intermedias.
    _artworkGeneration++;

    // 1) Actualizar UI instantáneamente: índice, metadata y estado de carga.
    _deferredStreamingQueueIndex = targetIndex;
    final item = _mediaQueue[targetIndex];
    mediaItem.add(item);
    unawaited(_syncFavoriteFlagForItem(item));
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: targetIndex,
        processingState: AudioProcessingState.loading,
      ),
    );

    // Usar carátula cacheada localmente si existe para UI instantánea.
    final rawVideoId = item.extras?['videoId']?.toString().trim();
    final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : item.id.replaceFirst('yt:', '').trim();
    if (videoId.isNotEmpty) {
      final cachedUri = _streamArtworkFileCache[videoId];
      if (cachedUri != null) {
        final updated = item.copyWith(artUri: cachedUri);
        _mediaQueue[targetIndex] = updated;
        mediaItem.add(updated);
      }
    }

    // 2) Resolver y reproducir inmediatamente.
    //    Si el usuario salta de nuevo, _resolveGeneration cambiará y
    //    la resolución en curso abortará via isSuperseded().
    unawaited(() async {
      await _resolveAndPlayDeferredStreamingIndex(
        targetIndex,
        playAfterResolve: playAfterResolve,
        expectedGeneration: requestGeneration,
      );
      _updateSleepTimer();
    }());
  }

  void _consumeQueuedSkip() {
    if (_isSkipping || _initializing) return;

    if (_queuedSkipNext) {
      _queuedSkipNext = false;
      unawaited(skipToNext());
      return;
    }

    if (_queuedSkipPrevious) {
      _queuedSkipPrevious = false;
      unawaited(skipToPrevious());
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    // Safety check
    if (_player.playing && _initializing) {
      _initializing = false;
      initializingNotifier.value = false;
    }

    if (_initializing) return;
    if (index >= 0 && index < _mediaQueue.length) {
      if (_deferredStreamingQueueMode) {
        _scheduleStreamingSkip(index, playAfterResolve: true);
        return;
      }
      try {
        // Cancelar operaciones pendientes antes de cambiar
        _pendingArtworkOperations.clear();
        cancelAllArtworkLoads();

        // Marcar que el usuario inició la reproducción para evitar que la pausa automática interfiera
        _userInitiatedPlayback = true;

        // Ejecutar el seek de forma asíncrona
        unawaited(() async {
          try {
            await _player
                .seek(Duration.zero, index: index)
                .timeout(const Duration(seconds: 3));
            _updateSleepTimer();

            // Siempre iniciar reproducción cuando el usuario selecciona una canción
            // Esto corrige el problema de que después de que la última canción termina,
            // al seleccionar otra canción no se reproducía automáticamente
            if (!_player.playing) {
              await _player.play();
            }

            // Resetear el flag después de que la reproducción haya comenzado
            await Future.delayed(const Duration(milliseconds: 200));
            _userInitiatedPlayback = false;
          } catch (e) {
            _userInitiatedPlayback = false;
            // Error silencioso
          }
        }());
      } catch (e) {
        _userInitiatedPlayback = false;
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
    playbackState.add(
      playbackState.value.copyWith(
        repeatMode: repeatMode,
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );

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
    if (_deferredStreamingQueueMode) return;
    isShuffleNotifier.value = _player.shuffleModeEnabled;
  }

  /// Obtiene la cola actual respetando el orden del shuffle si está activo
  List<MediaItem> get effectiveQueue {
    if (_mediaQueue.isEmpty) return [];

    // Si shuffle NO está activo, devolver la cola original
    if (!isShuffleNotifier.value) {
      return List<MediaItem>.from(_mediaQueue);
    }

    if (_deferredStreamingQueueMode) {
      _ensureDeferredShuffleOrder();
      if (_deferredShuffleOrder.isEmpty ||
          _deferredShuffleOrder.length != _mediaQueue.length) {
        return List<MediaItem>.from(_mediaQueue);
      }
      return _deferredShuffleOrder.map((i) => _mediaQueue[i]).toList();
    }

    try {
      final indices = _player.shuffleIndices;
      if (indices.isEmpty || indices.length != _mediaQueue.length) {
        return List<MediaItem>.from(_mediaQueue);
      }

      return indices.map((i) => _mediaQueue[i]).toList();
    } catch (e) {
      return List<MediaItem>.from(_mediaQueue);
    }
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

        if (_deferredStreamingQueueMode) {
          _ensureDeferredShuffleOrder(
            currentIndex: _deferredStreamingQueueIndex,
          );
        } else {
          // Usar el shuffle nativo de just_audio - sin pausas de audio
          await _player.setShuffleModeEnabled(true);
          await _player.shuffle();
        }

        // Actualizar el estado de audio_service con ambos modos para sincronización completa
        playbackState.add(
          playbackState.value.copyWith(
            shuffleMode: AudioServiceShuffleMode.all,
            repeatMode: _player.loopMode == LoopMode.one
                ? AudioServiceRepeatMode.one
                : _player.loopMode == LoopMode.all
                ? AudioServiceRepeatMode.all
                : AudioServiceRepeatMode.none,
          ),
        );
      } else {
        isShuffleNotifier.value = false;
        _deferredShuffleOrder = const <int>[];
        _deferredShuffleCursor = 0;

        // Desactivar shuffle nativo de just_audio
        await _player.setShuffleModeEnabled(false);

        // Actualizar el estado de audio_service con ambos modos para sincronización completa
        playbackState.add(
          playbackState.value.copyWith(
            shuffleMode: AudioServiceShuffleMode.none,
            repeatMode: _player.loopMode == LoopMode.one
                ? AudioServiceRepeatMode.one
                : _player.loopMode == LoopMode.all
                ? AudioServiceRepeatMode.all
                : AudioServiceRepeatMode.none,
          ),
        );
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
      playbackState.add(
        playbackState.value.copyWith(
          shuffleMode: enable
              ? AudioServiceShuffleMode.none
              : AudioServiceShuffleMode.all,
          repeatMode: _player.loopMode == LoopMode.one
              ? AudioServiceRepeatMode.one
              : _player.loopMode == LoopMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none,
        ),
      );
    }
  }

  Stream<Duration> get positionStream => _positionStream;
  Stream<Duration?> get durationStream => _durationStream;

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
            album: s.displayAlbum,
            title: s.displayTitle,
            artist: s.displayArtist,
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
  /// Si [duration] es null, se activará el modo "Pausar al finalizar la canción actual".
  /// Inicia el temporizador de apagado automático.
  /// Si [duration] es null, se activará el modo "Pausar al finalizar la canción actual".
  void startSleepTimer([Duration? duration]) {
    cancelSleepTimer();

    if (duration == null) {
      _stopAtEndOfSong = true;
      _lastSleepIndex = _player.currentIndex;

      // Listener de respaldo para detectar cambios de pista o finalización
      _sleepTimerSub = _player.playbackEventStream.listen((event) {
        if (!_stopAtEndOfSong) return;
        final state = event.processingState;
        final index = _player.currentIndex;
        if (state == ProcessingState.completed ||
            (index != null &&
                _lastSleepIndex != null &&
                index != _lastSleepIndex)) {
          unawaited(pause());
          cancelSleepTimer();
        }
      });
    } else {
      _stopAtEndOfSong = false;
      _sleepDuration = duration;
      _sleepStartPosition = _player.position;
    }

    _updateSleepTimer();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimerSub?.cancel();
    _sleepTimer = null;
    _sleepTimerSub = null;
    _sleepDuration = null;
    _sleepStartPosition = null;
    _lastSleepIndex = null;
    _stopAtEndOfSong = false;
  }

  /// Actualiza el temporizador cuando cambia la posición de reproducción
  void _updateSleepTimer() {
    if (!isSleepTimerActive) return;

    _sleepTimer?.cancel();
    final remainingTime = _calculateRemainingTime();

    if (remainingTime != null && remainingTime.inMilliseconds > 0) {
      _sleepTimer = Timer(remainingTime, () async {
        await pause();
        cancelSleepTimer();
      });
    } else if (remainingTime != null) {
      unawaited(pause());
      cancelSleepTimer();
    }
  }

  /// Calcula el tiempo restante basado en la posición actual
  Duration? _calculateRemainingTime() {
    if (!isSleepTimerActive) return null;

    final currentPosition = _player.position;

    if (_stopAtEndOfSong) {
      final songDuration = _player.duration;
      if (songDuration == null) return null;
      final remaining = songDuration - currentPosition;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    if (_sleepDuration == null || _sleepStartPosition == null) return null;

    final elapsedSinceStart = currentPosition - _sleepStartPosition!;
    final remaining = _sleepDuration! - elapsedSinceStart;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Devuelve el tiempo restante o null si no hay temporizador activo.
  Duration? get sleepTimeRemaining => _calculateRemainingTime();

  bool get isSleepTimerActive => _sleepDuration != null || _stopAtEndOfSong;

  /// Precarga todas las carátulas en background SIN actualizar MediaItem para evitar parpadeos
  Future<void> _preloadAllArtworksInBackground(
    List<SongModel> songs, {
    int? requestVersion,
  }) async {
    try {
      if (requestVersion != null && requestVersion != _loadVersion) return;
      if (songs.isEmpty) return;

      // print('🚀 Iniciando precarga masiva de ${songs.length} carátulas en background...');

      // Filtrar canciones que no están ya en caché
      final songsToLoad = songs
          .where(
            (song) =>
                !_artworkCache.containsKey(song.data) &&
                !_preloadCache.containsKey(song.data),
          )
          .take(20) // Limitar a 20 canciones para no sobrecargar
          .toList();

      if (songsToLoad.isEmpty) return;

      // Cargar carátulas en lotes pequeños para no bloquear la UI
      const int batchSize = 3;
      for (int i = 0; i < songsToLoad.length; i += batchSize) {
        if (requestVersion != null && requestVersion != _loadVersion) return;
        final batch = songsToLoad.skip(i).take(batchSize).toList();

        // Cargar lote en paralelo
        await Future.wait(
          batch.map((song) async {
            if (requestVersion != null && requestVersion != _loadVersion) {
              return;
            }
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
        if (requestVersion != null && requestVersion != _loadVersion) return;
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
      _initializePlayerWithEnhancer();
      _equalizerSettingsApplied = false;
      await _applyEqualizerSettingsFromPrefs();
      await _init();
    } catch (e) {
      _player = AudioPlayer();
      _bindPlayerStreams();
    }
  }

  // Guarda toda la sesión actual en SharedPreferences
  Future<void> _saveSessionToPrefs() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();

      if (_mediaQueue.isNotEmpty && _isStreamingMediaItem(_mediaQueue.first)) {
        await prefs.setStringList(_kPrefQueuePaths, const []);
        await prefs.setInt(_kPrefQueueIndex, _player.currentIndex ?? 0);
        await prefs.setInt(_kPrefSongPositionSec, _player.position.inSeconds);
        await prefs.setBool(_kPrefWasPlaying, _player.playing);
        return;
      }

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
                final artUri = await getOrCacheArtwork(
                  songId,
                  songPath,
                ).timeout(const Duration(milliseconds: 1500));

                if (artUri != null && mounted) {
                  final validUri = Uri.file(artUri.toFilePath());
                  final updatedMediaItem = currentMediaItem.copyWith(
                    artUri: validUri,
                  );
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
      return {'ok': true};
    }
    if (name == 'addYtStreamToQueue' ||
        extras?['action'] == 'addYtStreamToQueue') {
      return _addYtStreamToQueue(extras);
    }
    if (name == 'startStreamingRadioFromCurrent' ||
        extras?['action'] == 'startStreamingRadioFromCurrent') {
      final replaceQueue = extras?['replaceQueue'] != false;
      return _startStreamingRadioFromCurrent(replaceQueue: replaceQueue);
    }
    if (name == 'playYtStreamQueue' ||
        extras?['action'] == 'playYtStreamQueue') {
      final rawItems = extras?['items'];
      if (rawItems is! List || rawItems.isEmpty) {
        return {'ok': false, 'reason': 'missing_items'};
      }

      final requestedIndex = extras?['initialIndex'];
      int initialIndex = requestedIndex is int
          ? requestedIndex
          : int.tryParse(requestedIndex?.toString() ?? '0') ?? 0;
      if (initialIndex < 0 || initialIndex >= rawItems.length) {
        initialIndex = 0;
      }

      final queueItems = <MediaItem>[];
      for (int i = 0; i < rawItems.length; i++) {
        final raw = rawItems[i];
        if (raw is! Map) continue;
        final data = Map<String, dynamic>.from(raw);
        final videoId = data['videoId']?.toString().trim();
        if (videoId == null || videoId.isEmpty) continue;

        final rawDuration = data['durationMs'];
        int? durationMs;
        if (rawDuration is int) {
          durationMs = rawDuration;
        } else if (rawDuration is String) {
          durationMs = int.tryParse(rawDuration);
        }

        final artUriRaw = data['artUri']?.toString().trim();
        final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
          preferred: data['displayArtUri']?.toString(),
          artUri: artUriRaw != null && artUriRaw.isNotEmpty
              ? Uri.tryParse(artUriRaw)
              : null,
          videoId: videoId,
        );

        final title = data['title']?.toString().trim();
        final artist = data['artist']?.toString().trim();

        queueItems.add(
          MediaItem(
            id: 'yt:$videoId',
            title: (title != null && title.isNotEmpty)
                ? title
                : 'Unknown title',
            artist: (artist != null && artist.isNotEmpty) ? artist : null,
            duration: durationMs != null && durationMs > 0
                ? Duration(milliseconds: durationMs)
                : null,
            artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
            extras: {
              'videoId': videoId,
              'isStreaming': true,
              'radioMode': false,
              'streamUrl': data['streamUrl']?.toString().trim(),
              'displayArtUri': resolvedDisplayArtUri,
              'queueIndex': i,
            },
          ),
        );
      }

      if (queueItems.isEmpty) {
        return {'ok': false, 'reason': 'no_valid_items'};
      }

      if (initialIndex >= queueItems.length) {
        initialIndex = 0;
      }

      _deferredStreamingQueueMode = true;
      _deferredStreamingQueueIndex = initialIndex;
      _streamRadioEnabled = false;
      _streamRadioSeedVideoId = null;
      _streamRadioContinuationParams = null;

      _pendingArtworkOperations.clear();
      cancelAllArtworkLoads();
      _preloadDebounceTimer?.cancel();
      _isPreloadingNext = false;
      _resetTracking();

      _currentSongList.clear();
      _originalSongList = null;

      _mediaQueue
        ..clear()
        ..addAll(queueItems);
      _ensureDeferredShuffleOrder(currentIndex: initialIndex);
      queue.add(List<MediaItem>.from(_mediaQueue));
      mediaItem.add(_mediaQueue[initialIndex]);
      unawaited(_syncFavoriteFlagForItem(_mediaQueue[initialIndex]));

      final ok = await _resolveAndPlayDeferredStreamingIndex(initialIndex);
      if (!ok) return {'ok': false, 'reason': 'missing_stream_url'};
      if (extras?['autoPlay'] != false) {
        await play();
      }
      return {'ok': true};
    }
    if (name == "playYtStream" || extras?['action'] == 'playYtStream') {
      final streamUrl = extras?['streamUrl']?.toString().trim();
      if (streamUrl != null && streamUrl.isNotEmpty) {
        final radioMode = extras?['radioMode'] != false;
        final rawDuration = extras?['durationMs'];
        int? durationMs;
        if (rawDuration is int) {
          durationMs = rawDuration;
        } else if (rawDuration is String) {
          durationMs = int.tryParse(rawDuration);
        }

        final mediaId =
            (extras?['mediaId']?.toString().trim().isNotEmpty ?? false)
            ? extras!['mediaId'].toString().trim()
            : (extras?['videoId']?.toString().trim().isNotEmpty ?? false)
            ? 'yt:${extras!['videoId'].toString().trim()}'
            : 'yt_stream_$streamUrl';

        final artUriRaw = extras?['artUri']?.toString().trim();
        final videoId = extras?['videoId']?.toString().trim();
        final resolvedDisplayArtUri = _resolveStreamingDisplayArtUri(
          preferred: extras?['displayArtUri']?.toString(),
          artUri: artUriRaw != null && artUriRaw.isNotEmpty
              ? Uri.tryParse(artUriRaw)
              : null,
          videoId: videoId,
        );
        final artist = extras?['artist']?.toString().trim();

        final streamMediaItem = MediaItem(
          id: mediaId,
          title: extras?['title']?.toString().trim().isNotEmpty == true
              ? extras!['title'].toString().trim()
              : 'Unknown title',
          artist: artist == null || artist.isEmpty ? null : artist,
          duration: durationMs != null && durationMs > 0
              ? Duration(milliseconds: durationMs)
              : null,
          artUri: Uri.tryParse(resolvedDisplayArtUri ?? ''),
          extras: {
            'videoId': videoId,
            'isStreaming': true,
            'radioMode': radioMode,
            'playlistId': extras?['playlistId']?.toString().trim(),
            'streamUrl': streamUrl,
            'displayArtUri': resolvedDisplayArtUri,
          },
        );

        await playSingleStream(
          streamUrl: streamUrl,
          item: streamMediaItem,
          autoPlay: extras?['autoPlay'] != false,
        );
        return {'ok': true};
      }
      return {'ok': false, 'reason': 'missing_stream_url'};
    }
    if (name == "favorite" || extras?['action'] == 'favorite') {
      final item = mediaItem.value;
      if (item == null) {
        return {'ok': false, 'reason': 'no_media_item'};
      }

      final favoritePath = _favoritePathForMediaItem(item);
      if (favoritePath.isEmpty) {
        return {'ok': false, 'reason': 'missing_favorite_path'};
      }

      final existingFavoriteKey = await _findExistingFavoriteStorageKey(item);
      final isFav =
          _favoriteIds.contains(item.id) || existingFavoriteKey != null;
      if (isFav) {
        final keyToRemove = existingFavoriteKey ?? favoritePath;
        await FavoritesDB().removeFavorite(keyToRemove);
        _favoriteIds.remove(item.id);
      } else {
        if (item.extras?['isStreaming'] == true) {
          final videoId = item.extras?['videoId']?.toString().trim();
          final displayArtUri = item.extras?['displayArtUri']
              ?.toString()
              .trim();
          final artUri = (displayArtUri != null && displayArtUri.isNotEmpty)
              ? displayArtUri
              : item.artUri?.toString();
          final durationMs = item.duration?.inMilliseconds;
          await FavoritesDB().addFavoritePath(
            favoritePath,
            title: item.title,
            artist: item.artist,
            videoId: videoId,
            artUri: artUri,
            durationMs: (durationMs != null && durationMs > 0)
                ? durationMs
                : null,
          );
        } else {
          await FavoritesDB().addFavoritePath(favoritePath);
        }
        _favoriteIds.add(item.id);
      }

      playbackState.add(_transformPlaybackEvent(_player.playbackEvent));
      favoritesShouldReload.value = !favoritesShouldReload.value;
      return {'ok': true, 'isFavorite': _favoriteIds.contains(item.id)};
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
