import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:music/utils/db/artwork_db.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:flutter/foundation.dart';

// Variable global para rastrear si el AudioHandler ya está inicializado
// AudioHandler? _currentInstance;

AudioHandler? _audioHandler;

Future<AudioHandler> initAudioService() async {
  if (_audioHandler != null) return _audioHandler!;
  _audioHandler = await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.aura.music.channel',
      androidNotificationChannelName: 'Aura Music',
      androidNotificationOngoing: true,
      // androidNotificationIcon: 'mipmap/ic_stat_music_note',
    ),
  );
  return _audioHandler!;
}

/// Limpia la instancia actual del AudioHandler
//  void clearAudioHandlerInstance() {
//    _currentInstance = null;
//  }

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
  AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _mediaQueue = [];
  final ValueNotifier<bool> initializingNotifier = ValueNotifier(false);
  bool _initializing = true;
  bool _needsReinitialization = false;
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
        final currentMediaItem = _mediaQueue[index];
        
        // Verificar que el índice coincida con el esperado
        final expectedIndex = currentMediaItem.extras?['queueIndex'] as int?;
        if (expectedIndex != null && index != expectedIndex) {
          // print('⚠️ Desincronización de índices: actual=$index, esperado=$expectedIndex');
          // print('🎵 Canción actual: ${currentMediaItem.title}');
        }
        
        mediaItem.add(currentMediaItem);
        
        // Carga la carátula inmediatamente si no la tiene
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
    
    // Validar el índice inicial
    if (initialIndex < 0 || initialIndex >= totalSongs) {
      // print('⚠️ Índice inicial inválido: $initialIndex, total de canciones: $totalSongs');
      initialIndex = 0; // Usar el primer elemento si el índice es inválido
    }
    
    // Calcula la ventana de carga inicial alrededor del índice inicial
    final int start = (initialIndex - 5).clamp(0, totalSongs - 1);
    final int end = (initialIndex + 5).clamp(0, totalSongs - 1);

    // 1. Precarga carátulas en paralelo solo para la ventana inicial
    final artworkPromises = <Future<void>>[];
    for (int i = start; i <= end; i++) {
      artworkPromises.add(getOrCacheArtwork(songs[i].id, songs[i].data));
    }
    await Future.wait(artworkPromises);

    // 2. Prepara las fuentes de audio correctamente con verificación de archivos
    final sources = <AudioSource>[];
    final validSongs = <SongModel>[];
    final validIndices = <int>[];
    
    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];
      try {
        // Verificar si el archivo existe antes de crear el AudioSource
        final file = File(song.data);
        if (await file.exists()) {
          sources.add(AudioSource.uri(Uri.file(song.data)));
          validSongs.add(song);
          validIndices.add(i);
        } else {
          // Archivo no existe, omitir esta canción
          // print('⚠️ Archivo no encontrado: ${song.data}');
        }
      } catch (e) {
        // Error al verificar archivo, omitir esta canción
        // print('⚠️ Error al verificar archivo ${song.data}: $e');
      }
    }

    // Si no hay archivos válidos, manejar de forma elegante
    if (validSongs.isEmpty) {
      _initializing = false;
      initializingNotifier.value = false;
      
      // Detener completamente la reproducción actual
      try {
        await _player.stop();
        await _player.dispose();
        _needsReinitialization = true;
      } catch (e) {
        // print('⚠️ Error al detener el reproductor: $e');
      }
      
      // Limpiar la cola y el estado
      _mediaQueue.clear();
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      
      // Limpiar archivos faltantes de las bases de datos
      cleanMissingFilesFromDatabases();
      
      // print('⚠️ No se encontraron archivos de audio válidos en la lista proporcionada');
      // print('🛑 Reproducción detenida completamente');
      
      return; // Salir sin lanzar excepción
    }

    // Verificar si el reproductor necesita ser reinicializado
    if (_needsReinitialization || _player.processingState == ProcessingState.idle) {
      // print('🔄 Reinicializando reproductor...');
      await _reinitializePlayer();
      _needsReinitialization = false;
    }

    // Mapear el índice inicial original al nuevo índice en la lista filtrada
    int adjustedInitialIndex = 0;
    bool foundExactMatch = false;
    
    // Buscar el índice correspondiente en la lista filtrada
    for (int i = 0; i < validIndices.length; i++) {
      if (validIndices[i] == initialIndex) {
        adjustedInitialIndex = i;
        foundExactMatch = true;
        break;
      }
    }
    
    // Si no se encuentra el índice exacto, usar el más cercano
    if (!foundExactMatch && validIndices.isNotEmpty) {
      // Buscar el índice más cercano al original
      int closestIndex = 0;
      int minDistance = (initialIndex - validIndices[0]).abs();
      
      for (int i = 1; i < validIndices.length; i++) {
        final distance = (initialIndex - validIndices[i]).abs();
        if (distance < minDistance) {
          minDistance = distance;
          closestIndex = i;
        }
      }
      adjustedInitialIndex = closestIndex;
      // print('⚠️ Índice exacto no encontrado, usando el más cercano');
    }
    
    // print('🎵 Índice original: $initialIndex, Índice ajustado: $adjustedInitialIndex, Total válidos: ${validSongs.length}');
    // print('🎵 Canción seleccionada: ${validSongs[adjustedInitialIndex].title} - ${validSongs[adjustedInitialIndex].artist}');

    // 3. Prepara solo los MediaItem de la ventana inicial (usando índices de la lista filtrada)
    final items = <MediaItem>[];
    final adjustedStart = (adjustedInitialIndex - 5).clamp(0, validSongs.length - 1);
    final adjustedEnd = (adjustedInitialIndex + 5).clamp(0, validSongs.length - 1);
    
    for (int i = adjustedStart; i <= adjustedEnd; i++) {
      final song = validSongs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;

      if (i == adjustedInitialIndex && dur == null) {
        try {
          final audioSource = AudioSource.uri(Uri.file(song.data));
          await _player.setAudioSource(audioSource, preload: false);
          dur = await _player.setFilePath(song.data);
        } catch (e) {
          // Si falla, asigna una duración nula
          // print('⚠️ Error al obtener duración para ${song.data}: $e');
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
            'queueIndex': i, // Agregar el índice de la cola
          },
        ),
      );
    }

    // 4. Carga inicial optimizada: solo MediaItem básicos sin carátulas
    _mediaQueue.clear();
    final initialMediaItems = <MediaItem>[];
    
    // Para listas grandes, carga solo información básica inicialmente
    for (int i = 0; i < validSongs.length; i++) {
      final song = validSongs[i];
      Duration? dur = (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null;
      
      // Solo carga carátulas para la ventana inicial
      Uri? artUri;
      if (i >= adjustedStart && i <= adjustedEnd) {
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
            'queueIndex': i, // Agregar el índice de la cola
          },
        ),
      );
    }
    
    _mediaQueue.addAll(initialMediaItems);
    queue.add(_mediaQueue);

    if (currentVersion != _loadVersion) return;

    // 5. Carga todas las fuentes en el reproductor
    try {
      // Verificar que el reproductor esté listo
      if (_needsReinitialization || _player.processingState == ProcessingState.idle) {
        // print('🔄 Reproductor necesita reinicialización antes de cargar fuentes...');
        await _reinitializePlayer();
        _needsReinitialization = false;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      await _player.setAudioSources(
        sources,
        initialIndex: adjustedInitialIndex,
        initialPosition: Duration.zero,
      );
      if (currentVersion != _loadVersion) return;
      
      // Espera optimizada para que el reproductor esté listo
      int attempts = 0;
      while (_player.processingState != ProcessingState.ready && attempts < 30) {
        await Future.delayed(const Duration(milliseconds: 30));
        attempts++;
      }
      
      // Verificar que el índice actual del reproductor sea el correcto
      final currentPlayerIndex = _player.currentIndex;
      if (currentPlayerIndex != adjustedInitialIndex) {
        // print('⚠️ Índice del reproductor incorrecto: $currentPlayerIndex, esperado: $adjustedInitialIndex');
        // Intentar corregir el índice
        try {
          await _player.seek(Duration.zero, index: adjustedInitialIndex);
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (e) {
          // print('⚠️ Error al corregir índice del reproductor: $e');
        }
      }
      
      if (adjustedInitialIndex >= 0 && adjustedInitialIndex < _mediaQueue.length) {
        final selectedMediaItem = _mediaQueue[adjustedInitialIndex];
        mediaItem.add(selectedMediaItem);
        // print('🎵 Canción seleccionada: ${selectedMediaItem.title} - ${selectedMediaItem.artist}');
        // print('🎵 Índice del reproductor: ${_player.currentIndex}');
      }
    } catch (e) {
      // print('👻 Error al cargar las fuentes de audio: $e');
      // Si falla la carga, intentar con una sola canción
      if (validSongs.isNotEmpty) {
        try {
          final firstSong = validSongs.first;
          final firstSource = AudioSource.uri(Uri.file(firstSong.data));
          await _player.setAudioSource(firstSource);
          if (_mediaQueue.isNotEmpty) {
            mediaItem.add(_mediaQueue.first);
          }
        } catch (e2) {
          // print('👻 Error crítico al cargar audio: $e2');
        }
      }
    }

    // 6. Carga en segundo plano optimizada por lotes
    // Siempre carga las carátulas restantes, independientemente del tamaño de la lista
    _loadRemainingMediaItemsInBackground(validSongs, adjustedStart, adjustedEnd, currentVersion);
    
    // Verificación final de sincronización
    await Future.delayed(const Duration(milliseconds: 100));
    final finalIndex = _player.currentIndex;
    if (finalIndex != adjustedInitialIndex) {
      // print('⚠️ Verificación final: índice incorrecto $finalIndex, esperado $adjustedInitialIndex');
      try {
        await _player.seek(Duration.zero, index: adjustedInitialIndex);
        // print('✅ Índice corregido en verificación final');
      } catch (e) {
        // print('⚠️ Error en verificación final: $e');
      }
    }
    
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
    
    // Verificar si hay canciones disponibles
    if (_mediaQueue.isEmpty) {
      // print('⚠️ No hay canciones disponibles para reproducir');
      return;
    }
    
    // Verificar si el reproductor está en un estado válido
    if (_needsReinitialization || _player.processingState == ProcessingState.idle) {
      // print('⚠️ Reproductor necesita reinicialización, intentando...');
      try {
        await _reinitializePlayer();
        _needsReinitialization = false;
        // Esperar un poco para que se estabilice
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        // print('⚠️ Error al reinicializar reproductor: $e');
        return;
      }
    }
    
    try {
      // Verificar si el archivo actual existe antes de reproducir
      if (current != null) {
        final filePath = current.extras?['data'] as String?;
        if (filePath != null) {
          final file = File(filePath);
          if (!await file.exists()) {
            // print('⚠️ Archivo no encontrado al intentar reproducir: $filePath');
            // Intentar encontrar la siguiente canción válida
            await _handleNavigationError();
            return;
          }
        }
      }
      
      // Verificar que se esté reproduciendo la canción correcta
      final currentIndex = _player.currentIndex;
      final expectedIndex = mediaItem.value?.extras?['queueIndex'] as int?;
      
      if (expectedIndex != null && currentIndex != expectedIndex) {
        // print('⚠️ Índice incorrecto al reproducir: $currentIndex, esperado: $expectedIndex');
        try {
          await _player.seek(Duration.zero, index: expectedIndex);
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (e) {
          // print('⚠️ Error al corregir índice al reproducir: $e');
        }
      }
      
      await _player.play();
    } catch (e) {
      // print('⚠️ Error al intentar reproducir: $e');
      // Si hay error al reproducir, intentar encontrar una canción válida
      await _handleNavigationError();
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
      // print('⚠️ Error al cambiar a la siguiente canción: $e');
      // Si hay error, intentar saltar manualmente
      await _handleNavigationError();
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
      // print('⚠️ Error al cambiar a la canción anterior: $e');
      // Si hay error, intentar saltar manualmente
      await _handleNavigationError();
    } finally {
      _isSeekingOrLoading = false;
    }
  }

  /// Maneja errores de navegación intentando encontrar la siguiente canción válida
  Future<void> _handleNavigationError() async {
    try {
      final currentIndex = _player.currentIndex ?? 0;
      final wasPlaying = _player.playing;
      
      // Buscar la siguiente canción válida
      for (int i = currentIndex + 1; i < _mediaQueue.length; i++) {
        final mediaItem = _mediaQueue[i];
        final filePath = mediaItem.extras?['data'] as String?;
        
        if (filePath != null) {
          final file = File(filePath);
          if (await file.exists()) {
            try {
              await _player.seek(Duration.zero, index: i);
              if (wasPlaying) {
                await _player.play();
              }
              return;
            } catch (e) {
              // print('⚠️ Error al cambiar a índice $i: $e');
              continue;
            }
          }
        }
      }
      
      // Si no encuentra ninguna canción válida hacia adelante, buscar hacia atrás
      for (int i = currentIndex - 1; i >= 0; i--) {
        final mediaItem = _mediaQueue[i];
        final filePath = mediaItem.extras?['data'] as String?;
        
        if (filePath != null) {
          final file = File(filePath);
          if (await file.exists()) {
            try {
              await _player.seek(Duration.zero, index: i);
              if (wasPlaying) {
                await _player.play();
              }
              return;
            } catch (e) {
              // print('⚠️ Error al cambiar a índice $i: $e');
              continue;
            }
          }
        }
      }
      
      // Si no encuentra ninguna canción válida, detener completamente
      // print('⚠️ No se encontraron canciones válidas para reproducir');
      
      // Detener completamente la reproducción
      try {
        await _player.stop();
        await _player.dispose();
        // Marcar que el reproductor necesita reinicialización
        _needsReinitialization = true;
        // print('🔄 Reproductor marcado para reinicialización');
      } catch (e) {
        // print('⚠️ Error al detener el reproductor: $e');
      }
      
      // Limpiar el estado del reproductor
      _mediaQueue.clear();
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      
      // Limpiar archivos faltantes de las bases de datos
      cleanMissingFilesFromDatabases();
      
      // print('🛑 Reproducción detenida completamente - no hay canciones válidas');
      
    } catch (e) {
      // print('⚠️ Error crítico en manejo de navegación: $e');
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
      // Verificar si el archivo existe antes de intentar reproducirlo
      if (index >= 0 && index < _mediaQueue.length) {
        final mediaItem = _mediaQueue[index];
        final filePath = mediaItem.extras?['data'] as String?;
        
        if (filePath != null) {
          final file = File(filePath);
          if (!await file.exists()) {
            // print('⚠️ Archivo no encontrado para índice $index: $filePath');
            // Intentar encontrar la siguiente canción válida
            await _handleNavigationError();
            return;
          }
        }
      }
      
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
      // print('⚠️ Error al cambiar a índice $index: $e');
      // Si hay error, intentar encontrar una canción válida
      await _handleNavigationError();
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

  /// Verifica si hay canciones válidas disponibles en la cola
  bool get hasValidSongs => _mediaQueue.isNotEmpty;

  /// Obtiene el número de canciones en la cola
  int get queueLength => _mediaQueue.length;

  /// Verifica y devuelve información sobre archivos faltantes en la cola actual
  Future<Map<String, dynamic>> checkMissingFiles() async {
    final missingFiles = <String>[];
    final validFiles = <String>[];
    
    for (final mediaItem in _mediaQueue) {
      final filePath = mediaItem.extras?['data'] as String?;
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) {
          validFiles.add(filePath);
        } else {
          missingFiles.add(filePath);
        }
      }
    }
    
    return {
      'total': _mediaQueue.length,
      'valid': validFiles.length,
      'missing': missingFiles.length,
      'missingFiles': missingFiles,
      'validFiles': validFiles,
    };
  }

  /// Filtra y actualiza la cola para incluir solo archivos válidos
  Future<void> filterValidFiles() async {
    final validMediaItems = <MediaItem>[];
    
    for (final mediaItem in _mediaQueue) {
      final filePath = mediaItem.extras?['data'] as String?;
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) {
          validMediaItems.add(mediaItem);
        } else {
          // print('⚠️ Filtrando archivo faltante: $filePath');
        }
      }
    }
    
    if (validMediaItems.isEmpty) {
      // Si no hay archivos válidos, detener completamente
      // print('⚠️ No quedan archivos válidos después del filtrado');
      
      // Detener completamente la reproducción
      try {
        await _player.stop();
        await _player.dispose();
      } catch (e) {
        // print('⚠️ Error al detener el reproductor: $e');
      }
      
      // Limpiar todo
      _mediaQueue.clear();
      queue.add([]);
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      
      // print('🛑 Reproducción detenida completamente - no quedan archivos válidos');
    } else if (validMediaItems.length != _mediaQueue.length) {
      // Actualizar la cola con solo archivos válidos
      _mediaQueue.clear();
      _mediaQueue.addAll(validMediaItems);
      queue.add(_mediaQueue);
      // print('✅ Cola actualizada: ${validMediaItems.length} archivos válidos de ${_mediaQueue.length} originales');
    }
  }

  /// Reinicializa el reproductor cuando es necesario
  Future<void> _reinitializePlayer() async {
    try {
      // print('🔄 Iniciando reinicialización del reproductor...');
      
      // Detener y limpiar el reproductor actual si es necesario
      try {
        await _player.stop();
        await _player.dispose();
      } catch (e) {
        // print('⚠️ Error al limpiar reproductor anterior: $e');
      }
      
      // Limpiar la sesión de audio actual antes de crear una nueva
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
      } catch (e) {
        // print('⚠️ Error al configurar sesión de audio: $e');
      }
      
      // Crear un nuevo reproductor
      final newPlayer = AudioPlayer();
      
      // Reemplazar el reproductor
      _player = newPlayer;
      
      // Reinicializar los listeners sin crear nueva sesión
      await _initListeners();
      
      // print('✅ Reproductor reinicializado correctamente');
    } catch (e) {
      // print('⚠️ Error al reinicializar el reproductor: $e');
      // Intentar crear un reproductor básico como fallback
      try {
        _player = AudioPlayer();
        // print('✅ Reproductor básico creado como fallback');
      } catch (e2) {
        // print('❌ Error crítico al crear reproductor fallback: $e2');
      }
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

    _player.currentIndexStream.listen((index) {
      if (_initializing) return;
      if (index != null && index < _mediaQueue.length) {
        final currentMediaItem = _mediaQueue[index];
        
        // Verificar que el índice coincida con el esperado
        final expectedIndex = currentMediaItem.extras?['queueIndex'] as int?;
        if (expectedIndex != null && index != expectedIndex) {
          // print('⚠️ Desincronización de índices: actual=$index, esperado=$expectedIndex');
          // print('🎵 Canción actual: ${currentMediaItem.title}');
        }
        
        mediaItem.add(currentMediaItem);
        
        // Carga la carátula inmediatamente si no la tiene
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

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    return super.onTaskRemoved();
  }

  /// Limpia archivos faltantes de las bases de datos
  static Future<void> cleanMissingFilesFromDatabases() async {
    try {
      // Importar las clases de base de datos
      final recentDB = RecentsDB();
      final favoritesDB = FavoritesDB();
      final mostPlayedDB = MostPlayedDB();
      final playlistsDB = PlaylistsDB();
      final artworkDB = ArtworkDB();
      
      // Obtener todas las rutas de archivos de las bases de datos
      final recentPaths = await _getAllPathsFromRecents(recentDB);
      final favoritePaths = await _getAllPathsFromFavorites(favoritesDB);
      final mostPlayedPaths = await _getAllPathsFromMostPlayed(mostPlayedDB);
      final playlistPaths = await _getAllPathsFromPlaylists(playlistsDB);
      final artworkPaths = await _getAllPathsFromArtwork(artworkDB);
      
      // Verificar y limpiar archivos faltantes
      await _cleanMissingPaths(recentDB, recentPaths, 'recents');
      await _cleanMissingPaths(favoritesDB, favoritePaths, 'favorites');
      await _cleanMissingPaths(mostPlayedDB, mostPlayedPaths, 'most_played');
      await _cleanMissingPlaylistPaths(playlistsDB, playlistPaths);
      await _cleanMissingArtworkPaths(artworkDB, artworkPaths);
      
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

  /// Obtiene todas las rutas de la base de datos de carátulas
  static Future<List<String>> _getAllPathsFromArtwork(ArtworkDB db) async {
    final database = await ArtworkDB.database;
    final rows = await database.query('artwork_cache');
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

  /// Limpia rutas faltantes de carátulas
  static Future<void> _cleanMissingArtworkPaths(
    ArtworkDB db,
    List<String> paths,
  ) async {
    final database = await ArtworkDB.database;
    int cleanedCount = 0;
    
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists()) {
        try {
          await database.delete(
            'artwork_cache',
            where: 'song_path = ?',
            whereArgs: [path],
          );
          cleanedCount++;
        } catch (e) {
          // print('⚠️ Error al limpiar ruta $path de artwork: $e');
        }
      }
    }
    
    if (cleanedCount > 0) {
      // print('🧹 Limpiados $cleanedCount archivos faltantes de artwork');
    }
  }
}