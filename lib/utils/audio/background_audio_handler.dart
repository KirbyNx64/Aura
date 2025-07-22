import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Variable global para rastrear si el AudioHandler ya está inicializado
// AudioHandler? _currentInstance;

AudioHandler? _audioHandler;

Future<AudioHandler> initAudioService() async {
  // print('🎵 Iniciando AudioService...');
  if (_audioHandler != null) {
    // print('✅ AudioHandler ya existe, retornando...');
    return _audioHandler!;
  }
  
  try {
    // print('🧹 Limpieza inicial...');
    // Limpieza robusta antes de inicializar
    await _forceCleanupAudioService();
    await Future.delayed(const Duration(milliseconds: 25));
    
    // print('🔍 Verificando servicios obsoletos...');
    // Verificar si hay un servicio de audio activo que pueda causar conflictos
    await _checkAndCleanStaleAudioService();
    
    // print('🚀 Inicializando AudioService...');
    _audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationIcon: 'mipmap/ic_stat_music_note',
        androidNotificationChannelId: 'com.aura.music.channel',
        androidNotificationChannelName: 'Aura Music',
        androidNotificationOngoing: true,
        // androidStopForegroundOnPause: false, // true en debug
        androidResumeOnClick: true,
      ),
    ).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // print('⏰ Timeout en inicialización de AudioService');
        throw Exception('Timeout al inicializar AudioService');
      },
    );
    
    // Verificar que la inicialización fue exitosa
    if (_audioHandler == null) {
      throw Exception('AudioHandler no se inicializó correctamente');
    }
    
    // print('✅ AudioService inicializado correctamente');
    return _audioHandler!;
  } catch (e) {
    // print('❌ Error al inicializar AudioService: $e');
    // Limpiar en caso de error
    _audioHandler = null;
    throw Exception('Error al inicializar AudioService: $e');
  }
}

/// Verifica y limpia servicios de audio obsoletos que puedan causar conflictos
Future<void> _checkAndCleanStaleAudioService() async {
  // print('🧹 Verificando servicios de audio obsoletos...');
  try {
    // Intentar múltiples limpiezas para asegurar que no hay servicios residuales
    for (int i = 0; i < 3; i++) {
      try {
        await _audioHandler!.stop();

        // print('🧹 Limpieza $i completada');
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 25));
    }
    
    // Limpieza adicional más agresiva para casos de cierre forzado
    //print('🔥 Limpieza agresiva adicional...');
    for (int i = 0; i < 3; i++) {
      try {
        // Intentar detener cualquier servicio de audio que pueda estar activo
        await _audioHandler?.stop();
        // También limpiar la sesión de audio
        final session = await AudioSession.instance;
        await session.setActive(false);
        // print('🔥 Limpieza agresiva $i completada');
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 25));
    }
    
    // print('✅ Verificación de servicios completada');
  } catch (_) {}
}

/// Limpia de forma forzada cualquier instancia previa del AudioService
Future<void> _forceCleanupAudioService() async {
  // print('🧹 Limpieza forzada iniciada...');
  try {
    // Primero intentar detener el handler si existe
    if (_audioHandler != null) {
      try {
        // print('🛑 Deteniendo AudioHandler...');
        await _audioHandler?.stop();
        // print('✅ AudioHandler detenido');
      } catch (_) {}
    }
    
    // Luego intentar detener el servicio global como fallback
    try {
      // print('🛑 Deteniendo AudioService global...');
      await _audioHandler?.stop();
      // print('✅ AudioService global detenido');
    } catch (_) {}
    
    // Limpiar la AudioSession explícitamente
    try {
      // print('🧹 Limpiando AudioSession...');
      final session = await AudioSession.instance;
      await session.setActive(false);
      // print('✅ AudioSession limpiada');
    } catch (_) {}
  } catch (_) {}
  
  _audioHandler = null;
  // print('🧹 Variable global limpiada');
  
  // Esperar más tiempo para asegurar limpieza completa
  await Future.delayed(const Duration(milliseconds: 25));
  // print('✅ Limpieza forzada completada');
}

/// Función pública para limpiar el AudioHandler (útil para debugging)
Future<void> cleanupAudioHandler() async {
  await _forceCleanupAudioService();
}

// Cache global para carátulas en memoria (simplificado)
final Map<String, Uri?> _artworkCache = {};
// Cache para precarga de carátulas
final Map<String, Future<Uri?>> _preloadCache = {};

