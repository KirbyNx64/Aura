import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:music/main.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/notifiers.dart';

final OnAudioQuery _audioQuery = OnAudioQuery();

Future<String?> fetchLyrics(String artist, String title) async {
  try {
    final response = await http
        .get(Uri.parse('https://api.lyrics.ovh/v1/$artist/$title'))
        .timeout(const Duration(seconds: 8)); // Timeout de 8 segundos

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['lyrics'];
    } else {
      return null;
    }
  } catch (e) {
    return null;
  }
}

class FullPlayerScreen extends StatefulWidget {
  final MediaItem? initialMediaItem;

  const FullPlayerScreen({super.key, this.initialMediaItem});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with SingleTickerProviderStateMixin {
  double? _dragValueSeconds;

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget buildArtwork(MediaItem mediaItem, double size) {
    final artworkUrl = mediaItem.artUri?.toString();
    if (artworkUrl != null && artworkUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.network(
          artworkUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _defaultArtwork(size),
          loadingBuilder: (context, child, loadingProgress) =>
              loadingProgress == null
              ? child
              : Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(),
                ),
        ),
      );
    } else {
      return _defaultArtwork(size);
    }
  }

  Widget _defaultArtwork(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        Icons.music_note,
        color: Colors.white54,
        size: size * 0.5, // Ícono grande y centrado
      ),
    );
  }

  Future<void> _showSongOptions(
    BuildContext context,
    MediaItem mediaItem,
  ) async {
    final isFav = await FavoritesDB().isFavorite(
      mediaItem.extras?['data'] ?? '',
    );

    // Usamos `if (!context.mounted)` si estás dentro de un StatefulWidget con `BuildContext context`
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isFav ? Icons.delete_outline : Icons.favorite_border,
              ),
              title: Text(isFav ? 'Eliminar de me gusta' : 'Añadir a me gusta'),
              onTap: () async {
                Navigator.of(context).pop();

                final path = mediaItem.extras?['data'] ?? '';

                if (isFav) {
                  await FavoritesDB().removeFavorite(path);
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Eliminado de me gusta')),
                    );
                  }
                } else {
                  if (path.isEmpty) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'No se puede añadir: ruta no disponible',
                          ),
                        ),
                      );
                    }
                    return;
                  }

                  final allSongs = await _audioQuery.querySongs();
                  final songList = allSongs
                      .where((s) => s.data == path)
                      .toList();

                  if (songList.isEmpty) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No se encontró la canción original'),
                        ),
                      );
                    }
                    return;
                  }

                  final song = songList.first;
                  await _addToFavorites(song);

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Añadido a me gusta')),
                    );
                  }
                }
              },
            ),
            ListTile(
              leading: () {
                final isActive =
                    (audioHandler as MyAudioHandler).sleepTimeRemaining != null;
                return Icon(isActive ? Icons.timer : Icons.timer_outlined);
              }(),
              title: Text(() {
                final remaining =
                    (audioHandler as MyAudioHandler).sleepTimeRemaining;
                if (remaining != null) {
                  final minutes = remaining.inMinutes;
                  return 'Temporizador de apagado: $minutes minuto${minutes == 1 ? '' : 's'} restantes';
                } else {
                  return 'Temporizador de apagado';
                }
              }()),
              onTap: () {
                Navigator.of(context).pop();
                showModalBottomSheet(
                  context: context,
                  builder: (context) => const SleepTimerOptionsSheet(),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Información de la canción'),
              onTap: () {
                Navigator.of(context).pop();
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Información de la canción'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Título: ${mediaItem.title}'),
                        Text('Artista: ${mediaItem.artist ?? "Desconocido"}'),
                        Text('Álbum: ${mediaItem.album ?? "Desconocido"}'),
                        Text('Ubicación: ${mediaItem.extras?['data'] ?? ""}'),
                        Text(
                          'Duración: ${mediaItem.duration != null ? Duration(milliseconds: mediaItem.duration!.inMilliseconds).toString().split('.').first : "?"}',
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        child: const Text('Cerrar'),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Añadido a me gusta')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width;
    final height = size.height;

    // Tamaños relativos
    final artworkSize = width * 0.8;
    double progressBarWidth;
    if (width <= 400) {
      progressBarWidth = artworkSize * 1.2;
    } else if (width <= 800) {
      progressBarWidth = artworkSize * 1.3;
    } else {
      progressBarWidth = (artworkSize * 1.5).clamp(0, width * 0.9);
    }
    final buttonFontSize = width * 0.04 + 10;

    return GestureDetector(
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta != null && details.primaryDelta! > 12) {
          Navigator.of(context).maybePop();
        }
      },
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        initialData: widget.initialMediaItem,
        builder: (context, snapshot) {
          final mediaItem = snapshot.data;
          if (mediaItem == null) {
            return const Scaffold(
              body: Center(child: Text('No hay canción en reproducción')),
            );
          }

          final queue = audioHandler.queue.value;
          final currentSongId = mediaItem.extras?['songId'] ?? 0;
          final songIdList = queue
              .map((item) => item.extras?['songId'] ?? 0)
              .toList()
              .cast<int>();
          final currentIndex = songIdList.indexOf(currentSongId);
          return Scaffold(
            appBar: AppBar(
              leading: IconButton(
                iconSize: 38,
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: const Text(''),
              actions: [
                IconButton(
                  iconSize: 38,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {
                    _showSongOptions(context, mediaItem);
                  },
                ),
              ],
            ),
            resizeToAvoidBottomInset: true, // Asegúrate de que esté en true
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: width * 0.04,
                    vertical: height * 0.03,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      ArtworkHeroCached(
                        songId: mediaItem.extras?['songId'] ?? 0,
                        size: artworkSize,
                        borderRadius: BorderRadius.circular(artworkSize * 0.06),
                        heroTag:
                            'now_playing_artwork_${mediaItem.extras?['songId'] ?? mediaItem.id}',
                        currentIndex: currentIndex,
                        songIdList: songIdList,
                      ),
                      SizedBox(height: height * 0.03),
                      SizedBox(
                        width: artworkSize,
                        child: Row(
                          children: [
                            Expanded(
                              child: TitleMarquee(
                                text: mediaItem.title,
                                maxWidth: artworkSize - 40,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontSize: buttonFontSize + 0.75,
                                    ),
                              ),
                            ),
                            SizedBox(width: width * 0.04),
                            FutureBuilder<bool>(
                              future: FavoritesDB().isFavorite(
                                mediaItem.extras?['data'] ?? '',
                              ),
                              builder: (context, favSnapshot) {
                                final isFav = favSnapshot.data ?? false;
                                return AnimatedTapButton(
                                  onTap: () async {
                                    final path =
                                        mediaItem.extras?['data'] ?? '';
                                    if (path.isEmpty) return;

                                    if (isFav) {
                                      await FavoritesDB().removeFavorite(path);
                                      favoritesShouldReload.value =
                                          !favoritesShouldReload.value;
                                      if (mounted) setState(() {});
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Eliminado de me gusta',
                                          ),
                                        ),
                                      );
                                    } else {
                                      final allSongs = await _audioQuery
                                          .querySongs();
                                      final songList = allSongs
                                          .where((s) => s.data == path)
                                          .toList();

                                      if (songList.isEmpty) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'No se encontró la canción original',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      final song = songList.first;
                                      await _addToFavorites(song);
                                      if (mounted) setState(() {});
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Añadido a me gusta'),
                                        ),
                                      );
                                    }
                                  },
                                  child: Icon(
                                    isFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    size: 38,
                                    color: Colors.white,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: height * 0.01),
                      SizedBox(
                        width: artworkSize,
                        child: Text(
                          (mediaItem.artist == null ||
                                  mediaItem.artist!.trim().isEmpty)
                              ? 'Desconocido'
                              : mediaItem.artist!,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w400,
                                fontSize: 18,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.left,
                        ),
                      ),
                      SizedBox(height: height * 0.015),
                      // Barra de progreso + tiempos
                      StreamBuilder<Duration>(
                        stream: (audioHandler as MyAudioHandler).positionStream,
                        initialData: Duration.zero,
                        builder: (context, posSnapshot) {
                          final position = posSnapshot.data ?? Duration.zero;

                          // NUEVO: Usar durationStream como fallback si mediaItem.duration es nula o cero
                          return StreamBuilder<Duration?>(
                            stream: (audioHandler as MyAudioHandler)
                                .player
                                .durationStream,
                            builder: (context, durationSnapshot) {
                              final fallbackDuration = durationSnapshot.data;
                              final mediaDuration = mediaItem.duration;
                              final hasDuration =
                                  mediaDuration != null &&
                                  mediaDuration.inMilliseconds > 0;
                              final duration = hasDuration
                                  ? mediaDuration
                                  : (fallbackDuration ?? Duration.zero);

                              final durationSeconds = duration.inSeconds > 0
                                  ? duration.inSeconds
                                  : 1;

                              final sliderValueSeconds =
                                  (_dragValueSeconds != null)
                                  ? _dragValueSeconds!.clamp(
                                      0,
                                      durationSeconds.toDouble(),
                                    )
                                  : position.inSeconds
                                        .clamp(0, durationSeconds)
                                        .toDouble();

                              return Column(
                                children: [
                                  SizedBox(
                                    width: progressBarWidth,
                                    child: Slider(
                                      min: 0,
                                      max: durationSeconds.toDouble(),
                                      value: sliderValueSeconds.toDouble(),
                                      onChanged: (value) {
                                        setState(() {
                                          _dragValueSeconds = value;
                                        });
                                      },
                                      onChangeEnd: (value) {
                                        audioHandler.seek(
                                          Duration(seconds: value.toInt()),
                                        );
                                        setState(() {
                                          _dragValueSeconds = null;
                                        });
                                      },
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _formatDuration(
                                            Duration(
                                              seconds: sliderValueSeconds
                                                  .toInt(),
                                            ),
                                          ),
                                        ),
                                        Text(_formatDuration(duration)),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),

                      SizedBox(height: 12),
                      // Controles de reproducción
                      StreamBuilder<PlaybackState>(
                        stream: audioHandler.playbackState,
                        builder: (context, snapshot) {
                          final state = snapshot.data;
                          final isPlaying = state?.playing ?? false;
                          final shuffleMode =
                              state?.shuffleMode ??
                              AudioServiceShuffleMode.none;
                          final isShuffle =
                              shuffleMode == AudioServiceShuffleMode.all;
                          final repeatMode =
                              state?.repeatMode ?? AudioServiceRepeatMode.none;

                          IconData repeatIcon;
                          Color repeatColor;
                          switch (repeatMode) {
                            case AudioServiceRepeatMode.one:
                              repeatIcon = Icons.repeat_one;
                              repeatColor = Theme.of(
                                context,
                              ).colorScheme.primary;
                              break;
                            case AudioServiceRepeatMode.all:
                              repeatIcon = Icons.repeat;
                              repeatColor = Theme.of(
                                context,
                              ).colorScheme.primary;
                              break;
                            default:
                              repeatIcon = Icons.repeat;
                              repeatColor = Colors.white;
                          }

                          return LayoutBuilder(
                            builder: (context, constraints) {
                              // Cálculo responsivo de tamaños
                              final double maxControlsWidth = constraints
                                  .maxWidth
                                  .clamp(280, 420);

                              final double iconSize =
                                  (maxControlsWidth / 400 * 44).clamp(34, 60);
                              final double sideIconSize =
                                  (maxControlsWidth / 400 * 56).clamp(42, 76);
                              final double mainIconSize =
                                  (maxControlsWidth / 400 * 76).clamp(60, 100);
                              final double playIconSize =
                                  (maxControlsWidth / 400 * 52).clamp(40, 80);

                              return Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.shuffle),
                                      color: isShuffle
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Colors.white,
                                      iconSize: iconSize,
                                      onPressed: () {
                                        audioHandler.setShuffleMode(
                                          isShuffle
                                              ? AudioServiceShuffleMode.none
                                              : AudioServiceShuffleMode.all,
                                        );
                                      },
                                      tooltip: 'Aleatorio',
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.skip_previous),
                                      color: Colors.white,
                                      iconSize: sideIconSize,
                                      onPressed: () =>
                                          audioHandler.skipToPrevious(),
                                    ),
                                    Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: iconSize / 4,
                                      ),
                                      child: Material(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(
                                          mainIconSize / 4,
                                        ),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            mainIconSize / 3.5,
                                          ),
                                          splashColor: Colors.transparent,
                                          highlightColor: Colors.transparent,
                                          onTap: () {
                                            isPlaying
                                                ? audioHandler.pause()
                                                : audioHandler.play();
                                          },
                                          child: SizedBox(
                                            width: mainIconSize,
                                            height: mainIconSize,
                                            child: Center(
                                              child: Icon(
                                                isPlaying
                                                    ? Icons.pause
                                                    : Icons.play_arrow,
                                                color: Colors.black87,
                                                size: playIconSize,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.skip_next),
                                      color: Colors.white,
                                      iconSize: sideIconSize,
                                      onPressed: () =>
                                          audioHandler.skipToNext(),
                                    ),
                                    IconButton(
                                      icon: Icon(repeatIcon),
                                      color: repeatColor,
                                      iconSize: iconSize,
                                      onPressed: () {
                                        AudioServiceRepeatMode newMode;
                                        if (repeatMode ==
                                            AudioServiceRepeatMode.none) {
                                          newMode = AudioServiceRepeatMode.all;
                                        } else if (repeatMode ==
                                            AudioServiceRepeatMode.all) {
                                          newMode = AudioServiceRepeatMode.one;
                                        } else {
                                          newMode = AudioServiceRepeatMode.none;
                                        }
                                        audioHandler.setRepeatMode(newMode);
                                      },
                                      tooltip: 'Repetir',
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),

                      const SizedBox(height: 34),
                      SafeArea(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final isSmall = constraints.maxWidth < 380;

                            return SizedBox(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    // Botón Guardar
                                    AnimatedTapButton(
                                      onTap: () async {
                                        // Acción del botón
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius: BorderRadius.circular(
                                            26,
                                          ),
                                        ),
                                        padding: EdgeInsets.symmetric(
                                          horizontal: isSmall ? 12 : 14,
                                          vertical: 14,
                                        ),
                                        margin: EdgeInsets.only(
                                          right: isSmall ? 8 : 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.playlist_add,
                                              color: Colors.white,
                                              size: isSmall ? 20 : 24,
                                            ),
                                            SizedBox(width: isSmall ? 6 : 8),
                                            Text(
                                              'Guardar',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w600,
                                                fontSize: isSmall ? 14 : 16,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // Botón Letra
                                    AnimatedTapButton(
                                      onTap: () async {
                                        // Acción del botón
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius: BorderRadius.circular(
                                            26,
                                          ),
                                        ),
                                        padding: EdgeInsets.symmetric(
                                          horizontal: isSmall ? 14 : 20,
                                          vertical: 14,
                                        ),
                                        margin: EdgeInsets.only(
                                          right: isSmall ? 8 : 12,
                                        ),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            26,
                                          ),
                                          splashColor: Colors
                                              .transparent, // <-- Quita el splash
                                          highlightColor: Colors.transparent,
                                          onTap: () async {
                                            showDialog(
                                              context: context,
                                              barrierDismissible: false,
                                              builder: (dialogContext) => AlertDialog(
                                                backgroundColor: Theme.of(
                                                  dialogContext,
                                                ).scaffoldBackgroundColor,
                                                content: SizedBox(
                                                  width:
                                                      MediaQuery.of(
                                                        dialogContext,
                                                      ).size.width *
                                                      0.7,
                                                  child: Row(
                                                    children: [
                                                      const CircularProgressIndicator(),
                                                      const SizedBox(width: 16),
                                                      const Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            "Buscando letra",
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                          ),
                                                          SizedBox(height: 8),
                                                          Text(
                                                            "⚠️ Función experimental.",
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.orange,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );

                                            final lyrics = await fetchLyrics(
                                              (mediaItem.artist ?? '').split(
                                                ',',
                                              )[0],
                                              mediaItem.title,
                                            );

                                            if (!context.mounted) return;
                                            Navigator.of(context).pop();
                                            if (!context.mounted) return;

                                            showDialog(
                                              context: context,
                                              builder: (dialogContext) => AlertDialog(
                                                backgroundColor: Theme.of(
                                                  dialogContext,
                                                ).scaffoldBackgroundColor,
                                                title: const Text(
                                                  'Letra',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                content: SizedBox(
                                                  width: double.maxFinite,
                                                  child: SingleChildScrollView(
                                                    child: Text(
                                                      lyrics ??
                                                          'Letra no encontrada.',
                                                      style: const TextStyle(
                                                        fontSize: 16,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    child: const Text('Cerrar'),
                                                    onPressed: () =>
                                                        Navigator.of(
                                                          dialogContext,
                                                        ).pop(),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.lyrics,
                                                color: Colors.white,
                                                size: isSmall ? 20 : 24,
                                              ),
                                              SizedBox(width: isSmall ? 6 : 8),
                                              Text(
                                                'Letra',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: isSmall ? 14 : 16,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),

                                    // Botón Compartir
                                    AnimatedTapButton(
                                      onTap: () async {
                                        // Acción del botón
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white10,
                                          borderRadius: BorderRadius.circular(
                                            26,
                                          ),
                                        ),
                                        padding: EdgeInsets.symmetric(
                                          horizontal: isSmall ? 14 : 20,
                                          vertical: 16,
                                        ),
                                        child: InkWell(
                                          splashColor: Colors
                                              .transparent, // <-- Quita el splash
                                          highlightColor: Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            26,
                                          ),
                                          onTap: () async {
                                            final dataPath =
                                                mediaItem.extras?['data']
                                                    as String?;
                                            if (dataPath != null &&
                                                dataPath.isNotEmpty) {
                                              await Share.shareXFiles([
                                                XFile(dataPath),
                                              ], text: mediaItem.title);
                                            }
                                          },
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.share,
                                                color: Colors.white,
                                                size: isSmall ? 18 : 22,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
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
    final textPainter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final textWidth = textPainter.size.width;

    if (textWidth > widget.maxWidth) {
      if (!_showMarquee) {
        return SizedBox(
          height: 40,
          width: widget.maxWidth,
          child: Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      }
      return SizedBox(
        height: 40,
        width: widget.maxWidth,
        child: Marquee(
          key: ValueKey(widget.text),
          text: widget.text,
          style: widget.style!,
          velocity: 30.0,
          blankSpace: 40.0,
          pauseAfterRound: const Duration(seconds: 2),
          startPadding: 0.0,
          fadingEdgeStartFraction: 0.1,
          fadingEdgeEndFraction: 0.1,
        ),
      );
    } else {
      return SizedBox(
        height: 40,
        width: widget.maxWidth,
        child: Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
  }
}

class AnimatedTapButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const AnimatedTapButton({
    super.key,
    required this.child,
    required this.onTap,
  });

  @override
  State<AnimatedTapButton> createState() => _AnimatedTapButtonState();
}

class _AnimatedTapButtonState extends State<AnimatedTapButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class SleepTimerOptionsSheet extends StatelessWidget {
  const SleepTimerOptionsSheet({super.key});

  void _setTimer(BuildContext context, Duration duration) {
    (audioHandler as MyAudioHandler).startSleepTimer(duration);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Temporizador: ${_formatDuration(duration)}')),
    );
  }

  static String _formatDuration(Duration duration) {
    if (duration.inMinutes == 60) return '1 hora';
    return '${duration.inMinutes} minuto${duration.inMinutes > 1 ? 's' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('1 minuto'),
            onTap: () => _setTimer(context, const Duration(minutes: 1)),
          ),
          ListTile(
            title: const Text('5 minutos'),
            onTap: () => _setTimer(context, const Duration(minutes: 5)),
          ),
          ListTile(
            title: const Text('15 minutos'),
            onTap: () => _setTimer(context, const Duration(minutes: 15)),
          ),
          ListTile(
            title: const Text('30 minutos'),
            onTap: () => _setTimer(context, const Duration(minutes: 30)),
          ),
          ListTile(
            title: const Text('1 hora'),
            onTap: () => _setTimer(context, const Duration(minutes: 60)),
          ),
          const Divider(),
          ListTile(
            title: const Text('Cancelar temporizador'),
            onTap: () {
              (audioHandler as MyAudioHandler).cancelSleepTimer();
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Temporizador cancelado')),
              );
            },
          ),
        ],
      ),
    );
  }
}
