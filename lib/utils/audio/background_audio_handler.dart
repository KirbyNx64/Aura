import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:music/utils/db/artwork_db.dart';
import 'package:flutter/foundation.dart';

Future<AudioHandler> initAudioService() {
  return AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.aura.music.channel',
      androidNotificationChannelName: 'Aura Music',
      androidNotificationOngoing: true,
      // androidNotificationIcon: 'mipmap/ic_stat_music_note',
    ),
  );
}

// Cache global para carátulas en memoria
final Map<String, Uri?> _artworkCache = {};

Future<Uri?> getOrCacheArtwork(int songId, String songPath) async {
  // 1. Verifica cache en memoria primero
  if (_artworkCache.containsKey(songPath)) {
    return _artworkCache[songPath];
  }
  
  // 2. Busca en la base de datos
  final cachedPath = await ArtworkDB.getArtwork(songPath);
  if (cachedPath != null && await File(cachedPath).exists()) {
    final uri = Uri.file(cachedPath);
    _artworkCache[songPath] = uri;
    return uri;
  }
  
  // 3. Si no existe, descarga y guarda
  try {
    final albumArt = await OnAudioQuery().queryArtwork(
      songId,
      ArtworkType.AUDIO,
      size: 256, // Tamaño reducido para mejor rendimiento
    );
    if (albumArt != null) {
      final tempDir = await getTemporaryDirectory();
      final file = await File('${tempDir.path}/artwork_$songId.jpg').writeAsBytes(albumArt);
      await ArtworkDB.insertArtwork(songPath, file.path);
      final uri = Uri.file(file.path);
      _artworkCache[songPath] = uri;
      return uri;
    }
  } catch (e) {
    // Si falla, guarda null en cache para evitar reintentos
    _artworkCache[songPath] = null;
  }
  
  _artworkCache[songPath] = null;
  return null;
}

/// Limpia el cache de carátulas para liberar memoria
void clearArtworkCache() {
  _artworkCache.clear();
}

