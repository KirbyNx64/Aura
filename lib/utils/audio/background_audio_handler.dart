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
import 'optimized_album_art_loader.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

AudioHandler? _audioHandler;

Future<AudioHandler> initAudioService() async {
  if (_audioHandler != null) {
    return _audioHandler!;
  }

  try {
    _audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationIcon: 'mipmap/ic_stat_music_note',
        androidNotificationChannelId: 'com.aura.music.channel',
        androidNotificationChannelName: 'Aura Music',
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
    throw Exception('Error al inicializar AudioService: $e');
  }
}

/// Función para reinicializar completamente el AudioHandler
Future<void> reinitializeAudioHandler() async {
  try {
    // Limpiar la instancia global
    _audioHandler = null;

    // Reinicializar
    await initAudioService();
  } catch (e) {
    // Error silencioso
  }
}

// Cache Manager optimizado para carátulas
final AlbumArtCacheManager _albumArtCacheManager = AlbumArtCacheManager();

// Cargador optimizado con cancelación
final OptimizedAlbumArtLoader _optimizedLoader = OptimizedAlbumArtLoader();

// Cache global para URIs de carátulas (compatibilidad)
const int _artworkCacheMaxEntries = 300;
final LinkedHashMap<String, Uri?> _artworkCache = LinkedHashMap();
final Map<String, Future<Uri?>> _preloadCache = {};
String? _tempDirPath;

Map<String, Uri?> get artworkCache => _artworkCache;

Future<Uri?> getOrCacheArtwork(int songId, String songPath) async {
  // 1. Verifica cache en memoria primero (compatibilidad)
  if (_artworkCache.containsKey(songPath)) {
    // Toca la entrada para comportamiento tipo LRU
    final cached = _artworkCache.remove(songPath);
    if (cached != null) {
      _artworkCache[songPath] = cached;
    } else {
      _artworkCache[songPath] = null;
    }
    return cached;
  }

  // 2. Verifica si ya se está precargando
  if (_preloadCache.containsKey(songPath)) {
    return await _preloadCache[songPath]!;
  }

  // 3. Crea el Future y almacénalo inmediatamente para evitar duplicados
  final future = _loadArtworkAsyncOptimized(songId, songPath);
  _preloadCache[songPath] = future;

  try {
    final result = await future;
    _artworkCache[songPath] = result;
    // Limitar tamaño del cache (LRU simple por inserción)
    if (_artworkCache.length > _artworkCacheMaxEntries) {
      final firstKey = _artworkCache.keys.first;
      _artworkCache.remove(firstKey);
    }
    return result;
  } finally {
    _preloadCache.remove(songPath);
  }
}

/// Función optimizada que usa el nuevo cache manager y cargador
Future<Uri?> _loadArtworkAsyncOptimized(int songId, String songPath) async {
  try {
    // Usar el cargador optimizado con cancelación
    final bytes = await _optimizedLoader.loadAlbumArt(songId, songPath);

    if (bytes != null) {
      // Crear archivo temporal y retornar URI
      _tempDirPath ??= (await getTemporaryDirectory()).path;
      final file = await File(
        '$_tempDirPath/artwork_$songId.jpg',
      ).writeAsBytes(bytes);
      final uri = Uri.file(file.path);
      return uri;
    }
  } catch (e) {
    // Error silencioso, retorna null
  }
  return null;
}

/// Precarga carátulas para una lista de canciones de forma asíncrona
Future<void> preloadArtworks(
  List<SongModel> songs, {
  int maxConcurrent = 3,
}) async {
  // Usar el cargador optimizado para precarga
  final songsToLoad = songs
      .where(
        (song) =>
            !_artworkCache.containsKey(song.data) &&
            !_preloadCache.containsKey(song.data),
      )
      .take(10)
      .toList(); // Limitar a 10 canciones para no sobrecargar

  if (songsToLoad.isEmpty) return;

  // Convertir SongModel a formato requerido por el cargador optimizado
  final songsData = songsToLoad
      .map((song) => {'id': song.id, 'data': song.data})
      .toList();

  // Usar el cargador optimizado con cancelación
  await _optimizedLoader.loadMultipleAlbumArts(songsData);
}

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
  _optimizedLoader.cancelAllLoads();
}

