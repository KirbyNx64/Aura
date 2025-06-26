import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import 'package:music/main.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:share_plus/share_plus.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:palette_generator/palette_generator.dart';
import 'dart:typed_data';
import 'dart:ui';

final OnAudioQuery _audioQuery = OnAudioQuery();

// Future<String?> fetchLyrics(String artist, String title) async {
//   try {
//     final response = await http
//         .get(Uri.parse('https://api.lyrics.ovh/v1/$artist/$title'))
//         .timeout(const Duration(seconds: 8));

//     if (response.statusCode == 200) {
//       final data = json.decode(response.body);
//       return data['lyrics'];
//     } else {
//       return null;
//     }
//   } catch (e) {
//     return null;
//   }
// }

class _LyricLine {
  final Duration time;
  final String text;
  _LyricLine(this.time, this.text);
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
  bool _showLyrics = false;
  String? _syncedLyrics;
  bool _loadingLyrics = false;
  List<_LyricLine> _lyricLines = [];
  int _currentLyricIndex = 0;
  final ScrollController _lyricsScrollController = ScrollController();
  List<GlobalKey> _lyricLineKeys = [];
  String? _lastMediaItemId;
  Color? _dominantColor;
  Color? _secondaryColor;
  bool _loadingDominantColor = false;

  Future<void> _updateDominantColor(MediaItem mediaItem) async {
    try {
      final songId = mediaItem.extras?['songId'] as int?;
      Uint8List? artworkBytes;

      if (songId != null) {
        artworkBytes = await _audioQuery.queryArtwork(
          songId,
          ArtworkType.AUDIO,
          format: ArtworkFormat.PNG,
        );
      }

      if (!mounted) return;

      ImageProvider imageProvider;
      if (artworkBytes != null && artworkBytes.isNotEmpty) {
        imageProvider = MemoryImage(artworkBytes);
      } else {
        imageProvider = const AssetImage('assets/icon.png');
      }

      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        size: const Size(200, 200),
        maximumColorCount: 8,
      );

      if (!mounted) return;

      final predefinedColors = <Color>[
        Colors.blue.shade200,
        Colors.red.shade200,
        Colors.green.shade200,
        Colors.orange.shade200,
        Colors.purple.shade200,
        Colors.teal.shade200,
        Colors.pink.shade200,
        Colors.amber.shade200,
        Colors.cyan.shade200,
        Colors.indigo.shade200,
      ];

      Color findNearestColor(Color target, List<Color> candidates) {
        double distance(Color a, Color b) {
          final dr =
              ((a.r * 255).round() & 0xff) - ((b.r * 255).round() & 0xff);
          final dg =
              ((a.g * 255).round() & 0xff) - ((b.g * 255).round() & 0xff);
          final db =
              ((a.b * 255).round() & 0xff) - ((b.b * 255).round() & 0xff);
          return (dr * dr + dg * dg + db * db).toDouble();
        }

        candidates.sort(
          (a, b) => distance(target, a).compareTo(distance(target, b)),
        );
        return candidates.first;
      }

      final detected = palette.dominantColor?.color ?? Colors.white;
      final nearest = findNearestColor(detected, predefinedColors);

      if (!mounted) return;

      setState(() {
        _dominantColor = nearest;
        _secondaryColor = predefinedColors.firstWhere(
          (c) => c != nearest,
          orElse: () => nearest,
        );
      });
    } catch (e) {
      if (!mounted) return;
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
    }
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
      child: Icon(Icons.music_note, color: Colors.white54, size: size * 0.5),
    );
  }

  Future<void> _loadLyrics(MediaItem mediaItem) async {
    if (!mounted) return; // por si acaso
    setState(() {
      _loadingLyrics = true;
      _lyricLines = [];
      _currentLyricIndex = 0;
    });

    final lyricsData = await SyncedLyricsService.getSyncedLyrics(mediaItem);
    if (!mounted) return; // chequeo antes de seguir

    final synced = lyricsData?['synced'];
    if (synced != null) {
      final lines = synced.split('\n');
      final parsed = <_LyricLine>[];
      final reg = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\](.*)');
      for (final line in lines) {
        final match = reg.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          final ms = match.group(3) != null
              ? int.parse(match.group(3)!.padRight(3, '0'))
              : 0;
          final text = match.group(4)!.trim();
          parsed.add(
            _LyricLine(
              Duration(minutes: min, seconds: sec, milliseconds: ms),
              text,
            ),
          );
        }
      }
      if (!mounted) return; // chequeo antes de actualizar
      setState(() {
        _lyricLines = parsed;
        _lyricLineKeys = List.generate(parsed.length, (_) => GlobalKey());
        _loadingLyrics = false;
      });
    } else {
      if (!mounted) return;
      setState(() {
        _lyricLines = [];
        _loadingLyrics = false;
      });
    }
  }

  @override
  void dispose() {
    _lyricsScrollController.dispose();
    super.dispose();
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
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Añadir a playlist'),
              onTap: () async {
                if (!mounted) {
                  return;
                }
                final safeContext = context;
                Navigator.of(safeContext).pop();
                await _showAddToPlaylistDialog(safeContext, mediaItem);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Compartir archivo de audio'),
              onTap: () async {
                Navigator.of(context).pop();
                final dataPath = mediaItem.extras?['data'] as String?;
                if (dataPath != null && dataPath.isNotEmpty) {
                  await Share.shareXFiles([
                    XFile(dataPath),
                  ], text: mediaItem.title);
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
                  final seconds = remaining.inSeconds % 60;
                  return 'Tiempo restante: $minutes:${seconds.toString().padLeft(2, '0')} min';
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
  }

  Future<void> _showAddToPlaylistDialog(
    BuildContext safeContext,
    MediaItem mediaItem,
  ) async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    final TextEditingController controller = TextEditingController();

    if (!safeContext.mounted) return;

    showModalBottomSheet(
      context: safeContext,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Guardar en playlist',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 16),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'No tienes playlists aún.\nCrea una nueva abajo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            if (playlists.isNotEmpty)
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (context, i) {
                      final pl = playlists[i];
                      return ListTile(
                        leading: const Icon(Icons.queue_music, size: 32),
                        title: Text(
                          pl['name'],
                          style: const TextStyle(fontSize: 18),
                        ),
                        onTap: () async {
                          final allSongs = await _audioQuery.querySongs();
                          final songList = allSongs
                              .where(
                                (s) =>
                                    s.data == (mediaItem.extras?['data'] ?? ''),
                              )
                              .toList();

                          if (songList.isNotEmpty) {
                            await PlaylistsDB().addSongToPlaylist(
                              pl['id'],
                              songList.first,
                            );
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Nueva playlist',
                    ),
                    onSubmitted: (value) async {
                      await _createPlaylistAndAddSong(
                        context,
                        controller,
                        mediaItem,
                      );
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    await _createPlaylistAndAddSong(
                      context,
                      controller,
                      mediaItem,
                    );
                    playlistsShouldReload.value = !playlistsShouldReload.value;
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _createPlaylistAndAddSong(
    BuildContext context,
    TextEditingController controller,
    MediaItem mediaItem,
  ) async {
    final name = controller.text.trim();
    if (name.isEmpty) return;

    final playlistId = await PlaylistsDB().createPlaylist(name);
    final allSongs = await _audioQuery.querySongs();
    final songList = allSongs
        .where((s) => s.data == (mediaItem.extras?['data'] ?? ''))
        .toList();

    if (songList.isNotEmpty) {
      await PlaylistsDB().addSongToPlaylist(playlistId, songList.first);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width;
    final height = size.height;

    // Tamaños relativos
    final sizeScreen = MediaQuery.of(context).size;
    final aspectRatio = sizeScreen.height / sizeScreen.width;

    // Para 16:9 (≈1.77)
    final is16by9 = (aspectRatio < 1.85);

    // Para 18:9 (≈2.0)
    final is18by9 = (aspectRatio >= 1.95 && aspectRatio < 2.05);

    // Para 19.5:9 (≈2.16)
    final is195by9 = (aspectRatio >= 2.10);

    final isSmallScreen = height < 650;
    final artworkSize = isSmallScreen ? width * 0.6 : width * 0.8;
    double progressBarWidth;
    if (width <= 400) {
      progressBarWidth = isSmallScreen
          ? artworkSize * 2
          : is16by9
          ? artworkSize * 1.8
          : artworkSize * 2;
    } else if (width <= 800) {
      progressBarWidth = isSmallScreen
          ? artworkSize * 1.3
          : is16by9
          ? artworkSize * 1.2
          : artworkSize * 1.3;
    } else {
      progressBarWidth = isSmallScreen
          ? (artworkSize * 1.5).clamp(0, width * 0.9)
          : is16by9
          ? (artworkSize * 1.4).clamp(0, width * 0.9)
          : (artworkSize * 1.5).clamp(0, width * 0.9);
    }
    final buttonFontSize = width * 0.04 + 10;

    return GestureDetector(
      onVerticalDragUpdate: (details) {
        if (details.primaryDelta != null && details.primaryDelta! > 6) {
          Navigator.of(context).maybePop(); // Deslizar hacia abajo: cerrar
        } else if (details.primaryDelta != null && details.primaryDelta! < -6) {
          // Deslizar hacia arriba: mostrar lista de reproducción
          showModalBottomSheet(
            context: context,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            isScrollControlled: true,
            builder: (context) {
              final queue = audioHandler.queue.value;
              final maxHeight = MediaQuery.of(context).size.height * 0.6;
              return SafeArea(
                child: Container(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: StreamBuilder<MediaItem?>(
                    stream: audioHandler.mediaItem,
                    builder: (context, snapshot) {
                      final currentMediaItem =
                          snapshot.data ?? audioHandler.mediaItem.valueOrNull;
                      return ListView.builder(
                        shrinkWrap: true,
                        itemCount: queue.length + 1, // +1 para el encabezado
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            // Encabezado fijo como primer elemento de la lista
                            return Column(
                              children: [
                                const SizedBox(height: 12),
                                Container(
                                  width: 40,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  'Lista de reproducción',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ],
                            );
                          }
                          final item = queue[index - 1];
                          final isCurrent = item.id == currentMediaItem?.id;
                          return ListTile(
                            leading: ArtworkHeroCached(
                              songId: item.extras?['songId'] ?? 0,
                              size: 48,
                              borderRadius: BorderRadius.circular(8),
                              heroTag:
                                  'queue_artwork_${item.extras?['songId'] ?? item.id}_$index',
                            ),
                            title: Text(
                              item.title,
                              maxLines: 1,
                              style: TextStyle(
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            subtitle: Text(
                              item.artist ?? 'Desconocido',
                              maxLines: 1,
                            ),
                            selected: isCurrent,
                            selectedTileColor: Theme.of(
                              context,
                            ).colorScheme.primaryContainer,
                            onTap: () {
                              audioHandler.skipToQueueItem(index - 1);
                              // No cerramos el modal, así se mantiene abierto
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              );
            },
          );
        }
      },
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        initialData: widget.initialMediaItem,
        builder: (context, snapshot) {
          final mediaItem = snapshot.data;
          if (_showLyrics &&
              mediaItem != null &&
              (mediaItem.id != _lastMediaItemId)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _showLyrics = false;
                });
              }
            });
          }
          _lastMediaItemId = mediaItem?.id;
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
              backgroundColor: Theme.of(context).colorScheme.surface,
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
            resizeToAvoidBottomInset: true,
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? width * 0.010 : width * 0.035,
                    vertical: isSmallScreen ? height * 0.015 : height * 0.03,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          ArtworkHeroCached(
                            songId: mediaItem.extras?['songId'] ?? 0,
                            size: artworkSize,
                            borderRadius: BorderRadius.circular(
                              artworkSize * 0.06,
                            ),
                            heroTag:
                                'now_playing_artwork_${mediaItem.extras?['songId'] ?? mediaItem.id}',
                            currentIndex: currentIndex,
                            songIdList: songIdList,
                          ),
                          if (_showLyrics)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                artworkSize * 0.06,
                              ),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                                child: Container(
                                  width: artworkSize,
                                  height: artworkSize,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withAlpha(
                                      (0.75 * 255).toInt(),
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      artworkSize * 0.06,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.all(18),
                                  child: _loadingDominantColor
    ? const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      )
    : _loadingLyrics
                                      ? const CircularProgressIndicator(
                                          color: Colors.white,
                                        )
                                      : _lyricLines.isEmpty
                                      ? Text(
                                          _syncedLyrics ??
                                              'Letra no encontrada.',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                          ),
                                          textAlign: TextAlign.center,
                                        )
                                      : StreamBuilder<Duration>(
                                          stream:
                                              (audioHandler as MyAudioHandler)
                                                  .positionStream,
                                          builder: (context, posSnapshot) {
                                            final position =
                                                posSnapshot.data ??
                                                Duration.zero;
                                            int idx = 0;
                                            for (
                                              int i = 0;
                                              i < _lyricLines.length;
                                              i++
                                            ) {
                                              if (position >=
                                                  _lyricLines[i].time) {
                                                idx = i;
                                              } else {
                                                break;
                                              }
                                            }
                                            // Solo actualiza si cambia el índice
                                            WidgetsBinding.instance.addPostFrameCallback((
                                              _,
                                            ) {
                                              if (mounted) {
                                                if (_currentLyricIndex != idx) {
                                                  setState(
                                                    () => _currentLyricIndex =
                                                        idx,
                                                  );
                                                }
                                                // Scroll automático para centrar la línea resaltada SIEMPRE
                                                if (_lyricLineKeys.length >
                                                    idx) {
                                                  final context =
                                                      _lyricLineKeys[idx]
                                                          .currentContext;
                                                  if (context != null) {
                                                    Scrollable.ensureVisible(
                                                      context,
                                                      duration: const Duration(
                                                        milliseconds: 350,
                                                      ),
                                                      alignment: 0.5,
                                                      curve: Curves.easeOut,
                                                    );
                                                  } else if (_lyricsScrollController
                                                      .hasClients) {
                                                    // Respaldo: scroll manual si el widget aún no está montado
                                                    final lineHeight =
                                                        32.0; // Ajusta según tu diseño
                                                    final offset =
                                                        (idx + 1) * lineHeight -
                                                        (_lyricsScrollController
                                                                .position
                                                                .viewportDimension /
                                                            2) +
                                                        (lineHeight / 2);
                                                    _lyricsScrollController.animateTo(
                                                      offset.clamp(
                                                        _lyricsScrollController
                                                            .position
                                                            .minScrollExtent,
                                                        _lyricsScrollController
                                                            .position
                                                            .maxScrollExtent,
                                                      ),
                                                      duration: const Duration(
                                                        milliseconds: 350,
                                                      ),
                                                      curve: Curves.easeOut,
                                                    );
                                                  }
                                                }
                                              }
                                            });
                                            return ListView.builder(
                                              controller:
                                                  _lyricsScrollController,
                                              physics:
                                                  const NeverScrollableScrollPhysics(),
                                              itemCount:
                                                  _lyricLines.length +
                                                  2, // +2: espacio arriba y abajo
                                              shrinkWrap: true,
                                              itemBuilder: (context, i) {
                                                if (i == 0 ||
                                                    i ==
                                                        _lyricLines.length +
                                                            1) {
                                                  return SizedBox(
                                                    height: artworkSize / 10,
                                                  );
                                                }
                                                final lyricIndex = i - 1;
                                                if (lyricIndex < 0 ||
                                                    lyricIndex >=
                                                        _lyricLines.length) {
                                                  return const SizedBox.shrink();
                                                }
                                                return SizedBox(
                                                  key:
                                                      _lyricLineKeys.length >
                                                          lyricIndex
                                                      ? _lyricLineKeys[lyricIndex]
                                                      : null,
                                                  child: Text(
                                                    _lyricLines[lyricIndex]
                                                        .text,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color:
                                                          lyricIndex ==
                                                              _currentLyricIndex
                                                          ? (_dominantColor ??
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .primary)
                                                          : Colors.white70,
                                                      fontWeight:
                                                          lyricIndex ==
                                                              _currentLyricIndex
                                                          ? FontWeight.bold
                                                          : FontWeight.normal,
                                                      fontSize:
                                                          lyricIndex ==
                                                              _currentLyricIndex
                                                          ? 18
                                                          : 15,
                                                    ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(
                        height: isSmallScreen
                            ? 20
                            : is16by9
                            ? height * 0.045
                            : height * 0.03,
                      ),
                      SizedBox(
                        width: isSmallScreen ? 300 : artworkSize,
                        child: Row(
                          children: [
                            Expanded(
                              child: TitleMarquee(
                                text: mediaItem.title,
                                maxWidth:
                                    artworkSize - (isSmallScreen ? 60 : 40),
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
                        width: isSmallScreen ? 300 : artworkSize,
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
                                          style: TextStyle(
                                            fontSize: is16by9 ? 18 : 15,
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(duration),
                                          style: TextStyle(
                                            fontSize: is16by9 ? 18 : 15,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),

                      SizedBox(
                        height: isSmallScreen
                            ? 12
                            : is16by9
                            ? 24
                            : 12,
                      ),
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
                              final double maxControlsWidth = is16by9
                                  ? constraints.maxWidth.clamp(280, 350)
                                  : constraints.maxWidth.clamp(340, 480);

                              final double iconSize =
                                  (maxControlsWidth / 400 * 44).clamp(34, 60);
                              final double sideIconSize =
                                  (maxControlsWidth / 400 * 56).clamp(42, 76);
                              final double mainIconSize =
                                  (maxControlsWidth / 400 * 76).clamp(60, 100);
                              final double playIconSize =
                                  (maxControlsWidth / 400 * 52).clamp(40, 80);

                              return Center(
                                child: Container(
                                  alignment: Alignment.center,
                                  constraints: BoxConstraints(
                                    maxWidth: progressBarWidth,
                                  ),
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
                                            newMode =
                                                AudioServiceRepeatMode.all;
                                          } else if (repeatMode ==
                                              AudioServiceRepeatMode.all) {
                                            newMode =
                                                AudioServiceRepeatMode.one;
                                          } else {
                                            newMode =
                                                AudioServiceRepeatMode.none;
                                          }
                                          audioHandler.setRepeatMode(newMode);
                                        },
                                        tooltip: 'Repetir',
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),

                      if (!is16by9 && !isSmallScreen) ...[
                        SizedBox(
                          height: is18by9
                              ? 20
                              : is195by9
                              ? 38
                              : 16,
                        ),
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
                                          if (!mounted) {
                                            return;
                                          }

                                          final safeContext = context;
                                          await _showAddToPlaylistDialog(
                                            safeContext,
                                            mediaItem,
                                          );
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
    if (!_showLyrics) {
      setState(() {
        _loadingDominantColor = true;
        _showLyrics = true;
      });
      await _updateDominantColor(mediaItem);
      setState(() {
        _loadingDominantColor = false;
      });
      await _loadLyrics(mediaItem);
    } else {
      setState(() {
        _showLyrics = false;
      });
    }
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
                                            splashColor: Colors.transparent,
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
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = audioHandler.mediaItem.valueOrNull;
    final playbackState = audioHandler.playbackState.valueOrNull;
    final position = playbackState?.position ?? Duration.zero;
    final duration = mediaItem?.duration ?? Duration.zero;
    final remaining = duration > position ? duration - position : Duration.zero;
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
          ListTile(
            title: const Text('Hasta que la canción termine'),
            onTap: remaining > Duration.zero
                ? () => _setTimer(context, remaining)
                : null,
          ),
          const Divider(),
          ListTile(
            title: const Text('Cancelar temporizador'),
            onTap: () {
              (audioHandler as MyAudioHandler).cancelSleepTimer();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}
