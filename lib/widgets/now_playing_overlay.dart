import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart'
    show audioHandler, audioServiceReady, overlayVisibleNotifier;
import 'package:music/screens/play/player_screen.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:marquee/marquee.dart';
import 'package:music/utils/notifiers.dart';

class NowPlayingOverlay extends StatefulWidget {
  final bool showBar;

  const NowPlayingOverlay({super.key, required this.showBar});

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay>
    with TickerProviderStateMixin {
  MediaItem? _lastKnownMediaItem;
  late AnimationController _playPauseController;
  Timer? _temporaryItemTimer;
  Timer? _playingDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1.0,
    );

    // Escuchar cambios en el estado de reproducción con debounce
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 100), () {
        if (mounted) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });
  }

  @override
  void dispose() {
    _playPauseController.dispose();
    _temporaryItemTimer?.cancel();
    _playingDebounce?.cancel();
    _isPlayingNotifier.dispose();
    super.dispose();
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

            if (!widget.showBar ||
                currentSong == null ||
                currentSong.id.isEmpty) {
              return const SizedBox.shrink();
            }

            final isLoading =
                (audioHandler as MyAudioHandler).initializingNotifier.value;

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
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              // El Hero se anima solo, solo animamos el resto del contenido
                              return SlideTransition(
                                position:
                                    Tween<Offset>(
                                      begin: const Offset(0, 1),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic,
                                      ),
                                    ),
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
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: (audioHandler as MyAudioHandler)
                                  .initializingNotifier,
                              builder: (context, isLoading, child) {
                                if (isLoading) {
                                  return Container(
                                    width: 50,
                                    height: 50,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Center(
                                      child: SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                final artUri = currentSong.artUri;

                                return ArtworkHeroCached(
                                  artUri: artUri,
                                  size: 50,
                                  borderRadius: BorderRadius.circular(8),
                                  heroTag:
                                      'now_playing_artwork_${(currentSong.extras?['songId'] ?? currentSong.id).toString()}',
                                  showPlaceholderIcon: true,
                                  isLoading:
                                      false, // El overlay maneja el loading externamente
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
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  Text(
                                    (currentSong.artist == null ||
                                            currentSong.artist!.trim().isEmpty)
                                        ? 'Desconocido'
                                        : currentSong.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),

                            RepaintBoundary(
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _isPlayingNotifier,
                                builder: (context, isPlaying, child) {
                                  // Sincroniza la animación
                                  if (isPlaying) {
                                    _playPauseController.forward();
                                  } else {
                                    _playPauseController.reverse();
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
                            stream:
                                (audioHandler as MyAudioHandler).positionStream,
                            initialData: Duration.zero,
                            builder: (context, posSnapshot) {
                              final position =
                                  posSnapshot.data ?? Duration.zero;
                              final hasDuration =
                                  duration != null &&
                                  duration.inMilliseconds > 0;

                              return StreamBuilder<Duration?>(
                                stream: (audioHandler as MyAudioHandler)
                                    .player
                                    .durationStream,
                                builder: (context, durationSnapshot) {
                                  final fallbackDuration =
                                      durationSnapshot.data;
                                  final total = hasDuration
                                      ? duration.inMilliseconds
                                      : (fallbackDuration?.inMilliseconds ?? 1);
                                  final current = position.inMilliseconds.clamp(
                                    0,
                                    total,
                                  );

                                  return Column(
                                    children: [
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                                            width: 0.5,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: LinearProgressIndicator(
                                            year2023: false,
                                            key: ValueKey(total),
                                            value: total > 0
                                                ? current / total
                                                : 0,
                                            minHeight: 4,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            backgroundColor: Theme.of(
                                              context,
                                            ).colorScheme.onSurface.withAlpha(60),
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
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
