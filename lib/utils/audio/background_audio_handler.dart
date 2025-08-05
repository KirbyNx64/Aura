import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'album_art_cache_manager.dart';
import 'optimized_album_art_loader.dart';

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
        androidStopForegroundOnPause: false,
        androidResumeOnClick: true,
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
final Map<String, Uri?> _artworkCache = {};
final Map<String, Future<Uri?>> _preloadCache = {};
final Set<String> _loadingArtworks = {};

Map<String, Uri?> get artworkCache => _artworkCache;

Future<Uri?> getOrCacheArtwork(int songId, String songPath) async {
  // 1. Verifica cache en memoria primero (compatibilidad)
  if (_artworkCache.containsKey(songPath)) {
    return _artworkCache[songPath];
  }
  
  // 2. Verifica si ya se está precargando
  if (_preloadCache.containsKey(songPath)) {
    return await _preloadCache[songPath]!;
  }
  
  // 3. Evita cargas duplicadas
  if (_loadingArtworks.contains(songPath)) {
    // Espera a que termine la carga actual
    while (_loadingArtworks.contains(songPath)) {
      await Future.delayed(const Duration(milliseconds: 10));
      // Si ya se cargó mientras esperaba, retorna inmediatamente
      if (_artworkCache.containsKey(songPath)) {
        return _artworkCache[songPath];
      }
    }
    return _artworkCache[songPath];
  }
  
  // 4. Marca como cargando y crea el Future
  _loadingArtworks.add(songPath);
  final future = _loadArtworkAsyncOptimized(songId, songPath);
  _preloadCache[songPath] = future;
  
  try {
    final result = await future;
    _artworkCache[songPath] = result;
    return result;
  } finally {
    _loadingArtworks.remove(songPath);
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
      final tempDir = await getTemporaryDirectory();
      final file = await File('${tempDir.path}/artwork_$songId.jpg').writeAsBytes(bytes);
      final uri = Uri.file(file.path);
      return uri;
    }
  } catch (e) {
    // Error silencioso, retorna null
  }
  return null;
}

/// Precarga carátulas para una lista de canciones de forma asíncrona
Future<void> preloadArtworks(List<SongModel> songs, {int maxConcurrent = 3}) async {
  // Usar el cargador optimizado para precarga
  final songsToLoad = songs.where((song) => 
    !_artworkCache.containsKey(song.data) && 
    !_preloadCache.containsKey(song.data) &&
    !_loadingArtworks.contains(song.data)
  ).take(10).toList(); // Limitar a 10 canciones para no sobrecargar
  
  if (songsToLoad.isEmpty) return;
  
  // Convertir SongModel a formato requerido por el cargador optimizado
  final songsData = songsToLoad.map((song) => {
    'id': song.id,
    'data': song.data,
  }).toList();
  
  // Usar el cargador optimizado con cancelación
  await _optimizedLoader.loadMultipleAlbumArts(songsData);
}

/// Obtiene el tamaño actual del cache de carátulas
int get artworkCacheSize => _artworkCache.length + _albumArtCacheManager.memoryCacheSize;

/// Limpia el cache de carátulas para liberar memoria
void clearArtworkCache() {
  _artworkCache.clear();
  _preloadCache.clear();
  _loadingArtworks.clear();
  _albumArtCacheManager.clearCache();
}