/// Obtiene el tamaño actual del cache de carátulas
int get artworkCacheSize => _artworkCache.length;

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _mediaQueue = [];
  final ValueNotifier<bool> initializingNotifier = ValueNotifier(false);
  bool _initializing = true;
  Timer? _sleepTimer;
  Duration? _sleepDuration;
  Duration? _sleepStartPosition;
  bool _isSeekingOrLoading = false;
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 100);

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _player.playbackEventStream.listen((event) async {
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

      if (event.processingState == ProcessingState.completed &&
          _player.loopMode == LoopMode.one) {
        await _player.seek(Duration.zero);
        await _player.play();
      }
    });

    _player.currentIndexStream.listen((index) {
      if (_initializing) return;
      if (index != null && index < _mediaQueue.length) {
        mediaItem.add(_mediaQueue[index]);
        
        // Carga la carátula inmediatamente si no la tiene
        final currentMediaItem = _mediaQueue[index];
        if (currentMediaItem.artUri == null) {
          loadArtworkForIndex(index);
        }
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
  static const int _batchSize = 20; // Tamaño del lote para carga en segundo plano

  Future<void> setQueueFromSongs(
    List<SongModel> songs, {
    int initialIndex = 0,
    bool autoPlay = false,
  }) async {
    initializingNotifier.value = true;
    _initializing = true;
    _loadVersion++;
    final int currentVersion = _loadVersion;

    // Optimización para listas grandes: limita la carga inicial
    final int totalSongs = songs.length;
    
    // Calcula la ventana de carga inicial alrededor del índice inicial
    final int start = (initialIndex - 5).clamp(0, totalSongs - 1);
    final int end = (initialIndex + 5).clamp(0, totalSongs - 1);

    // 1. Precarga carátulas en paralelo solo para la ventana inicial
    final artworkPromises = <Future<void>>[];
    for (int i = start; i <= end; i++) {
      artworkPromises.add(getOrCacheArtwork(songs[i].id, songs[i].data));
    }
    await Future.wait(artworkPromises);

    // 2. Prepara las fuentes de audio correctamente
    final sources = <AudioSource>[
      for (final song in songs)
        AudioSource.uri(Uri.file(song.data)),
    ];

    // 3. Prepara solo los MediaItem de la ventana inicial
    final items = <MediaItem>[];
    for (int i = start; i <= end; i++) {
      final song = songs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;

      if (i == initialIndex && dur == null) {
        try {
          final audioSource = AudioSource.uri(Uri.file(song.data));
          await _player.setAudioSource(audioSource, preload: false);
          dur = await _player.setFilePath(song.data);
        } catch (e) {
          // Si falla, asigna una duración nula
        }
      }

      Uri? artUri = await getOrCacheArtwork(song.id, song.data);
      items.add(
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
          },
        ),
      );
    }

    // 4. Carga inicial optimizada: solo MediaItem básicos sin carátulas
    _mediaQueue.clear();
    final initialMediaItems = <MediaItem>[];
    
    // Para listas grandes, carga solo información básica inicialmente
    for (int i = 0; i < totalSongs; i++) {
      final song = songs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;
      
      // Solo carga carátulas para la ventana inicial
      Uri? artUri;
      if (i >= start && i <= end) {
        artUri = await getOrCacheArtwork(song.id, song.data);
      }
      
      initialMediaItems.add(
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
          },
        ),
      );
    }
    
    _mediaQueue.addAll(initialMediaItems);
    queue.add(_mediaQueue);

    if (currentVersion != _loadVersion) return;

    // 5. Carga todas las fuentes en el reproductor
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
      );
      if (currentVersion != _loadVersion) return;
      
      // Espera optimizada para que el reproductor esté listo
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 30) {
        await Future.delayed(const Duration(milliseconds: 30));
        attempts++;
      }
      
      if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
        mediaItem.add(_mediaQueue[initialIndex]);
      }
    } catch (e) {
      // print('👻 Error al cargar las fuentes de audio: $e');
    }

    // 6. Carga en segundo plano optimizada por lotes
    // Siempre carga las carátulas restantes, independientemente del tamaño de la lista
    _loadRemainingMediaItemsInBackground(songs, start, end, currentVersion);
    _initializing = false;
    initializingNotifier.value = false;

    if (autoPlay) {
      await play();
    }
  }

  AudioPlayer get player => _player;

  @override
  Future<void> play() async {
    final current = mediaItem.value;
    final duration = _player.duration;
    if (current != null && duration != null && current.duration != duration) {
      mediaItem.add(current.copyWith(duration: duration));
      // Espera un microtask para asegurar que la notificación se refresque
      await Future.delayed(Duration.zero);
    }
    try {
      await _player.play();
    } catch (e) {
      // Manejo de errores al intentar reproducir
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
      // Limpia el timer de debounce
      _debounceTimer?.cancel();
      _isSeekingOrLoading = false;
      
      // Limpia el cache de carátulas si es muy grande
      if (artworkCacheSize > 100) {
        clearArtworkCache();
      }
      
      await _player.stop();
      await _player.dispose();
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
    } catch (e) {
      // Manejo de errores al intentar detener
    }
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    // Actualiza el temporizador cuando se cambia la posición
    _updateSleepTimer();
  }

  @override
  Future<void> skipToNext() async {
    if (_initializing) return;
    
    // Debounce para evitar cambios demasiado rápidos
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () async {
      await _performSkipToNext();
    });
  }

  Future<void> _performSkipToNext() async {
    if (_isSeekingOrLoading) return;
    
    _isSeekingOrLoading = true;
    try {
      final wasPlaying = _player.playing;
      await _player.seekToNext();
      
      // Espera optimizada
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 15) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Actualiza el temporizador cuando cambia de canción
      _updateSleepTimer();
      
      // Solo reproduce si estaba reproduciendo antes del cambio
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
    } catch (e) {
      // Manejo de errores al cambiar de canción
    } finally {
      _isSeekingOrLoading = false;
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_initializing) return;
    
    // Debounce para evitar cambios demasiado rápidos
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () async {
      await _performSkipToPrevious();
    });
  }

  Future<void> _performSkipToPrevious() async {
    if (_isSeekingOrLoading) return;
    
    _isSeekingOrLoading = true;
    try {
      final wasPlaying = _player.playing;
      await _player.seekToPrevious();
      
      // Espera optimizada
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 15) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Actualiza el temporizador cuando cambia de canción
      _updateSleepTimer();
      
      // Solo reproduce si estaba reproduciendo antes del cambio
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
    } catch (e) {
      // Manejo de errores al cambiar de canción
    } finally {
      _isSeekingOrLoading = false;
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_initializing) return;
    if (index >= 0 && index < _mediaQueue.length) {
      // Debounce para evitar cambios demasiado rápidos
      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDelay, () async {
        await _performSkipToQueueItem(index);
      });
    }
  }

  Future<void> _performSkipToQueueItem(int index) async {
    if (_isSeekingOrLoading) return;
    
    _isSeekingOrLoading = true;
    try {
      final wasPlaying = _player.playing;
      await _player.seek(Duration.zero, index: index);
      
      // Espera optimizada
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 15) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Actualiza el temporizador cuando cambia de canción
      _updateSleepTimer();
      
      // Solo reproduce si estaba reproduciendo antes del cambio
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
    } catch (e) {
      // Manejo de errores
    } finally {
      _isSeekingOrLoading = false;
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

  /// Carga los MediaItem restantes en segundo plano por lotes
  Future<void> _loadRemainingMediaItemsInBackground(
    List<SongModel> songs,
    int initialStart,
    int initialEnd,
    int loadVersion,
  ) async {
    // Si la versión de carga cambió, cancela la operación
    if (loadVersion != _loadVersion) return;

    final int totalSongs = songs.length;
    
    // Carga por lotes para evitar sobrecarga
    for (int batchStart = 0; batchStart < totalSongs; batchStart += _batchSize) {
      // Si la versión de carga cambió, cancela la operación
      if (loadVersion != _loadVersion) return;
      
      final int batchEnd = (batchStart + _batchSize - 1).clamp(0, totalSongs - 1);
      
      // Carga carátulas para todas las canciones que no están en la ventana inicial
      await _loadBatchMediaItems(songs, batchStart, batchEnd, loadVersion, initialStart, initialEnd);
      
      // Pequeña pausa entre lotes para no sobrecargar el sistema
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Carga un lote de MediaItem con carátulas
  Future<void> _loadBatchMediaItems(
    List<SongModel> songs,
    int start,
    int end,
    int loadVersion,
    int initialStart,
    int initialEnd,
  ) async {
    if (loadVersion != _loadVersion) return;
    
    final batchPromises = <Future<void>>[];
    
    for (int i = start; i <= end; i++) {
      if (i < _mediaQueue.length) {
        // Solo carga carátulas para canciones que no están en la ventana inicial
        if (i < initialStart || i > initialEnd) {
          batchPromises.add(_loadSingleMediaItem(songs[i], i, loadVersion));
        }
      }
    }
    
    await Future.wait(batchPromises);
    
    // Actualiza la cola solo si la versión no cambió
    if (loadVersion == _loadVersion) {
      queue.add(_mediaQueue);
    }
  }

  /// Carga un solo MediaItem con carátula
  Future<void> _loadSingleMediaItem(
    SongModel song,
    int index,
    int loadVersion,
  ) async {
    if (loadVersion != _loadVersion || index >= _mediaQueue.length) return;
    
    try {
      final artUri = await getOrCacheArtwork(song.id, song.data);
      
      if (loadVersion == _loadVersion && index < _mediaQueue.length) {
        _mediaQueue[index] = _mediaQueue[index].copyWith(artUri: artUri);
      }
    } catch (e) {
      // Si falla la carga de carátula, mantiene el MediaItem sin carátula
    }
  }

  /// Carga la carátula de una canción específica de forma inmediata
  Future<void> loadArtworkForIndex(int index) async {
    if (index < 0 || index >= _mediaQueue.length) return;
    
    final mediaItem = _mediaQueue[index];
    if (mediaItem.artUri != null) return; // Ya tiene carátula
    
    // Busca la canción correspondiente
    final songId = mediaItem.extras?['songId'] as int?;
    final songPath = mediaItem.extras?['data'] as String?;
    
    if (songId != null && songPath != null) {
      try {
        final artUri = await getOrCacheArtwork(songId, songPath);
        if (index < _mediaQueue.length) {
          _mediaQueue[index] = _mediaQueue[index].copyWith(artUri: artUri);
          queue.add(_mediaQueue);
        }
      } catch (e) {
        // Si falla, no hace nada
      }
    }
  }
}