import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/main.dart';
import 'package:music/screens/play/player_screen.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:marquee/marquee.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:on_audio_query/on_audio_query.dart';

class NowPlayingOverlay extends StatelessWidget {
  final bool showBar;

  const NowPlayingOverlay({super.key, required this.showBar});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: audioHandler.mediaItem,
      builder: (context, snapshot) {
        final song = snapshot.data;
        final duration = song?.duration;

        if (!showBar || song == null || song.id.isEmpty) {
          return const SizedBox.shrink();
        }

        if (song.id.isNotEmpty) {
          final path = song.extras?['data'];
          if (path != null) {
            RecentsDB().addRecentPath(path);

            // Nuevo: sumar 1 a la base de datos de más escuchadas
            final query = OnAudioQuery();
            query.querySongs().then((allSongs) {
              final match = allSongs.where((s) => s.data == path);
              if (match.isNotEmpty) {
                MostPlayedDB().incrementPlayCount(match.first);
              }
            });
          }
        }

        final queue = audioHandler.queue.value; // Lista de MediaItem
        final currentSongId = song.extras?['songId'] ?? 0;
        final songIdList = queue
            .map((item) => item.extras?['songId'] ?? 0)
            .toList()
            .cast<int>();
        final currentIndex = songIdList.indexOf(currentSongId);
        final isLoading = (audioHandler as MyAudioHandler).initializingNotifier.value;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (isLoading) return;
            final currentSong = song;
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    FullPlayerScreen(initialMediaItem: currentSong),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      final offsetAnimation =
                          Tween<Offset>(
                            begin: const Offset(0, 1), // Empieza abajo
                            end: Offset.zero, // Termina en su lugar
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
          },
          onVerticalDragEnd: (details) {
            if (isLoading) return;
            if (details.primaryVelocity != null &&
                details.primaryVelocity! < 0) {
              final currentSong = song;
              Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                      FullPlayerScreen(initialMediaItem: currentSong),
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
                              borderRadius: BorderRadius.circular(12),
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
                        return ArtworkHeroCached(
                          songId: song.extras?['songId'] ?? 0,
                          size: 50,
                          borderRadius: BorderRadius.circular(12),
                          heroTag: 'now_playing_artwork_${song.extras?['songId'] ?? song.id}',
                          currentIndex: currentIndex,
                          songIdList: songIdList,
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
                            text: song.title,
                            maxWidth:
                                MediaQuery.of(context).size.width -
                                170, // Ajusta según tu layout
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            (song.artist == null || song.artist!.trim().isEmpty)
                                ? 'Desconocido'
                                : song.artist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    StreamBuilder<bool>(
                      stream: audioHandler.playbackState
                          .map((s) => s.playing)
                          .distinct(),
                      initialData: false,
                      builder: (context, isPlayingSnapshot) {
                        final isPlaying = isPlayingSnapshot.data ?? false;
                        return IconButton(
                          iconSize: 36,
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                          onPressed: () {
                            if (isPlaying) {
                              audioHandler.pause();
                            } else {
                              audioHandler.play();
                            }
                          },
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                StreamBuilder<Duration>(
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
              ],
            ),
          ),
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
