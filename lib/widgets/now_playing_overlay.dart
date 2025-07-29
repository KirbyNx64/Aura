import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart' show audioHandler, audioServiceReady, overlayVisibleNotifier;
import 'package:music/screens/play/player_screen.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:marquee/marquee.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/notifiers.dart';

// Función optimizada para actualizar más reproducidas
Future<void> _updateMostPlayedAsync(String path) async {
  try {
    final query = OnAudioQuery();
    final allSongs = await query.querySongs();
    final match = allSongs.where((s) => s.data == path);
    if (match.isNotEmpty) {
      await MostPlayedDB().incrementPlayCount(match.first);
    }
  } catch (e) {
    // Ignorar errores de actualización
  }
}

class NowPlayingOverlay extends StatefulWidget {
  final bool showBar;

  const NowPlayingOverlay({super.key, required this.showBar});

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay> with TickerProviderStateMixin {

  MediaItem? _lastKnownMediaItem;
  late AnimationController _playPauseController;
  Timer? _temporaryItemTimer;
  
  // Variables para tracking de tiempo de escucha
  String? _currentSongId;
  DateTime? _songStartTime;
  Timer? _listeningTimer;
  bool _hasBeenSaved = false;
  Duration _elapsedTime = Duration.zero;

  @override
  void initState() {
    super.initState();
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _playPauseController.dispose();
    _temporaryItemTimer?.cancel();
    _listeningTimer?.cancel();
    super.dispose();
  }

  // Función para guardar la canción después de 20 segundos
  void _saveSongAfterDelay(String songId, String path) {
    _listeningTimer?.cancel();
    final remainingTime = const Duration(seconds: 20) - _elapsedTime;
    if (remainingTime <= Duration.zero) {
      // Ya pasó el tiempo, guardar inmediatamente
      if (mounted && _currentSongId == songId && !_hasBeenSaved) {
        _hasBeenSaved = true;
        unawaited(RecentsDB().addRecentPath(path));
        unawaited(_updateMostPlayedAsync(path));
      }
    } else {
      _listeningTimer = Timer(remainingTime, () {
        if (mounted && _currentSongId == songId && !_hasBeenSaved) {
          _hasBeenSaved = true;
          // Actualizar recientes de forma asíncrona
          unawaited(RecentsDB().addRecentPath(path));
          // Actualizar más reproducidas de forma asíncrona
          unawaited(_updateMostPlayedAsync(path));
        }
      });
    }
  }

  // Función para cancelar el timer cuando se pausa o cambia la canción
  void _cancelListeningTimer() {
    _listeningTimer?.cancel();
    if (_songStartTime != null) {
      _elapsedTime += DateTime.now().difference(_songStartTime!);
    }
    _hasBeenSaved = false;
  }
  
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: audioServiceReady,
      builder: (context, ready, _) {
        if (!ready || audioHandler == null) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<MediaItem?>(
          stream: audioHandler?.mediaItem,
          builder: (context, snapshot) {
            final song = snapshot.data;
            
            // Mantener el último MediaItem conocido
            if (song != null && song.id.isNotEmpty) {
              _lastKnownMediaItem = song;
            }
            
            // Usar la canción actual o la última conocida
            final currentSong = song ?? _lastKnownMediaItem;
            final duration = currentSong?.duration;

            if (!widget.showBar || currentSong == null || currentSong.id.isEmpty) {
              // Cancelar timer si no hay canción
              _cancelListeningTimer();
              return const SizedBox.shrink();
            }

            // Tracking de tiempo de escucha: Solo guardar si se escucha más de 20 segundos
            if (currentSong.id.isNotEmpty && currentSong.id != _currentSongId) {
              // Nueva canción detectada - cancelar timer anterior si existe
              _cancelListeningTimer();
              
              _currentSongId = currentSong.id;
              _songStartTime = DateTime.now();
              _hasBeenSaved = false;
              _elapsedTime = Duration.zero;
              
              final path = currentSong.extras?['data'];
              if (path != null) {
                // Iniciar timer para guardar después de 20 segundos
                _saveSongAfterDelay(currentSong.id, path);
              }
            }

            final isLoading = (audioHandler as MyAudioHandler).initializingNotifier.value;

            return ValueListenableBuilder<bool>(
              valueListenable: overlayPlayerNavigationEnabled,
              builder: (context, navigationEnabled, _) {
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () async {
                    if (!overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }
                    if (isLoading || !navigationEnabled) return;
                    final songId = currentSong.extras?['songId'] ?? 0;
                    final songPath = currentSong.extras?['data'] ?? '';
                    final artUri = await getOrCacheArtwork(songId, songPath);
                    if (!context.mounted) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                          FullPlayerScreen(
                            initialMediaItem: currentSong,
                            initialArtworkUri: artUri,
                          ),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
                          // El Hero se anima solo, solo animamos el resto del contenido
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 1),
                              end: Offset.zero,
                            ).animate(CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            )),
                            child: child,
                          );
                        },
                        transitionDuration: const Duration(milliseconds: 350),
                      ),
                    );
                  },
                  onVerticalDragEnd: (details) async {
                    if (!overlayVisibleNotifier.value) {
                      overlayVisibleNotifier.value = true;
                    }
                    if (isLoading || !navigationEnabled) return;
                    if (details.primaryVelocity != null &&
                        details.primaryVelocity! < 0) {
                      final currentSong = song;
                      final songId = currentSong?.extras?['songId'] ?? 0;
                      final songPath = currentSong?.extras?['data'] ?? '';
                      final artUri = await getOrCacheArtwork(songId, songPath);
                      if (!context.mounted) return;
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder: (context, animation, secondaryAnimation) =>
                              FullPlayerScreen(
                                initialMediaItem: currentSong,
                                initialArtworkUri: artUri,
                              ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                final offsetAnimation =
                                    Tween<Offset>(
                                      begin: const Offset(0, 1),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      ),
                                    );
                                return SlideTransition(
                                  position: offsetAnimation,
                                  child: child,
                                );
                              },
                          transitionDuration: const Duration(milliseconds: 350),
                        ),
                      );
                    }
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: (audioHandler as MyAudioHandler).initializingNotifier,
                              builder: (context, isLoading, child) {
                                if (isLoading) {
                                  return Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Center(
                                      child: SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(strokeWidth: 3),
                                      ),
                                    ),
                                  );
                                }
                                
                                final songPath = currentSong.extras?['data'] as String?;
                                Uri? fallbackArtUri;
                                if (songPath != null && artworkCache.containsKey(songPath)) {
                                  fallbackArtUri = artworkCache[songPath];
                                }
                                final artUri = currentSong.artUri ?? fallbackArtUri;
                                
                                return ArtworkHeroCached(
                                  artUri: artUri,
                                  size: 50,
                                  borderRadius: BorderRadius.circular(8),
                                  heroTag: 'now_playing_artwork_${(currentSong.extras?['songId'] ?? currentSong.id).toString()}',
                                );
                              },
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TitleMarquee(
                                    text: currentSong.title,
                                    maxWidth:
                                        MediaQuery.of(context).size.width -
                                        170, // Ajusta según tu layout
                                    style: Theme.of(context).textTheme.titleMedium,
                                  ),
                                  Text(
                                    (currentSong.artist == null || currentSong.artist!.trim().isEmpty)
                                        ? 'Desconocido'
                                        : currentSong.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),

                            RepaintBoundary(
                              child: StreamBuilder<bool>(
                                stream: audioHandler?.playbackState
                                    .map((s) => s.playing)
                                    .distinct(),
                                initialData: false,
                                builder: (context, isPlayingSnapshot) {
                                  final isPlaying = isPlayingSnapshot.data ?? false;
                                  // Sincroniza la animación
                                  if (isPlaying) {
                                    _playPauseController.forward();
                                    // Reanudar timer si la canción vuelve a reproducirse
                                    if (_currentSongId != null && !_hasBeenSaved) {
                                      _songStartTime = DateTime.now();
                                      final path = currentSong.extras?['data'];
                                      if (path != null) {
                                        _saveSongAfterDelay(_currentSongId!, path);
                                      }
                                    }
                                  } else {
                                    _playPauseController.reverse();
                                    // Cancelar timer si se pausa la reproducción
                                    _cancelListeningTimer();
                                  }
                                  return IconButton(
                                    iconSize: 36,
                                    icon: AnimatedIcon(
                                      icon: AnimatedIcons.play_pause,
                                      progress: _playPauseController,
                                      size: 36,
                                    ),
                                    onPressed: () {
                                      if (isPlaying) {
                                        audioHandler?.pause();
                                      } else {
                                        audioHandler?.play();
                                      }
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        RepaintBoundary(
                          child: StreamBuilder<Duration>(
                            stream: (audioHandler as MyAudioHandler).positionStream,
                            initialData: Duration.zero,
                            builder: (context, posSnapshot) {
                              final position = posSnapshot.data ?? Duration.zero;
                              final hasDuration =
                                  duration != null && duration.inMilliseconds > 0;

                              return StreamBuilder<Duration?>(
                                stream: (audioHandler as MyAudioHandler)
                                    .player
                                    .durationStream,
                                builder: (context, durationSnapshot) {
                                  final fallbackDuration = durationSnapshot.data;
                                  final total = hasDuration
                                      ? duration.inMilliseconds
                                      : (fallbackDuration?.inMilliseconds ?? 1);
                                  final current = position.inMilliseconds.clamp(0, total);

                                  return Column(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: LinearProgressIndicator(
                                          key: ValueKey(total),
                                          value: total > 0 ? current / total : 0,
                                          minHeight: 4,
                                          borderRadius: BorderRadius.circular(8),
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.onSurface.withAlpha(60),
                                          color: Theme.of(context).colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class TitleMarquee extends StatefulWidget {
  final String text;
  final double maxWidth;
  final TextStyle? style;

  const TitleMarquee({
    super.key,
    required this.text,
    required this.maxWidth,
    this.style,
  });

  @override
  State<TitleMarquee> createState() => _TitleMarqueeState();
}

class _TitleMarqueeState extends State<TitleMarquee> {
  bool _showMarquee = false;

  @override
  void didUpdateWidget(covariant TitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      setState(() => _showMarquee = false);
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) setState(() => _showMarquee = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _showMarquee = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.style ?? DefaultTextStyle.of(context).style;
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: textStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textHeight = textPainter.height;
    final textWidth = textPainter.size.width;

    final boxHeight = textHeight + 4; // pequeño margen

    if (textWidth > widget.maxWidth) {
      if (!_showMarquee) {
        return SizedBox(
          height: boxHeight,
          width: widget.maxWidth,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      return SizedBox(
        height: boxHeight,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Marquee(
            key: ValueKey(widget.text),
            text: widget.text,
            style: textStyle,
            velocity: 30.0,
            blankSpace: 40.0,
            pauseAfterRound: const Duration(seconds: 2),
            startPadding: 0.0,
            fadingEdgeStartFraction: 0.1,
            fadingEdgeEndFraction: 0.1,
          ),
        ),
      );
    } else {
      return SizedBox(
        height: boxHeight,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.text,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}