/// Limpia carátulas específicas del cache
void removeArtworkFromCache(String songPath) {
  _artworkCache.remove(songPath);
  _preloadCache.remove(songPath);
  _loadingArtworks.remove(songPath);
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
  final ValueNotifier<bool> isQueueTransitioning = ValueNotifier(false);
  final ValueNotifier<bool> initializingNotifier = ValueNotifier(false);
  DateTime _lastShuffleToggle = DateTime.fromMillisecondsSinceEpoch(0);
  bool _initializing = true;
  Timer? _sleepTimer;
  Duration? _sleepDuration;
  Duration? _sleepStartPosition;
  bool _isSkipping = false;
  bool _isInitialized = false;

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    if (_isInitialized) return;
    
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      _player.playbackEventStream.listen((event) {
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

      _player.currentIndexStream.listen((index) {
        if (_initializing) return;
        if (index != null && index < _mediaQueue.length) {
          var currentMediaItem = _mediaQueue[index];
          
          // Actualizar el MediaItem inmediatamente (con o sin carátula)
          mediaItem.add(currentMediaItem);
          
          // Cargar carátula de forma asíncrona si no está en caché
          final songPath = currentMediaItem.extras?['data'] as String?;
          final songId = currentMediaItem.extras?['songId'] as int?;
          
          if (songPath != null && songId != null && !_artworkCache.containsKey(songPath)) {
            // Cargar carátula en segundo plano
            unawaited(() async {
              try {
                final artUri = await getOrCacheArtwork(songId, songPath);
                if (artUri != null) {
                  // Actualizar el MediaItem con la carátula cargada
                  final updatedMediaItem = currentMediaItem.copyWith(artUri: artUri);
                  _mediaQueue[index] = updatedMediaItem;
                  queue.add(_mediaQueue);
                  mediaItem.add(updatedMediaItem);
                }
              } catch (e) {
                // Error silencioso
              }
            }());
          } else if (songPath != null && _artworkCache.containsKey(songPath)) {
            // Si la carátula ya está en caché, actualizar inmediatamente
            final artUri = _artworkCache[songPath];
            if (artUri != null && currentMediaItem.artUri != artUri) {
              currentMediaItem = currentMediaItem.copyWith(artUri: artUri);
              _mediaQueue[index] = currentMediaItem;
              queue.add(_mediaQueue);
              mediaItem.add(currentMediaItem);
            }
          }
          
          // Precargar carátulas de canciones próximas
          _preloadNextArtworks(index);
        }
      });

      _player.durationStream.listen((duration) {
        final current = mediaItem.value;
        if (current != null && duration != null && current.duration != duration) {
          mediaItem.add(current.copyWith(duration: duration));
          playbackState.add(
            playbackState.value.copyWith(
              updatePosition: _player.position,
              processingState: playbackState.value.processingState,
            ),
          );
        }
      });

      _player.playingStream.listen((playing) {
        playbackState.add(playbackState.value.copyWith(playing: playing));
      });

      _player.processingStateStream.listen((state) {
        playbackState.add(
          playbackState.value.copyWith(processingState: _transformState(state)),
        );
      });
      
      _isInitialized = true;
    } catch (e) {
      // Si hay error en la inicialización, intentar reinicializar
      _isInitialized = false;
      await Future.delayed(const Duration(milliseconds: 100));
      await _init();
    }
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
    // Verificar si el handler está inicializado correctamente
    if (!_isInitialized) {
      await _init();
    }
    
    // Solo desactiva shuffle si la lista realmente cambia y resetShuffle es true
    bool shouldResetShuffle = false;
    if (resetShuffle && (_originalSongList == null || !_areSongListsEqual(_originalSongList!, songs))) {
      shouldResetShuffle = true;
    }
    if (shouldResetShuffle) {
      isShuffleNotifier.value = false;
      _originalQueue = null;
      _originalSongList = null;
    }
    _currentSongList = List<SongModel>.from(songs);
    isQueueTransitioning.value = true;
    initializingNotifier.value = true;
    _initializing = true;
    _loadVersion++;
    final int currentVersion = _loadVersion;

    // Guardar la lista original solo la primera vez
    if (_originalSongList == null || _originalSongList!.isEmpty) {
      _originalSongList = List<SongModel>.from(songs);
    }

    // Validar el índice inicial
    if (initialIndex < 0 || initialIndex >= songs.length) {
      initialIndex = 0;
    }

    // 1. Crear MediaItems básicos inmediatamente (sin verificaciones de archivo)
    _mediaQueue.clear();
    final mediaItems = <MediaItem>[];
    
    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
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
    queue.add(_mediaQueue);

    // 2. Crear AudioSources sin verificación de archivos (just_audio maneja errores)
    final sources = songs.map((song) => AudioSource.uri(Uri.file(song.data))).toList();

    // 3. Cargar fuentes en el reproductor de forma asíncrona con timeout
    Future.delayed(Duration.zero, () async {
      try {
        await _player.setAudioSources(
          sources,
          initialIndex: initialIndex,
          initialPosition: Duration.zero,
        ).timeout(
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
            mediaItem.add(selectedMediaItem);
          }
        }
        
        // Finalizar la inicialización
        _initializing = false;
        initializingNotifier.value = false;
        isQueueTransitioning.value = false;
        
        if (autoPlay) {
          await play();
        }
      } catch (e) {
        // Si falla, intentar con una sola canción
        if (songs.isNotEmpty) {
          try {
            final firstSong = songs.first;
            final firstSource = AudioSource.uri(Uri.file(firstSong.data));
            await _player.setAudioSource(firstSource);
            if (_mediaQueue.isNotEmpty) {
              mediaItem.add(_mediaQueue.first);
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
    
    try {
      await _player.play();
    } catch (e) {
      // Si hay error, intentar reinicializar y reproducir
      try {
        await _reinitializePlayer();
        await _player.play();
      } catch (e2) {
        // Error crítico, no hacer nada
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
      // Detener y limpiar el reproductor completamente
      await _player.stop();
      await _player.dispose();
      
      // Limpiar la sesión de audio
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
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
        await _player.seekToNext();
        _updateSleepTimer();
    } catch (e) {
      // Error silencioso
    } finally {
      // Liberar el flag inmediatamente para permitir más operaciones
      Future.delayed(const Duration(milliseconds: 50), () {
        _isSkipping = false;
      });
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_initializing || _isSkipping) return;
    
    _isSkipping = true;
    try {
      if (_player.position.inMilliseconds > 5000) {
        await _player.seek(Duration.zero);
      } else {
        await _player.seekToPrevious();
      }
      _updateSleepTimer();
    } catch (e) {
      // Error silencioso
    } finally {
      // Liberar el flag inmediatamente para permitir más operaciones
      Future.delayed(const Duration(milliseconds: 50), () {
        _isSkipping = false;
      });
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_initializing) return;
    if (index >= 0 && index < _mediaQueue.length) {
      try {
        final wasPlaying = _player.playing;
        
        // Actualizar inmediatamente el MediaItem para evitar lag visual
        final newMediaItem = _mediaQueue[index];
        mediaItem.add(newMediaItem);
        
        // Ejecutar el seek de forma completamente asíncrona
        unawaited(() async {
          try {
            await _player.seek(Duration.zero, index: index);
            
            // Cargar carátula de forma asíncrona si no está en caché
            final songPath = newMediaItem.extras?['data'] as String?;
            final songId = newMediaItem.extras?['songId'] as int?;
            
            if (songPath != null && songId != null && !_artworkCache.containsKey(songPath)) {
              unawaited(() async {
                try {
                  final artUri = await getOrCacheArtwork(songId, songPath);
                  if (artUri != null) {
                    final updatedMediaItem = newMediaItem.copyWith(artUri: artUri);
                    _mediaQueue[index] = updatedMediaItem;
                    queue.add(_mediaQueue);
                    mediaItem.add(updatedMediaItem);
                  }
                } catch (e) {
                  // Error silencioso
                }
              }());
            }
            
            // Precargar carátulas de canciones próximas
            _preloadNextArtworks(index);
            
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
    if (shuffleMode == AudioServiceShuffleMode.all) {
      await _player.setShuffleModeEnabled(true);
      await _player.shuffle();
    } else {
      await _player.setShuffleModeEnabled(false);
    }
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
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
    if (currentIndex == null || currentIndex < 0 || currentIndex >= _mediaQueue.length) {
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
      final currentSong = _originalSongList!.firstWhere((s) => s.data == currentSongPath);
      final rest = List<SongModel>.from(_originalSongList!)..removeWhere((s) => s.data == currentSongPath);
      rest.shuffle();
      _currentSongList = [currentSong, ...rest];
      // Reconstruir cola y audio source
      await setQueueFromSongs(_currentSongList, initialIndex: 0, autoPlay: false, resetShuffle: false);
      await _player.seek(currentPosition, index: 0);
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
    } else {
      isShuffleNotifier.value = false;
      // Restaurar la lista original solo si existe
      if (_originalSongList != null && _originalQueue != null) {
        final currentSongPath = currentItem.id;
        final idx = _originalSongList!.indexWhere((s) => s.data == currentSongPath);
        if (idx < 0) {
          isQueueTransitioning.value = false;
          return;
        }
        _currentSongList = List<SongModel>.from(_originalSongList!);
        await setQueueFromSongs(_currentSongList, initialIndex: idx, autoPlay: false, resetShuffle: false);
        await _player.seek(currentPosition, index: idx);
        if (wasPlaying && !_player.playing) {
          await _player.play();
        }
      } else {
        // Ya estamos en la lista original, no hacer nada
      }
      isQueueTransitioning.value = false;
    }
  }

  Stream<Duration> get positionStream => _player.positionStream;

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

  /// Precarga carátulas de canciones próximas
  void _preloadNextArtworks(int currentIndex) {
    if (_currentSongList.isEmpty) return;
    
    // Precargar las siguientes 3 canciones
    final nextIndices = <int>[];
    for (int i = 1; i <= 3; i++) {
      final nextIndex = currentIndex + i;
      if (nextIndex < _currentSongList.length) {
        nextIndices.add(nextIndex);
      }
    }
    
    // Precargar carátulas de forma asíncrona
    unawaited(() async {
      try {
        for (final index in nextIndices) {
          final song = _currentSongList[index];
          if (!_artworkCache.containsKey(song.data)) {
            unawaited(getOrCacheArtwork(song.id, song.data));
          }
        }
      } catch (e) {
        // Error silencioso
      }
    }());
  }

  /// Reinicializa el reproductor cuando es necesario
  Future<void> _reinitializePlayer() async {
    try {
      await _player.stop();
      await _player.dispose();
      
      final newPlayer = AudioPlayer();
      _player = newPlayer;
      await _initListeners();
    } catch (e) {
      _player = AudioPlayer();
    }
  }

  /// Inicializa solo los listeners del reproductor sin configurar nueva sesión
  Future<void> _initListeners() async {
    _player.playbackEventStream.listen((event) {
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

    _player.currentIndexStream.listen((index) {
      if (_initializing) return;
      if (index != null && index < _mediaQueue.length) {
        var currentMediaItem = _mediaQueue[index];
        
        // Actualizar inmediatamente el MediaItem (con o sin carátula)
        mediaItem.add(currentMediaItem);
        
        // Cargar carátula de forma asíncrona si no está en caché
        final songPath = currentMediaItem.extras?['data'] as String?;
        final songId = currentMediaItem.extras?['songId'] as int?;
        
        if (songPath != null && songId != null && !_artworkCache.containsKey(songPath)) {
          // Cargar carátula en segundo plano
          unawaited(() async {
            try {
              final artUri = await getOrCacheArtwork(songId, songPath);
              if (artUri != null) {
                // Actualizar el MediaItem con la carátula cargada
                final updatedMediaItem = currentMediaItem.copyWith(artUri: artUri);
                _mediaQueue[index] = updatedMediaItem;
                queue.add(_mediaQueue);
                mediaItem.add(updatedMediaItem);
              }
            } catch (e) {
              // Error silencioso
            }
          }());
        } else if (songPath != null && _artworkCache.containsKey(songPath)) {
          // Si la carátula ya está en caché, actualizar inmediatamente
          final artUri = _artworkCache[songPath];
          if (artUri != null && currentMediaItem.artUri != artUri) {
            currentMediaItem = currentMediaItem.copyWith(artUri: artUri);
            _mediaQueue[index] = currentMediaItem;
            queue.add(_mediaQueue);
            mediaItem.add(currentMediaItem);
          }
        }
        
        // Precargar carátulas de canciones próximas
        _preloadNextArtworks(index);
      }
    });

    _player.durationStream.listen((duration) {
      final current = mediaItem.value;
      if (current != null && duration != null && current.duration != duration) {
        mediaItem.add(current.copyWith(duration: duration));
        playbackState.add(
          playbackState.value.copyWith(
            updatePosition: _player.position,
            processingState: playbackState.value.processingState,
          ),
        );
      }
    });

    _player.playingStream.listen((playing) {
      playbackState.add(playbackState.value.copyWith(playing: playing));
    });

    _player.processingStateStream.listen((state) {
      playbackState.add(
        playbackState.value.copyWith(processingState: _transformState(state)),
      );
    });
  }

  @override
  Future customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == "saveSession") {
      await stop();
    }
    return super.customAction(name, extras);
  }
}