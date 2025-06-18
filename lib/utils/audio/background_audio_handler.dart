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
      androidNotificationChannelId: 'com.tuapp.music.channel',
      androidNotificationChannelName: 'Reproducción de música',
      androidNotificationOngoing: true,
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
          androidCompactActionIndices: const [0, 1, 3],
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

  Future<void> setQueueFromSongs(
    List<SongModel> songs, {
    int initialIndex = 0,
  }) async {
    _initializing = true;

    final items = <MediaItem>[];
    final sources = <AudioSource>[];

    for (int i = 0; i < songs.length; i++) {
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
          // Si algo falla, lo ignoramos y seguimos sin duración real
        }
      }

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

      sources.add(AudioSource.uri(Uri.file(song.data)));
    }

    _mediaQueue
      ..clear()
      ..addAll(items);
    queue.add(_mediaQueue);

    await _player.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
      mediaItem.add(_mediaQueue[initialIndex]);
    }

    _initializing = false;
  }

  Future<void> setQueueFromFavorites(
    List<Map<String, dynamic>> favorites, {
    int initialIndex = 0,
  }) async {
    final mediaItems = favorites.map((song) {
      return MediaItem(
        id: song['id'].toString(),
        album: song['album'] ?? '',
        title: song['title'] ?? '',
        artist: song['artist'] ?? '',
        artUri: song['artUri'] != null ? Uri.parse(song['artUri']) : null,
        extras: {'data': song['artUri']},
      );
    }).toList();

    final audioSources = favorites.map((song) {
      return AudioSource.uri(Uri.parse(song['artUri']));
    }).toList();

    _mediaQueue
      ..clear()
      ..addAll(mediaItems);
    queue.add(_mediaQueue);

    await _player.setAudioSources(
      audioSources,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    if (initialIndex >= 0 && initialIndex < _mediaQueue.length) {
      mediaItem.add(_mediaQueue[initialIndex]);
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