Future<Uri?> getOrCacheArtwork(int songId, String songPath) async {
  // 1. Verifica cache en memoria primero
  if (_artworkCache.containsKey(songPath)) {
    return _artworkCache[songPath];
  }
  // 2. Verifica si ya se está precargando
  if (_preloadCache.containsKey(songPath)) {
    return await _preloadCache[songPath]!;
  }
  // 3. Intenta extraer la carátula embebida directamente del archivo usando OnAudioQuery
  int size = 410; // Tamaño por defecto (80%)
  try {
    final prefs = await SharedPreferences.getInstance();
    size = prefs.getInt('artwork_quality') ?? 410; // 80% por defecto
  } catch (_) {}
  try {
    final albumArt = await OnAudioQuery().queryArtwork(
      songId,
      ArtworkType.AUDIO,
      size: size,
    );
    if (albumArt != null) {
      final tempDir = await getTemporaryDirectory();
      final file = await File('${tempDir.path}/artwork_$songId.jpg').writeAsBytes(albumArt);
      final uri = Uri.file(file.path);
      _artworkCache[songPath] = uri;
      return uri;
    }
  } catch (e) {
    _artworkCache[songPath] = null;
  }
  _artworkCache[songPath] = null;
  return null;
}



/// Precarga carátulas para una lista de canciones
Future<void> preloadArtworks(List<SongModel> songs) async {
  for (final song in songs) {
    if (!_artworkCache.containsKey(song.data) && !_preloadCache.containsKey(song.data)) {
      _preloadCache[song.data] = _loadArtworkAsync(song.id, song.data);
    }
  }
}

/// Carga carátula de forma asíncrona
Future<Uri?> _loadArtworkAsync(int songId, String songPath) async {
  try {
    final result = await getOrCacheArtwork(songId, songPath);
    _preloadCache.remove(songPath);
    return result;
  } catch (e) {
    _preloadCache.remove(songPath);
    return null;
  }
}

/// Limpia el cache de carátulas para liberar memoria
void clearArtworkCache() {
  _artworkCache.clear();
  _preloadCache.clear();
}

/// Obtiene el tamaño actual del cache de carátulas
int get artworkCacheSize => _artworkCache.length;

/// Precarga carátulas de canciones recientes y favoritas
Future<void> preloadCommonArtworks() async {
  try {
    // Precargar carátulas de canciones recientes
    final recentSongs = await RecentsDB().getRecents();
    final limitedRecents = recentSongs.take(20).toList();
    unawaited(preloadArtworks(limitedRecents));
    
    // Precargar carátulas de favoritos
    final favoriteSongs = await FavoritesDB().getFavorites();
    final limitedFavorites = favoriteSongs.take(20).toList();
    unawaited(preloadArtworks(limitedFavorites));
  } catch (e) {
    // Ignorar errores de precarga
  }
}

/// Precarga carátulas para una playlist específica
Future<void> preloadPlaylistArtworks(int playlistId) async {
  try {
    final playlistSongs = await PlaylistsDB().getSongsFromPlaylist(playlistId);
    unawaited(preloadArtworks(playlistSongs));
  } catch (e) {
    // Ignorar errores de precarga
  }
}

