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

import 'dart:async';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

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

class LyricLine {
  final Duration time;
  final String text;
  LyricLine(this.time, this.text);
}

class FullPlayerScreen extends StatefulWidget {
  final MediaItem? initialMediaItem;
  final Uri? initialArtworkUri;

  const FullPlayerScreen({super.key, this.initialMediaItem, this.initialArtworkUri});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  double? _dragValueSeconds;
  bool _showLyrics = false;
  String? _syncedLyrics;
  bool _loadingLyrics = false;
  List<LyricLine> _lyricLines = [];
  int _currentLyricIndex = 0;
  final ScrollController _lyricsScrollController = ScrollController();
  String? _lastMediaItemId;
  Timer? _seekDebounceTimer;
  int? _lastSeekMs;
  DateTime _lastSeekTime = DateTime.fromMillisecondsSinceEpoch(0);
  final int _seekThrottleMs = 300;
  Duration? _lastKnownPosition;

  late AnimationController _favController;
  late Animation<double> _favAnimation;
  bool _lastIsFav = false;
  late AnimationController _playPauseController;

  // Flag para usar initialArtworkUri solo en el primer build
  // bool _usedInitialArtwork = false;

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

  String _formatSleepTimerDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')} h';
    } else {
      return '$minutes:${seconds.toString().padLeft(2, '0')} min';
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
          // Optimización: Cache de imagen
          cacheWidth: (size * MediaQuery.of(context).devicePixelRatio).round(),
          cacheHeight: (size * MediaQuery.of(context).devicePixelRatio).round(),
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
      child: Icon(Icons.music_note, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.54), size: size * 0.5),
    );
  }

  Future<void> _loadLyrics(MediaItem mediaItem) async {
    if (!mounted) return;
    setState(() {
      _loadingLyrics = true;
      _lyricLines = [];
      _currentLyricIndex = 0;
    });

    final lyricsData = await SyncedLyricsService.getSyncedLyrics(mediaItem);
    if (!mounted) return; 

    final synced = lyricsData?.synced;
    if (synced != null) {
      final lines = synced.split('\n');
      final parsed = <LyricLine>[];
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
            LyricLine(
              Duration(minutes: min, seconds: sec, milliseconds: ms),
              text,
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _lyricLines = parsed;
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
  void initState() {
    super.initState();
    _favController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _favAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _favController, curve: Curves.elasticOut),
    );
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: 1.0, // Empieza en pausa (o 0.0 si quieres que empiece en play)
    );
    // Eliminado: _loadQueueSource();
    // Eliminado: (audioHandler as MyAudioHandler).queueSourceNotifier.addListener(_onQueueSourceChanged);
  }

  @override
  void dispose() {
    _seekDebounceTimer?.cancel();
    _lyricsScrollController.dispose();
    _favController.dispose();
    _playPauseController.dispose();
    // Eliminado: (audioHandler as MyAudioHandler).queueSourceNotifier.removeListener(_onQueueSourceChanged);
    super.dispose();
  }

  Future<void> _showSongOptions(
    BuildContext context,
    MediaItem mediaItem,
  ) async {
    final isFav = await FavoritesDB().isFavorite(
      mediaItem.extras?['data'] ?? '',
    );

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
              title: Text(isFav ? LocaleProvider.tr('remove_from_favorites') : LocaleProvider.tr('add_to_favorites')),
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
              title: Text(LocaleProvider.tr('add_to_playlist')),
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
              leading: const Icon(Icons.lyrics),
              title: Text(LocaleProvider.tr('show_lyrics')),
              onTap: () async {
                Navigator.of(context).pop();
                if (!_showLyrics) {
                  setState(() {
                    _showLyrics = true;
                  });
                  await _loadLyrics(mediaItem);
                } else {
                  setState(() {
                    _showLyrics = false;
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: Text(LocaleProvider.tr('share_audio_file')),
              onTap: () async {
                Navigator.of(context).pop();
                final dataPath = mediaItem.extras?['data'] as String?;
                if (dataPath != null && dataPath.isNotEmpty) {
                  await SharePlus.instance.share(
                    ShareParams(
                      text: mediaItem.title,
                      files: [XFile(dataPath)],
                    ),
                  );
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
                  return '${LocaleProvider.tr('sleep_timer_remaining')}: ${_formatSleepTimerDuration(remaining)}';
                } else {
                  return LocaleProvider.tr('sleep_timer');
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
              title: Text(LocaleProvider.tr('song_info')),
              onTap: () {
                Navigator.of(context).pop();
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(LocaleProvider.tr('song_info')),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${LocaleProvider.tr('title')}: ${mediaItem.title}\n'),
                        Text('${LocaleProvider.tr('artist')}: ${mediaItem.artist ?? LocaleProvider.tr('unknown_artist')}\n'),
                        Text('${LocaleProvider.tr('album')}: ${mediaItem.album ?? LocaleProvider.tr('unknown_artist')}\n'),
                        Text('${LocaleProvider.tr('location')}: ${mediaItem.extras?['data'] ?? ""}\n'),
                        Text(
                          '${LocaleProvider.tr('duration')}: ${mediaItem.duration != null ? Duration(milliseconds: mediaItem.duration!.inMilliseconds).toString().split('.').first : "?"}',
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        child: Text(LocaleProvider.tr('close')),
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
            Text(
              LocaleProvider.tr('save_to_playlist'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 16),
            if (playlists.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  LocaleProvider.tr('no_playlists_yet'),
                  textAlign: TextAlign.center,
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
                          pl.name,
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
                              pl.id,
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
                    decoration: InputDecoration(
                      labelText: LocaleProvider.tr('new_playlist'),
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
    final artworkSize = isSmallScreen ? width * 0.6 : width * 0.85;
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
              final queue = audioHandler?.queue.value;
              final maxHeight = MediaQuery.of(context).size.height * 0.6;
              return SafeArea(
                child: Container(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: StreamBuilder<MediaItem?>(
                    stream: audioHandler?.mediaItem,
                    builder: (context, snapshot) {
                      final currentMediaItem =
                          snapshot.data ?? audioHandler?.mediaItem.valueOrNull;
                      
                      // Encontrar el índice de la canción actual
                      int currentIndex = -1;
                      if (currentMediaItem != null) {
                        for (int i = 0; i < queue!.length; i++) {
                          if (queue[i].id == currentMediaItem.id) {
                            currentIndex = i;
                            break;
                          }
                        }
                      }
                      
                      return _PlaylistListView(
                        queue: queue ?? [],
                        currentMediaItem: currentMediaItem,
                        currentIndex: currentIndex,
                        maxHeight: maxHeight,
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
        stream: audioHandler?.mediaItem,
        initialData: widget.initialMediaItem,
        builder: (context, snapshot) {
          final mediaItem = snapshot.data;
          
          // Solo procesar si es una canción nueva
          if (mediaItem != null && mediaItem.id != _lastMediaItemId) {
            _lastMediaItemId = mediaItem.id;
            
            // Ocultar letras si estaban mostradas
            if (_showLyrics) {
              _showLyrics = false;
            }
          }

          // Usar el MediaItem inicial si no hay uno actual
          final currentMediaItem = mediaItem ?? widget.initialMediaItem;



          return WillPopScope(
            onWillPop: () async {
              return !playLoadingNotifier.value;
            },
            child: Scaffold(
              appBar: AppBar(
              leading: ValueListenableBuilder<bool>(
                valueListenable: playLoadingNotifier,
                builder: (context, isLoading, _) {
                  return IconButton(
                    iconSize: 38,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: isLoading ? null : () => Navigator.of(context).pop(),
                  );
                },
              ),
              title: FutureBuilder<SharedPreferences>(
                future: SharedPreferences.getInstance(),
                builder: (context, snapshot) {
                  final prefs = snapshot.data;
                  final queueSource = prefs?.getString('last_queue_source');
                  if (queueSource != null && queueSource.isNotEmpty) {
                    return Center(
                      child: RichText(
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: LocaleProvider.tr('playing_from'),
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: Theme.of(context).textTheme.titleMedium?.color?.withValues(alpha: 0.5),
                                fontWeight: FontWeight.normal,
                              ),
                            ),
                            TextSpan(
                              text: queueSource,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).textTheme.titleMedium?.color?.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  } else {
                    return const SizedBox.shrink();
                  }
                },
              ),
              backgroundColor: Theme.of(context).colorScheme.surface,
              actions: [
                IconButton(
                  iconSize: 38,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {
                    _showSongOptions(context, currentMediaItem!);
                  },
                ),
              ],
            ),
            resizeToAvoidBottomInset: true,
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? width * 0.005 : width * 0.013,
                    vertical: isSmallScreen ? height * 0.015 : height * 0.03,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          Builder(
                            builder: (context) {
                              // Usar initialArtworkUri solo en el primer build
                              // Uri? initialUri;
                              // if (!_usedInitialArtwork && widget.initialArtworkUri != null) {
                              //   initialUri = widget.initialArtworkUri;
                              //   _usedInitialArtwork = true;
                              // }
                              return ArtworkHeroCached(
                                artUri: currentMediaItem!.artUri,
                                size: artworkSize,
                                borderRadius: BorderRadius.circular(artworkSize * 0.06),
                                heroTag: 'now_playing_artwork_${(currentMediaItem.extras?['songId'] ?? currentMediaItem.id).toString()}',
                              );
                            },
                          ),
                          if (_showLyrics)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                artworkSize * 0.06,
                              ),
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
                                child: _loadingLyrics
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                        ),
                                      )
                                    : _lyricLines.isEmpty
                                    ? Text(
                                        _syncedLyrics ??
                                            LocaleProvider.tr('lyrics_not_found'),
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
                                          // Actualizar índice directamente sin setState
                                          if (_currentLyricIndex != idx) {
                                            _currentLyricIndex = idx;
                                          }
                                          return VerticalMarqueeLyrics(
                                            lyricLines: _lyricLines,
                                            currentLyricIndex: _currentLyricIndex,
                                            context: context,
                                            artworkSize: artworkSize,
                                          );
                                        },
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
                        width: is16by9 ? 310 : isSmallScreen ? 300 : artworkSize,
                        child: Row(
                          children: [
                            Expanded(
                              child: TitleMarquee(
                                text: currentMediaItem!.title,
                                maxWidth:
                                    artworkSize - (isSmallScreen ? 60 : 40),
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface,
                                      fontSize: buttonFontSize + 0.75,
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ),
                            SizedBox(width: width * 0.04),
                            FutureBuilder<bool>(
                              future: (currentMediaItem.extras?['isStreaming'] == true || currentMediaItem.extras?['data'] == null || (currentMediaItem.extras?['data'] as String?)?.startsWith('http') == true)
                                  ? Future.value(false)
                                  : FavoritesDB().isFavorite(currentMediaItem.extras?['data'] ?? ''),
                              builder: (context, favSnapshot) {
                                final isFav = favSnapshot.data ?? false;
                                // Trigger heartbeat animation only when state changes
                                if (_lastIsFav != isFav) {
                                  _favController.forward(from: 0.0);
                                  _lastIsFav = isFav;
                                }
                                return ValueListenableBuilder<bool>(
                                  valueListenable: playLoadingNotifier,
                                  builder: (context, isLoading, _) {
                                    return AnimatedTapButton(
                                      onTap: () {
                                        if (isLoading) return;
                                        unawaited(() async {
                                          final path =
                                              currentMediaItem.extras?['data'] ?? '';
                                          if (path.isEmpty) return;

                                          if (isFav) {
                                            await FavoritesDB().removeFavorite(path);
                                            favoritesShouldReload.value =
                                                !favoritesShouldReload.value;
                                            if (!context.mounted) return;
                                            setState(() {});
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
                                                SnackBar(
                                                  content: Text(
                                                    LocaleProvider.tr('song_not_found'),
                                                  ),
                                                ),
                                              );
                                              return;
                                            }

                                            final song = songList.first;
                                            await _addToFavorites(song);
                                            if (!context.mounted) return;
                                            setState(() {}); // <-- fuerza actualización visual
                                          }
                                        }());
                                      },
                                      child: ScaleTransition(
                                        scale: _favAnimation,
                                        child: Icon(
                                          isFav ? Icons.favorite : Icons.favorite_border,
                                          size: 34,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: height * 0.01),
                      SizedBox(
                        width: is16by9 ? 310 : isSmallScreen ? 300 : artworkSize,
                        child: Text(
                          (currentMediaItem.artist == null ||
                                  currentMediaItem.artist!.trim().isEmpty)
                              ? LocaleProvider.tr('unknown_artist')
                              : currentMediaItem.artist!,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
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
                      ValueListenableBuilder<bool>(
                        valueListenable: (audioHandler as MyAudioHandler).isQueueTransitioning,
                        builder: (context, isTransitioning, _) {
                          return StreamBuilder<Duration>(
                            stream: (audioHandler as MyAudioHandler).positionStream,
                            initialData: Duration.zero,
                            builder: (context, posSnapshot) {
                              Duration position = posSnapshot.data ?? Duration.zero;
                              if (!isTransitioning) {
                                _lastKnownPosition = position;
                              } else if (_lastKnownPosition != null) {
                                position = _lastKnownPosition!;
                              }
                              return StreamBuilder<Duration?>
                                (
                                stream: (audioHandler as MyAudioHandler).player.durationStream,
                                builder: (context, durationSnapshot) {
                                  final fallbackDuration = durationSnapshot.data;
                                  final mediaDuration = currentMediaItem.duration;
                                  // Si no hay duración, usa 1 segundo como mínimo para el slider
                                  final duration = (mediaDuration != null && mediaDuration.inMilliseconds > 0)
                                    ? mediaDuration
                                    : (fallbackDuration != null && fallbackDuration.inMilliseconds > 0)
                                      ? fallbackDuration
                                      : const Duration(seconds: 1);
                                  final durationMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
                                  final sliderValueMs = (_dragValueSeconds != null)
                                      ? (_dragValueSeconds! * 1000).clamp(0, durationMs.toDouble())
                                      : position.inMilliseconds.clamp(0, durationMs).toDouble();
                                  return Column(
                                    children: [
                                      SizedBox(
                                        width: progressBarWidth,
                                        child: Slider(
                                          min: 0.0,
                                          max: durationMs.toDouble(),
                                          value: sliderValueMs.toDouble(),
                                          onChanged: (value) {
                                            _dragValueSeconds = value / 1000.0;
                                            setState(() {});
                                          },
                                          onChangeEnd: (value) {
                                            final now = DateTime.now();
                                            final ms = value.toInt();
                                            if (now.difference(_lastSeekTime).inMilliseconds > _seekThrottleMs) {
                                              audioHandler?.seek(Duration(milliseconds: ms));
                                              _lastSeekTime = now;
                                            } else {
                                              _lastSeekMs = ms;
                                              Future.delayed(Duration(milliseconds: _seekThrottleMs), () {
                                                if (_lastSeekMs != null && DateTime.now().difference(_lastSeekTime).inMilliseconds >= _seekThrottleMs) {
                                                  audioHandler?.seek(Duration(milliseconds: _lastSeekMs!));
                                                  _lastSeekTime = DateTime.now();
                                                  _lastSeekMs = null;
                                                }
                                              });
                                            }
                                            _dragValueSeconds = null;
                                            setState(() {});
                                          },
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 24),
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              _formatDuration(Duration(milliseconds: sliderValueMs.toInt())),
                                              style: TextStyle(fontSize: is16by9 ? 18 : 15),
                                            ),
                                            Text(
                                              // Si la duración es desconocida, muestra '--:--'
                                              (mediaDuration == null || mediaDuration.inMilliseconds <= 0) ? '--:--' : _formatDuration(duration),
                                              style: TextStyle(fontSize: is16by9 ? 18 : 15),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                },
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
                        stream: audioHandler?.playbackState,
                        builder: (context, snapshot) {
                          final state = snapshot.data;
                          final isPlaying = state?.playing ?? false;
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
                              repeatColor = Theme.of(context).brightness == Brightness.light
                                              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9)
                                              : Theme.of(context).colorScheme.onSurface;
                          }

                          // Controla la animación según el estado
                          if (isPlaying) {
                            _playPauseController.forward();
                          } else {
                            _playPauseController.reverse();
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
                                      ValueListenableBuilder<bool>(
                                        valueListenable: (audioHandler as MyAudioHandler).isShuffleNotifier,
                                        builder: (context, isShuffle, _) {
                                          return ValueListenableBuilder<bool>(
                                            valueListenable: playLoadingNotifier,
                                            builder: (context, isLoading, _) {
                                              return IconButton(
                                                icon: const Icon(Icons.shuffle),
                                                color: isShuffle
                                                    ? Theme.of(context).colorScheme.primary
                                                    : Theme.of(context).brightness == Brightness.light
                                                        ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9)
                                                        : Theme.of(context).colorScheme.onSurface,
                                                iconSize: iconSize,
                                                onPressed: () async {
                                                  if (isLoading) return;
                                                  await (audioHandler as MyAudioHandler).toggleShuffle(!isShuffle);
                                                },
                                                tooltip: LocaleProvider.tr('shuffle'),
                                              );
                                            },
                                          );
                                        },
                                      ),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return IconButton(
                                            icon: const Icon(Icons.skip_previous),
                                            color: Theme.of(context).brightness == Brightness.light
                                                  ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9)
                                                  : Theme.of(context).colorScheme.onSurface,
                                            iconSize: sideIconSize,
                                            onPressed: () {
                                              if (isLoading) return;
                                              audioHandler?.skipToPrevious();
                                            },
                                          );
                                        },
                                      ),
                                      Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: iconSize / 4,
                                        ),
                                        child: Material(
                                          color: Theme.of(context).brightness == Brightness.light
                                              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9)
                                              : Theme.of(context).colorScheme.onSurface,
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
                                              if (playLoadingNotifier.value) return;
                                              isPlaying
                                                  ? audioHandler?.pause()
                                                  : audioHandler?.play();
                                            },
                                            child: SizedBox(
                                              width: mainIconSize,
                                              height: mainIconSize,
                                              child: Center(
                                                child: ValueListenableBuilder<bool>(
                                                  valueListenable: playLoadingNotifier,
                                                  builder: (context, isLoading, _) {
                                                    return isLoading
                                                        ? SizedBox(
                                                            width: playIconSize,
                                                            height: playIconSize,
                                                            child: CircularProgressIndicator(
                                                              strokeWidth: 5,
                                                              strokeCap: StrokeCap.round,
                                                              color: Theme.of(context).brightness == Brightness.light
                                                                  ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.9)
                                                                  : Theme.of(context).colorScheme.surface,
                                                            ),
                                                          )
                                                        : AnimatedIcon(
                                                            icon: AnimatedIcons.play_pause,
                                                            progress: _playPauseController,
                                                            size: playIconSize,
                                                            color: Theme.of(context).brightness == Brightness.light
                                                                ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.9)
                                                                : Theme.of(context).colorScheme.surface,
                                                          );
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return IconButton(
                                            icon: const Icon(Icons.skip_next),
                                            color: Theme.of(context).brightness == Brightness.light
                                                  ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9)
                                                  : Theme.of(context).colorScheme.onSurface,
                                            iconSize: sideIconSize,
                                            onPressed: () {
                                              if (isLoading) return;
                                              audioHandler?.skipToNext();  
                                            },
                                          );
                                        },
                                      ),
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return IconButton(
                                            icon: Icon(repeatIcon),
                                            color: repeatColor,
                                            iconSize: iconSize,
                                            onPressed: () {
                                              if (isLoading) return;
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
                                              audioHandler?.setRepeatMode(newMode);
                                            },
                                            tooltip: LocaleProvider.tr('repeat'),
                                          );
                                        },
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
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return AnimatedTapButton(
                                            onTap: isLoading ? () {} : () async {
                                              if (!mounted) {
                                                return;
                                              }

                                              final safeContext = context;
                                              await _showAddToPlaylistDialog(
                                                safeContext,
                                                currentMediaItem,
                                              );
                                            },
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
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
                                                color: Theme.of(context).colorScheme.onSurface,
                                                size: isSmall ? 20 : 24,
                                              ),
                                              SizedBox(width: isSmall ? 6 : 8),
                                              Text(
                                                LocaleProvider.tr('save'),
                                                style: TextStyle(
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: isSmall ? 14 : 16,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),

                                      // Botón Letra
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return AnimatedTapButton(
                                            onTap: isLoading ? () {} : () async {
                                              if (!_showLyrics) {
                                                setState(() {
                                                  _showLyrics = true;
                                                });
                                                await _loadLyrics(currentMediaItem);
                                              } else {
                                                setState(() {
                                                  _showLyrics = false;
                                                });
                                              }
                                            },
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
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
                                                color: Theme.of(context).colorScheme.onSurface,
                                                size: isSmall ? 20 : 24,
                                              ),
                                              SizedBox(width: isSmall ? 6 : 8),
                                              Text(
                                                LocaleProvider.tr('lyrics'),
                                                style: TextStyle(
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: isSmall ? 14 : 16,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),

                                      // Botón Compartir
                                      ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return AnimatedTapButton(
                                            onTap: isLoading ? () {} : () async {
                                              // Acción del botón
                                            },
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
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
                                                  currentMediaItem.extras?['data']
                                                      as String?;
                                              if (dataPath != null &&
                                                  dataPath.isNotEmpty) {
                                                await SharePlus.instance.share(
                                                  ShareParams(
                                                    text: currentMediaItem.title,
                                                    files: [XFile(dataPath)],
                                                  ),
                                                );
                                              }
                                            },
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.share,
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                  size: isSmall ? 18 : 22,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
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
          ),
        );
      },
    )
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
    final mediaItem = audioHandler?.mediaItem.valueOrNull;
    final playbackState = audioHandler?.playbackState.valueOrNull;
    final position = playbackState?.position ?? Duration.zero;
    final duration = mediaItem?.duration ?? Duration.zero;
    final remaining = duration > position ? duration - position : Duration.zero;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(LocaleProvider.tr('one_minute')),
            onTap: () => _setTimer(context, const Duration(minutes: 1)),
          ),
          ListTile(
            title: Text(LocaleProvider.tr('five_minutes')),
            onTap: () => _setTimer(context, const Duration(minutes: 5)),
          ),
          ListTile(
            title: Text(LocaleProvider.tr('fifteen_minutes')),
            onTap: () => _setTimer(context, const Duration(minutes: 15)),
          ),
          ListTile(
            title: Text(LocaleProvider.tr('thirty_minutes')),
            onTap: () => _setTimer(context, const Duration(minutes: 30)),
          ),
          ListTile(
            title: Text(LocaleProvider.tr('one_hour')),
            onTap: () => _setTimer(context, const Duration(minutes: 60)),
          ),
          ListTile(
            title: Text(LocaleProvider.tr('until_song_ends')),
            onTap: remaining > Duration.zero
                ? () => _setTimer(context, remaining)
                : null,
          ),
          const Divider(),
          ListTile(
            title: Text(LocaleProvider.tr('cancel_timer')),
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

class VerticalMarqueeLyrics extends StatefulWidget {
  final List<LyricLine> lyricLines;
  final int currentLyricIndex;
  final BuildContext context;
  final double artworkSize;

  const VerticalMarqueeLyrics({
    super.key,
    required this.lyricLines,
    required this.currentLyricIndex,
    required this.context,
    required this.artworkSize,
  });

  @override
  State<VerticalMarqueeLyrics> createState() => _VerticalMarqueeLyricsState();
}

class _VerticalMarqueeLyricsState extends State<VerticalMarqueeLyrics>
    with TickerProviderStateMixin {
  late final AutoScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = AutoScrollController();
    // Centrar la línea actual al iniciar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentLyric();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VerticalMarqueeLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentLyricIndex != oldWidget.currentLyricIndex) {
      _scrollToCurrentLyric();
    }
  }

  Future<void> _scrollToCurrentLyric() async {
    await _scrollController.scrollToIndex(
      widget.currentLyricIndex,
      preferPosition: AutoScrollPosition.middle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final idx = widget.currentLyricIndex;
    final lines = widget.lyricLines;
    return SizedBox(
      width: widget.artworkSize,
      height: widget.artworkSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.artworkSize * 0.06),
        child: ShaderMask(
          shaderCallback: (Rect bounds) {
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.white,
                Colors.white,
                Colors.transparent,
              ],
              stops: const [0.0, 0.1, 0.9, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: _scrollController,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(
              vertical: 0,
              horizontal: 10,
            ),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final isCurrent = index == idx;
              final textStyle = TextStyle(
                color: isCurrent
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white70,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                fontSize: isCurrent ? 18 : 15,
              );
              return AutoScrollTag(
                key: ValueKey(index),
                controller: _scrollController,
                index: index,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  alignment: Alignment.center,
                  child: Text(
                    lines[index].text,
                    textAlign: TextAlign.center,
                    style: textStyle,
                    maxLines: null,
                    softWrap: true,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlaylistListView extends StatefulWidget {
  final List<MediaItem> queue;
  final MediaItem? currentMediaItem;
  final int currentIndex;
  final double maxHeight;

  const _PlaylistListView({
    required this.queue,
    required this.currentMediaItem,
    required this.currentIndex,
    required this.maxHeight,
  });

  @override
  State<_PlaylistListView> createState() => _PlaylistListViewState();
}

class _PlaylistListViewState extends State<_PlaylistListView> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    // Calcular la posición inicial para centrar la canción actual
    final itemHeight = 72.0; // Altura aproximada de cada ListTile
    final headerHeight = 80.0; // Altura del encabezado
    final initialOffset = widget.currentIndex >= 0 
        ? headerHeight + (widget.currentIndex * itemHeight) - (widget.maxHeight / 2) + (itemHeight / 2)
        : 0.0;
    
    _scrollController = ScrollController(initialScrollOffset: initialOffset.clamp(0.0, double.infinity));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      itemCount: widget.queue.length + 1, // +1 para el encabezado
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
              Text(
                LocaleProvider.tr('playlist'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
            ],
          );
        }
        final item = widget.queue[index - 1];
        final isCurrent = item.id == widget.currentMediaItem?.id;
        final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
        final songId = item.extras?['songId'] ?? 0;
        final songPath = item.extras?['data'] ?? '';
        return ListTile(
          leading: ArtworkListTile(
            songId: songId,
            songPath: songPath,
            artUri: item.artUri,
            size: 48,
            borderRadius: BorderRadius.circular(8),
          ),
          title: Text(
            item.title,
            maxLines: 1,
            style: TextStyle(
              fontWeight: isCurrent
                  ? FontWeight.bold
                  : FontWeight.normal,
              color: isCurrent
                  ? (isAmoledTheme
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary)
                  : null,
            ),
          ),
          subtitle: Text(
            item.artist ?? LocaleProvider.tr('unknown_artist'),
            maxLines: 1,
          ),
          selected: isCurrent,
          selectedTileColor: isAmoledTheme
              ? Colors.white.withValues(alpha: 0.1)
              : Theme.of(context).colorScheme.primaryContainer,
          onTap: () {
            audioHandler?.skipToQueueItem(index - 1);
            // No cerramos el modal, así se mantiene abierto
          },
        );
      },
    );
  }
}

class ArtworkListTile extends StatefulWidget {
  final int songId;
  final String songPath;
  final Uri? artUri;
  final double size;
  final BorderRadius borderRadius;

  const ArtworkListTile({
    super.key,
    required this.songId,
    required this.songPath,
    required this.size,
    required this.borderRadius,
    this.artUri,
  });

  @override
  State<ArtworkListTile> createState() => _ArtworkListTileState();
}

class _ArtworkListTileState extends State<ArtworkListTile> {
  Uri? _artUri;

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  Future<void> _loadArtwork() async {
    // Si hay artUri remota, no busques local
    if (widget.artUri != null && (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      setState(() => _artUri = widget.artUri);
      return;
    }
    final uri = await getOrCacheArtwork(widget.songId, widget.songPath);
    if (mounted) setState(() => _artUri = uri);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.artUri != null && (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.network(
          widget.artUri.toString(),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: 400,
          cacheHeight: 400,
        ),
      );
    }
    if (_artUri != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.file(
          File(_artUri!.toFilePath()),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
        ),
      );
    } else {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: widget.borderRadius,
        ),
        child: Icon(Icons.music_note, size: widget.size * 0.5),
      );
    }
  }
}