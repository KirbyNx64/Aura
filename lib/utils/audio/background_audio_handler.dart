import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';

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

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _mediaQueue = [];
  bool _initializing = true;
  Timer? _sleepTimer;
  DateTime? _sleepEndTime;

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

  Future<void> setQueueFromSongs(
    List<SongModel> songs, {
    int initialIndex = 0,
  }) async {
    _initializing = true;
    _loadVersion++;
    final int currentVersion = _loadVersion;

    final int start = (initialIndex - 2).clamp(0, songs.length - 1);
    final int end = (initialIndex + 2).clamp(0, songs.length - 1);

    // 1. Prepara todas las fuentes de audio
    final sources = <AudioSource>[
      for (final song in songs) AudioSource.uri(Uri.file(song.data)),
    ];

    // 2. Prepara solo los MediaItem de la ventana inicial
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

      Uri? artUri;
      try {
        final albumArt = await OnAudioQuery().queryArtwork(
          song.id,
          ArtworkType.AUDIO,
          size: 512,
        );
        if (albumArt != null) {
          final tempDir = await getTemporaryDirectory();
          final file = await File(
            '${tempDir.path}/artwork_${song.id}.jpg',
          ).writeAsBytes(albumArt);
          artUri = Uri.file(file.path);
        }
      } catch (e) {
        artUri = null;
      }
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

    // 3. Llena la cola visual con los MediaItem de la ventana y placeholders para el resto
    _mediaQueue
      ..clear()
      ..addAll([
        ...List.generate(
          start,
          (i) => MediaItem(id: songs[i].data, title: songs[i].title),
        ),
        ...items,
        ...List.generate(
          songs.length - end - 1,
          (i) => MediaItem(
            id: songs[end + 1 + i].data,
            title: songs[end + 1 + i].title,
          ),
        ),
      ]);
    queue.add(_mediaQueue);

    if (currentVersion != _loadVersion) return;

    // 4. Carga todas las fuentes en el reproductor
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
      );
      if (currentVersion != _loadVersion) return;
      if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
        mediaItem.add(_mediaQueue[initialIndex]);
      }
    } catch (e) {
      // print('👻 Error al cargar las fuentes de audio: $e');
    }

    _initializing = false;

    // 5. En segundo plano, completa los MediaItem faltantes
    Future(() async {
      for (int i = 0; i < songs.length; i++) {
        if (i >= start && i <= end) continue;
        final song = songs[i];
        Duration? dur = (song.duration != null && song.duration! > 0)
            ? Duration(milliseconds: song.duration!)
            : null;
        Uri? artUri;
        try {
          final albumArt = await OnAudioQuery().queryArtwork(
            song.id,
            ArtworkType.AUDIO,
          );
          if (albumArt != null) {
            final tempDir = await getTemporaryDirectory();
            final file = await File(
              '${tempDir.path}/artwork_${song.id}.jpg',
            ).writeAsBytes(albumArt);
            artUri = Uri.file(file.path);
          }
        } catch (e) {
          artUri = null;
        }
        _mediaQueue[i] = MediaItem(
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
        );
        queue.add(_mediaQueue);
      }
    });
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
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < _mediaQueue.length) {
      await _player.seek(Duration.zero, index: index);
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
    _sleepEndTime = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () async {
      await pause();
      _sleepEndTime = null;
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndTime = null;
  }

  /// Devuelve el tiempo restante o null si no hay temporizador activo.
  Duration? get sleepTimeRemaining {
    if (_sleepEndTime == null) return null;
    final remaining = _sleepEndTime!.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  bool get isSleepTimerActive => sleepTimeRemaining != null;
}