/// Cancela carga específica de carátula
void cancelArtworkLoad(int songId) {
  _optimizedLoader.cancelLoad(songId);
}

/// Obtiene estadísticas del cargador optimizado
Map<String, dynamic> getOptimizedLoaderStats() {
  return _optimizedLoader.getLoaderStats();
}

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _mediaQueue = [];
  List<MediaItem>? _originalQueue; // Guarda la cola original para restaurar
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
  bool _isManualChange = false;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<ProcessingState>? _processingStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  // Control de operaciones pendientes para evitar sobrecarga
  String? _lastProcessedSongId;
  final Map<String, bool> _pendingArtworkOperations = {};

  // Debounce para actualizaciones de notificación
  Timer? _notificationDebounceTimer;
  static const Duration _notificationDebounceDelay = Duration(
    milliseconds: 300,
  );
  MediaItem? _lastNotificationMediaItem;

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

  MyAudioHandler() {
    _init();
  }

  int _initRetryCount = 0;
  static const int _initMaxRetries = 5;

  Future<void> _init() async {
    if (_isInitialized) return;

    try {
      _prefs ??= await SharedPreferences.getInstance();
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Cancelar suscripciones anteriores si existen
      await _disposeListeners();

      _playbackEventSubscription = _player.playbackEventStream.listen((event) {
        final playing = _player.playing;
        final processingState = _transformState(event.processingState);

        playbackState.add(
          playbackState.value.copyWith(
            controls: [
              MediaControl.skipToPrevious,
              if (playing) MediaControl.pause else MediaControl.play,
              MediaControl.skipToNext,
            ],
            systemActions: const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
            },
            androidCompactActionIndices: const [0, 1, 2],
            processingState: processingState,
            playing: playing,
            updatePosition: _player.position,
            bufferedPosition: _player.bufferedPosition,
            speed: _player.speed,
            queueIndex: _player.currentIndex,
          ),
        );

        // Si se completó y está en loop one, lanza el seek/play en segundo plano
        if (event.processingState == ProcessingState.completed &&
            _player.loopMode == LoopMode.one) {
          unawaited(_player.seek(Duration.zero));
          unawaited(_player.play());
        }
      });

      _currentIndexSubscription = _player.currentIndexStream.listen((index) {
        if (_initializing) return;
        if (index != null && index < _mediaQueue.length) {
          var currentMediaItem = _mediaQueue[index];
          final songPath = currentMediaItem.extras?['data'] as String?;
          final songId = currentMediaItem.extras?['songId'] as int?;
          final currentSongId = currentMediaItem.id;

          // Cancelar operaciones pendientes de canciones anteriores
          if (_lastProcessedSongId != null &&
              _lastProcessedSongId != currentSongId) {
            _pendingArtworkOperations.clear();
            cancelAllArtworkLoads(); // Cancelar cargas de carátulas activas
          }
          _lastProcessedSongId = currentSongId;

          // Persistir índice actual (sin await para no bloquear)
          unawaited(() async {
            try {
              await _prefs?.setInt(_kPrefQueueIndex, index);
            } catch (_) {}
          }());

          // Tracking de tiempo de escucha: resetear tracking al cambiar de canción
          if (currentMediaItem.id.isNotEmpty &&
              currentMediaItem.id != _currentTrackingId) {
            _resetTracking();
            _currentTrackingId = currentMediaItem.id;
            _trackingStartTime = DateTime.now();

            if (songPath != null) {
              _startTrackingPlaytime(currentMediaItem.id, songPath);
            }
          }

          // Preparar MediaItem final solo basándose en la nueva canción
          MediaItem finalMediaItem = currentMediaItem;

          if (songPath != null && songId != null) {
            if (_artworkCache.containsKey(songPath)) {
              // Carátula en caché - usar inmediatamente
              final artUri = _artworkCache[songPath];
              finalMediaItem = currentMediaItem.copyWith(artUri: artUri);
              _mediaQueue[index] = finalMediaItem;
            } else {
              // No está en caché - cargar en background después de actualizar
              if (!_pendingArtworkOperations.containsKey(currentSongId)) {
                _pendingArtworkOperations[currentSongId] = true;
                unawaited(() async {
                  try {
                    final artUri = await getOrCacheArtwork(
                      songId,
                      songPath,
                    ).timeout(const Duration(milliseconds: 500));

                    // Verificar que aún estamos en la misma canción
                    if (_lastProcessedSongId == currentSongId &&
                        mounted &&
                        _player.currentIndex == index) {
                      final updatedMediaItem = _mediaQueue[index].copyWith(
                        artUri: artUri,
                      );
                      _mediaQueue[index] = updatedMediaItem;
                      // Actualizar inmediatamente en la UI
                      mediaItem.add(updatedMediaItem);
                    }
                  } catch (e) {
                    // Error silencioso - el widget ya sabe que no hay carátula
                  } finally {
                    _pendingArtworkOperations.remove(currentSongId);
                  }
                }());
              }
            }
          }

          // Actualizar inmediatamente para cambios automáticos, con debounce para manuales
          mediaItem.add(finalMediaItem);

          if (_isSkipping || _isManualChange) {
            // Cambio manual (skipToNext, skipToPrevious, skipToQueueItem) - usar debounce
            _updateNotificationWithDebounce(finalMediaItem, index);
            // Resetear flag después de detectar
            _isManualChange = false;
          } else {
            // Cambio automático (canción termina sola) - pequeño delay para cargar carátula
            Timer(const Duration(milliseconds: 100), () {
              if (mounted) {
                playbackState.add(
                  playbackState.value.copyWith(queueIndex: index),
                );
              }
            });
          }
        }
      });

      _durationSubscription = _player.durationStream.listen((duration) {
        final current = mediaItem.value;
        if (current != null &&
            duration != null &&
            current.duration != duration) {
          // Actualizar inmediatamente en la UI
          mediaItem.add(current.copyWith(duration: duration));
          playbackState.add(
            playbackState.value.copyWith(
              updatePosition: _player.position,
              processingState: playbackState.value.processingState,
            ),
          );
        }
      });

      _playingSubscription = _player.playingStream.listen((playing) {
        playbackState.add(playbackState.value.copyWith(playing: playing));
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
        playbackState.add(
          playbackState.value.copyWith(processingState: _transformState(state)),
        );

        // Nudge en READY/BUFFERING y cuando finaliza una pista para asegurar refresco de arte
        if ((state == ProcessingState.ready ||
                state == ProcessingState.buffering ||
                state == ProcessingState.completed) &&
            mounted) {}
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

    // Cancelar timer de debounce de notificaciones
    _notificationDebounceTimer?.cancel();
    _lastNotificationMediaItem = null;

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

  /// Actualiza la notificación con debounce para evitar sobrecarga
  void _updateNotificationWithDebounce(MediaItem mediaItem, int index) {
    // Siempre cancelar timer anterior para evitar acumulación
    _notificationDebounceTimer?.cancel();

    // Almacenar la actualización más reciente
    _lastNotificationMediaItem = mediaItem;

    _notificationDebounceTimer = Timer(_notificationDebounceDelay, () {
      if (mounted && _lastNotificationMediaItem != null) {
        // Solo actualizar si realmente cambió algo significativo
        final current = this.mediaItem.value;
        final pending = _lastNotificationMediaItem!;

        bool shouldUpdate =
            current == null ||
            current.id != pending.id ||
            current.duration != pending.duration ||
            current.title != pending.title;

        // Preservar carátula existente si la nueva no tiene carátula
        MediaItem finalPending = pending;
        if (current != null &&
            current.id == pending.id &&
            current.artUri != null &&
            pending.artUri == null) {
          finalPending = pending.copyWith(artUri: current.artUri);
        }

        // Solo actualizar artUri si realmente cambió
        if (current?.artUri != finalPending.artUri) {
          shouldUpdate = true;
        }

        if (shouldUpdate) {
          this.mediaItem.add(finalPending);
          playbackState.add(playbackState.value.copyWith(queueIndex: index));
        }
        _lastNotificationMediaItem = null;
      }
    });
  }

  AudioProcessingState _transformState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  int _loadVersion = 0;

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
      _originalQueue = null;
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
      _originalQueue = null;
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

    // 1. Crear MediaItems básicos inmediatamente (sin verificaciones de archivo)
    _mediaQueue.clear();
    final mediaItems = <MediaItem>[];

    for (int i = 0; i < validSongs.length; i++) {
      final song = validSongs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;

      // No esperes la carátula, crea el MediaItem sin artUri
      Uri? artUri;

      mediaItems.add(
        MediaItem(
          id: song.data,
          album: song.album ?? '',
          title: song.title,
          artist: song.artist ?? '',
          duration: dur,
          artUri: artUri,
          extras: {
            'songId': song.id,
            'albumId': song.albumId,
            'data': song.data,
            'queueIndex': i,
          },
        ),
      );
    }

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

        if (autoPlay) {
          await play();
        }
        // Precargar próximas carátulas tras restaurar/establecer cola
        if (initialIndex >= 0) {
          _preloadNextArtworks(initialIndex);
        }
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

      // Cancelar timer de debounce de notificaciones
      _notificationDebounceTimer?.cancel();

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

  @override
  Future<void> skipToNext() async {
    if (_initializing || _isSkipping) return;

    _isSkipping = true;
    try {
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
      _isManualChange = true;
      try {
        // Cancelar operaciones pendientes antes de cambiar
        _pendingArtworkOperations.clear();
        cancelAllArtworkLoads();

        final wasPlaying = _player.playing;

        // El MediaItem se actualizará automáticamente por el currentIndexStream listener
        playbackState.add(playbackState.value.copyWith(queueIndex: index));

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
      } finally {
        _isManualChange = false;
      }
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode == AudioServiceShuffleMode.all) {
      await _player.setShuffleModeEnabled(true);
      await _player.shuffle();
    } else {
      await _player.setShuffleModeEnabled(false);
    }
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
    // Persistir modo shuffle (solo habilitado/deshabilitado)
    unawaited(() async {
      try {
        await _prefs?.setBool(
          _kPrefShuffleEnabled,
          shuffleMode == AudioServiceShuffleMode.all,
        );
      } catch (_) {}
    }());
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
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
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

  /// Activa o desactiva el modo aleatorio mezclando la lista actual sin repetir canciones y reconstruyendo el audio source
  Future<void> toggleShuffle(bool enable) async {
    // Intervalo mínimo de 1 segundo entre toques
    final now = DateTime.now();
    if (now.difference(_lastShuffleToggle).inMilliseconds < 1000) return;
    _lastShuffleToggle = now;
    if (_mediaQueue.isEmpty) return;
    isQueueTransitioning.value = true;
    final currentIndex = _player.currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _mediaQueue.length) {
      isQueueTransitioning.value = false;
      return;
    }
    final currentItem = _mediaQueue[currentIndex];
    final currentPosition = _player.position;
    final wasPlaying = _player.playing;

    if (enable) {
      isShuffleNotifier.value = true;
      _originalQueue ??= List<MediaItem>.from(_mediaQueue);
      // Mezclar la lista, poniendo la canción actual al inicio
      final currentSongPath = currentItem.id;
      final currentSong = _originalSongList!.firstWhere(
        (s) => s.data == currentSongPath,
      );
      final rest = List<SongModel>.from(_originalSongList!)
        ..removeWhere((s) => s.data == currentSongPath);
      rest.shuffle();
      _currentSongList = [currentSong, ...rest];
      // Reconstruir cola y audio source manteniendo la posición actual
      await setQueueFromSongsWithPosition(
        _currentSongList,
        initialIndex: 0,
        initialPosition: currentPosition,
        autoPlay: false,
        resetShuffle: false,
      );
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
    } else {
      isShuffleNotifier.value = false;
      // Restaurar la lista original solo si existe
      if (_originalSongList != null && _originalQueue != null) {
        final currentSongPath = currentItem.id;
        final idx = _originalSongList!.indexWhere(
          (s) => s.data == currentSongPath,
        );
        if (idx < 0) {
          isQueueTransitioning.value = false;
          return;
        }
        _currentSongList = List<SongModel>.from(_originalSongList!);
        await setQueueFromSongsWithPosition(
          _currentSongList,
          initialIndex: idx,
          initialPosition: currentPosition,
          autoPlay: false,
          resetShuffle: false,
        );
        if (wasPlaying && !_player.playing) {
          await _player.play();
        }
      } else {
        // Ya estamos en la lista original, no hacer nada
      }
      isQueueTransitioning.value = false;
    }
    // Persistir flag de shuffle
    unawaited(() async {
      try {
        await _prefs?.setBool(_kPrefShuffleEnabled, enable);
      } catch (_) {}
    }());
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
      _originalQueue = null;
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
}