/// Precarga carátulas para canciones más reproducidas
Future<void> preloadMostPlayedArtworks() async {
  try {
    final mostPlayedSongs = await MostPlayedDB().getMostPlayed();
    final limitedMostPlayed = mostPlayedSongs.take(30).toList();
    unawaited(preloadArtworks(limitedMostPlayed));
  } catch (e) {
    // Ignorar errores de precarga
  }
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

  MyAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    
    // Precargar carátulas comunes en segundo plano
    unawaited(preloadCommonArtworks());

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

    _player.currentIndexStream.listen((index) async {
      if (_initializing) return;
      if (index != null && index < _mediaQueue.length) {
        var currentMediaItem = _mediaQueue[index];
        // Verificar que el índice coincida con el esperado
        final expectedIndex = currentMediaItem.extras?['queueIndex'] as int?;
        if (expectedIndex != null && index != expectedIndex) {
          // print('⚠️ Desincronización de índices: actual=$index, esperado=$expectedIndex');
        }
        // Si la carátula ya está en caché, actualizar el MediaItem inmediatamente
        final songPath = currentMediaItem.extras?['data'] as String?;
        if (songPath != null && _artworkCache.containsKey(songPath)) {
          final artUri = _artworkCache[songPath];
          if (artUri != null && currentMediaItem.artUri != artUri) {
            currentMediaItem = currentMediaItem.copyWith(artUri: artUri);
            _mediaQueue[index] = currentMediaItem;
            queue.add(_mediaQueue);
          }
        }
        mediaItem.add(currentMediaItem);
        // Si no tiene carátula, intenta cargarla
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
    bool resetShuffle = true, // nuevo parámetro
  }) async {
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
      
      // Cargar carátula inmediatamente solo para la canción actual
      Uri? artUri;
      if (i == initialIndex) {
        try {
          artUri = await getOrCacheArtwork(song.id, song.data);
        } catch (e) {
          // Si falla, continuar sin carátula
        }
      }
      
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

    // Precargar carátulas para toda la lista en segundo plano
    unawaited(preloadArtworks(songs));

    // 3. Cargar fuentes en el reproductor inmediatamente
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
      );
      
      if (currentVersion != _loadVersion) return;
      
      // Espera mínima para que el reproductor esté listo
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 10) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Establecer el MediaItem actual
      if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
        final selectedMediaItem = _mediaQueue[initialIndex];
        // Solo emitir si la canción realmente cambia
        if (mediaItem.value?.id != selectedMediaItem.id) {
          mediaItem.add(selectedMediaItem);
        }
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
    }

    // 4. Precargar carátulas inmediatamente
    unawaited(preloadArtworks(songs));
    
    // 5. Cargar carátulas en segundo plano (sin bloquear)
    unawaited(_loadArtworkInBackground(songs, currentVersion, initialIndex));
    
    _initializing = false;
    initializingNotifier.value = false;
    isQueueTransitioning.value = false;

    if (autoPlay) {
      await play();
    }
  }

  /// Carga carátulas en segundo plano sin bloquear la UI
  Future<void> _loadArtworkInBackground(List<SongModel> songs, int loadVersion, int initialIndex) async {
    if (loadVersion != _loadVersion) return;
    
    try {
      // Cargar carátulas para toda la lista de una sola vez, saltando la canción actual
      for (int i = 0; i < songs.length; i++) {
        if (loadVersion != _loadVersion) return;
        // Saltar la canción actual ya que su carátula ya se cargó
        if (i != initialIndex && i < _mediaQueue.length) {
          try {
            final artUri = await getOrCacheArtwork(songs[i].id, songs[i].data);
            if (loadVersion == _loadVersion && i < _mediaQueue.length) {
              _mediaQueue[i] = _mediaQueue[i].copyWith(artUri: artUri);
            }
          } catch (e) {
            // Ignorar errores de carátulas
          }
        }
      }
      // Actualizar la cola con las carátulas cargadas
      if (loadVersion == _loadVersion) {
        queue.add(_mediaQueue);
      }
    } catch (e) {
      // Ignorar errores de carga de carátulas
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
      // Limpia el cache de carátulas si es muy grande
      if (artworkCacheSize > 100) {
        clearArtworkCache();
      }
      
      // Detener y limpiar el reproductor completamente
      await _player.stop();
      await _player.dispose();
      
      // Limpiar la sesión de audio
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      } catch (e) {
        // print('⚠️ Error al limpiar sesión de audio: $e');
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
      
      // Limpia archivos faltantes de las bases de datos en segundo plano
      cleanMissingFilesFromDatabases();
      
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
      final wasPlaying = _player.playing;
      final currentIndex = _player.currentIndex;
      await _player.seekToNext();
      
      // Esperar a que el reproductor esté listo
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 5) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Verificar que realmente cambió de canción
      final newIndex = _player.currentIndex;
      if (newIndex == currentIndex && currentIndex != null && currentIndex < _mediaQueue.length - 1) {
        // Si no cambió, intentar manualmente
        await _player.seek(Duration.zero, index: currentIndex + 1);
      }
      
      _updateSleepTimer();
      
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
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
      final wasPlaying = _player.playing;
      final currentIndex = _player.currentIndex;
      await _player.seekToPrevious();
      
      // Esperar a que el reproductor esté listo
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 5) {
        await Future.delayed(const Duration(milliseconds: 10));
        attempts++;
      }
      
      // Verificar que realmente cambió de canción
      final newIndex = _player.currentIndex;
      if (newIndex == currentIndex && currentIndex != null && currentIndex > 0) {
        // Si no cambió, intentar manualmente
        await _player.seek(Duration.zero, index: currentIndex - 1);
      }
      
      _updateSleepTimer();
      
      if (wasPlaying && !_player.playing) {
        await _player.play();
      }
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
        final wasPlaying = _player.playing;
        await _player.seek(Duration.zero, index: index);
        
        // Esperar a que el reproductor esté listo
        int attempts = 0;
        while (_player.processingState != ProcessingState.ready && attempts < 5) {
          await Future.delayed(const Duration(milliseconds: 10));
          attempts++;
        }
        
        _updateSleepTimer();
        
        if (wasPlaying && !_player.playing) {
          await _player.play();
        }
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

    _player.currentIndexStream.listen((index) async {
      if (_initializing) return;
      if (index != null && index < _mediaQueue.length) {
        var currentMediaItem = _mediaQueue[index];
        // Verificar que el índice coincida con el esperado
        final expectedIndex = currentMediaItem.extras?['queueIndex'] as int?;
        if (expectedIndex != null && index != expectedIndex) {
          // print('⚠️ Desincronización de índices: actual=$index, esperado=$expectedIndex');
        }
        // Si la carátula ya está en caché, actualizar el MediaItem inmediatamente
        final songPath = currentMediaItem.extras?['data'] as String?;
        if (songPath != null && _artworkCache.containsKey(songPath)) {
          final artUri = _artworkCache[songPath];
          if (artUri != null && currentMediaItem.artUri != artUri) {
            currentMediaItem = currentMediaItem.copyWith(artUri: artUri);
            _mediaQueue[index] = currentMediaItem;
            queue.add(_mediaQueue);
          }
        }
        mediaItem.add(currentMediaItem);
        // Si no tiene carátula, intenta cargarla
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

  @override
  Future customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == "saveSession") {
      await stop();
    }
    return super.customAction(name, extras);
  }

  /// Limpia archivos faltantes de las bases de datos
  static Future<void> cleanMissingFilesFromDatabases() async {
    try {
      // Importar las clases de base de datos
      final recentDB = RecentsDB();
      final favoritesDB = FavoritesDB();
      final mostPlayedDB = MostPlayedDB();
      final playlistsDB = PlaylistsDB();
      
      // Obtener todas las rutas de archivos de las bases de datos
      final recentPaths = await _getAllPathsFromRecents(recentDB);
      final favoritePaths = await _getAllPathsFromFavorites(favoritesDB);
      final mostPlayedPaths = await _getAllPathsFromMostPlayed(mostPlayedDB);
      final playlistPaths = await _getAllPathsFromPlaylists(playlistsDB);
      
      // Verificar y limpiar archivos faltantes
      await _cleanMissingPaths(recentDB, recentPaths, 'recents');
      await _cleanMissingPaths(favoritesDB, favoritePaths, 'favorites');
      await _cleanMissingPaths(mostPlayedDB, mostPlayedPaths, 'most_played');
      await _cleanMissingPlaylistPaths(playlistsDB, playlistPaths);
      
      // print('✅ Limpieza de archivos faltantes completada');
    } catch (e) {
      // print('⚠️ Error durante la limpieza de archivos faltantes: $e');
    }
  }

  /// Obtiene todas las rutas de la base de datos de recientes
  static Future<List<String>> _getAllPathsFromRecents(RecentsDB db) async {
    final database = await db.database;
    final rows = await database.query('recents');
    return rows.map((e) => e['path'] as String).toList();
  }

  /// Obtiene todas las rutas de la base de datos de favoritos
  static Future<List<String>> _getAllPathsFromFavorites(FavoritesDB db) async {
    final database = await db.database;
    final rows = await database.query('favorites');
    return rows.map((e) => e['path'] as String).toList();
  }

  /// Obtiene todas las rutas de la base de datos de más reproducidas
  static Future<List<String>> _getAllPathsFromMostPlayed(MostPlayedDB db) async {
    final database = await db.database;
    final rows = await database.query('most_played');
    return rows.map((e) => e['path'] as String).toList();
  }

  /// Obtiene todas las rutas de la base de datos de playlists
  static Future<List<String>> _getAllPathsFromPlaylists(PlaylistsDB db) async {
    final database = await db.database;
    final rows = await database.query('playlist_songs');
    return rows.map((e) => e['song_path'] as String).toList();
  }

  /// Limpia rutas faltantes de una base de datos específica
  static Future<void> _cleanMissingPaths(
    dynamic db,
    List<String> paths,
    String dbName,
  ) async {
    final database = await db.database;
    int cleanedCount = 0;
    
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        try {
          if (dbName == 'recents') {
            await RecentsDB().removeRecent(path);
          } else if (dbName == 'favorites') {
            await FavoritesDB().removeFavorite(path);
          } else if (dbName == 'most_played') {
            await database.delete(
              'most_played',
              where: 'path = ?',
              whereArgs: [path],
            );
          }
          cleanedCount++;
        } catch (e) {
          // print('⚠️ Error al limpiar ruta $path de $dbName: $e');
        }
      }
    }
    
    if (cleanedCount > 0) {
      // print('🧹 Limpiados $cleanedCount archivos faltantes de $dbName');
    }
  }

  /// Limpia rutas faltantes de playlists
  static Future<void> _cleanMissingPlaylistPaths(
    PlaylistsDB db,
    List<String> paths,
  ) async {
    final database = await db.database;
    int cleanedCount = 0;
    
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        try {
          await database.delete(
            'playlist_songs',
            where: 'song_path = ?',
            whereArgs: [path],
          );
          cleanedCount++;
        } catch (e) {
          // print('⚠️ Error al limpiar ruta $path de playlists: $e');
        }
      }
    }
    
    if (cleanedCount > 0) {
      // print('🧹 Limpiados $cleanedCount archivos faltantes de playlists');
    }
  }


}