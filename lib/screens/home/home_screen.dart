import 'package:flutter/material.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/encoding_utils.dart';
import 'package:music/main.dart'
    show audioHandler, getAudioServiceSafely, AudioHandlerSafeCast;
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:audio_service/audio_service.dart';
import 'package:music/screens/home/home_discovery_screen.dart';
import 'package:music/screens/home/ota_update_screen.dart';
import 'package:music/screens/home/settings_screen.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/artist_images_cache_db.dart';
import 'package:music/utils/db/artist_songs_cache_db.dart';
import 'package:music/utils/db/streaming_artists_db.dart';
import 'package:music/utils/db/download_history_hive.dart';
import 'package:music/utils/db/home_youtube_cache_db.dart';
import 'package:music/utils/yt_search/service.dart';
// import 'package:music/widgets/hero_cached.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/song_info_dialog.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:async';
import 'dart:io';
import 'package:music/widgets/refresh_m3e.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:share_plus/share_plus.dart';

enum OrdenCancionesPlaylist { normal, alfabetico, invertido, ultimoAgregado }

enum RecentSongsSource { local, streaming }

class _StreamingRecentItem {
  final String rawPath;
  final String title;
  final String artist;
  final String? videoId;
  final String? artUri;
  final String? durationText;
  final int? durationMs;
  final bool isPinned;

  const _StreamingRecentItem({
    required this.rawPath,
    required this.title,
    required this.artist,
    this.videoId,
    this.artUri,
    this.durationText,
    this.durationMs,
    this.isPinned = false,
  });
}

class _StreamingArtwork extends StatefulWidget {
  final List<String> sources;
  final Color backgroundColor;
  final Color iconColor;

  const _StreamingArtwork({
    required this.sources,
    required this.backgroundColor,
    required this.iconColor,
  });

  @override
  State<_StreamingArtwork> createState() => _StreamingArtworkState();
}

class _StreamingArtworkState extends State<_StreamingArtwork> {
  int _sourceIndex = 0;

  void _tryNextSource() {
    if (_sourceIndex >= widget.sources.length - 1) return;
    if (!mounted) return;
    setState(() {
      _sourceIndex++;
    });
  }

  Widget _buildFallback() {
    return Container(
      color: Colors.transparent,
      child: Icon(Icons.music_note_rounded, color: Colors.transparent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty || _sourceIndex >= widget.sources.length) {
      return _buildFallback();
    }

    final currentSource = widget.sources[_sourceIndex];
    final lower = currentSource.toLowerCase();

    if (lower.startsWith('file://') || currentSource.startsWith('/')) {
      final filePath = lower.startsWith('file://')
          ? (Uri.tryParse(currentSource)?.toFilePath() ?? '')
          : currentSource;
      if (filePath.isEmpty) {
        _tryNextSource();
        return _buildFallback();
      }

      return Image.file(
        File(filePath),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          _tryNextSource();
          return _buildFallback();
        },
      );
    }

    return CachedNetworkImage(
      imageUrl: currentSource,
      fit: BoxFit.cover,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => _buildFallback(),
      errorWidget: (context, url, error) {
        _tryNextSource();
        return _buildFallback();
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  final void Function(int)? onTabChange;
  final void Function(AppThemeMode)? setThemeMode;
  final void Function(AppColorScheme)? setColorScheme;
  const HomeScreen({
    super.key,
    this.onTabChange,
    this.setThemeMode,
    this.setColorScheme,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const int _quickAccessSlots = 18;
  List<SongModel> _recentSongs = [];
  List<_StreamingRecentItem> _streamingRecents = [];
  bool _showingRecents = false;
  bool _showingDiscovery = false;
  RecentSongsSource _recentSongsSource = RecentSongsSource.local;
  Future<void>? _recentsWarmLoad;
  bool _showingPlaylistSongs = false;
  List<SongModel> _playlistSongs = [];
  Map<String, dynamic>? _selectedPlaylist;
  double _lastBottomInset = 0.0;
  String? _updateVersion;
  String? _updateApkUrl;
  bool _updateChecked = false;

  // Estado de carga
  bool _isLoading = true;

  List<SongModel> _mostPlayed = [];
  final PageController _pageController = PageController(viewportFraction: 0.95);
  final PageController _quickPickPageController = PageController(
    viewportFraction: 0.90,
  );
  final ScrollController _homeScrollController = ScrollController();
  final ScrollController _recentsScrollController = ScrollController();
  final ScrollController _playlistSongsScrollController = ScrollController();
  final ScrollController _artistSongsScrollController = ScrollController();
  final ValueNotifier<double> _gradientAlphaNotifier = ValueNotifier(1.0);
  static const int _gradientThrottleMs = 80;
  int _lastGradientAlphaUpdateMs = 0;
  Timer? _gradientSyncTimer;
  // List<Map<String, dynamic>> _playlists = [];

  final TextEditingController _searchRecentsController =
      TextEditingController();
  final FocusNode _searchRecentsFocus = FocusNode();
  List<SongModel> _filteredRecents = [];
  List<_StreamingRecentItem> _filteredStreamingRecents = [];
  OrdenCancionesPlaylist _ordenCancionesPlaylist =
      OrdenCancionesPlaylist.normal;
  static const String _orderPrefsKey = 'home_screen_playlist_order_filter';
  static const String _recentsSourcePrefsKey = 'home_screen_recents_source';

  // Controladores y estados para búsqueda en playlist
  final TextEditingController _searchPlaylistController =
      TextEditingController();
  final FocusNode _searchPlaylistFocus = FocusNode();
  List<SongModel> _filteredPlaylistSongs = [];
  List<SongModel> _originalPlaylistSongs = [];
  final List<List<SongModel>> _quickPickPages = [];
  List<SongModel> allSongs = [];

  bool _isSelectingPlaylistSongs = false;
  final Set<int> _selectedPlaylistSongIds = {};

  List<SongModel> _shortcutSongs = [];
  List<_StreamingRecentItem> _streamingShortcutSongs = [];
  List<SongModel> _randomSongs =
      []; // Canciones aleatorias para llenar espacios vacíos
  List<SongModel> _shuffledQuickPick = [];
  List<_StreamingRecentItem> _shuffledStreamingRecentsQuickPick = [];
  List<_StreamingRecentItem> _quickPickYtFallbackSongs = [];
  List<_StreamingRecentItem> _sharedYtFallbackPool = [];
  Future<void>? _sharedYtFallbackLoading;
  bool _homeYtCacheLoaded = false;
  bool _randomSongsLoaded = false; // Bandera para evitar cargas duplicadas
  List<Map<String, dynamic>> _artists = []; // Lista de artistas populares

  // Cache para los widgets de accesos directos para evitar reconstrucciones
  final Map<String, Widget> _shortcutWidgetCache = {};
  final Map<String, Widget> _streamingShortcutWidgetCache = {};

  // Cache para los widgets de selección rápida para evitar reconstrucciones
  final Map<String, Widget> _quickPickWidgetCache = {};

  // Cache para los widgets de artistas para evitar reconstrucciones
  final Map<String, Widget> _artistWidgetCache = {};
  // final Map<String, Uint8List?> _artworkCache = {};

  /*
  Future<Uint8List?> _getCachedArtwork(int songId) async {
    final cacheKey = 'artwork_$songId';

    if (_artworkCache.containsKey(cacheKey)) {
      return _artworkCache[cacheKey];
    }

    try {
      final artwork = await OnAudioQuery().queryArtwork(
        songId,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 200,
      );

      _artworkCache[cacheKey] = artwork;
      return artwork;
    } catch (e) {
      _artworkCache[cacheKey] = null;
      return null;
    }
  }
  */

  /*
  Future<void> _handleAddToPlaylistSingle(
    BuildContext context,
    SongModel song,
  ) async {
    final playlists = (await PlaylistsDB().getAllPlaylists())
        .where((p) => _playlistMatchesTargetSource(p, forStreaming: false))
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      playlists,
    );
    final TextEditingController controller = TextEditingController();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = colorSchemeNotifier.value;
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isAmoled
            ? Colors.white.withAlpha(20)
            : isDark
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (playlists.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            LocaleProvider.tr('no_playlists_yet'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (playlists.isNotEmpty)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: playlists.length,
                          itemBuilder: (context, i) {
                            final pl = playlists[i];
                            final bool isFirst = i == 0;
                            final bool isLast = i == playlists.length - 1;
                            final bool isOnly = playlists.length == 1;

                            BorderRadius borderRadius;
                            if (isOnly) {
                              borderRadius = BorderRadius.circular(20);
                            } else if (isFirst) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                                bottomLeft: Radius.circular(4),
                                bottomRight: Radius.circular(4),
                              );
                            } else if (isLast) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(4),
                                topRight: Radius.circular(4),
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              );
                            } else {
                              borderRadius = BorderRadius.circular(4);
                            }

                            return Padding(
                              padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                              child: Card(
                                color: barColor,
                                margin: EdgeInsets.zero,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: borderRadius,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: _buildPlaylistArtworkGrid(
                                    pl,
                                    allSongs,
                                    streamingArtworkCache:
                                        playlistArtworkSourcesCache,
                                  ),
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  onTap: () async {
                                    await PlaylistsDB().addSongToPlaylist(
                                      pl.id,
                                      song,
                                    );
                                    playlistsShouldReload.value =
                                        !playlistsShouldReload.value;
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = controller.text.trim();
                          if (name.isNotEmpty) {
                            final id = await PlaylistsDB().createPlaylist(name);
                            await PlaylistsDB().addSongToPlaylist(id, song);
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                    ),
                    onSubmitted: (value) async {
                      final name = value.trim();
                      if (name.isNotEmpty) {
                        final id = await PlaylistsDB().createPlaylist(name);
                        await PlaylistsDB().addSongToPlaylist(id, song);
                        playlistsShouldReload.value =
                            !playlistsShouldReload.value;
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
  */

  Future<void> _handleAddStreamingToPlaylistSingle(
    BuildContext context,
    _StreamingRecentItem item,
  ) async {
    final playlists = (await PlaylistsDB().getAllPlaylists())
        .where((p) => _playlistMatchesTargetSource(p, forStreaming: true))
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      playlists,
    );
    final TextEditingController controller = TextEditingController();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final colorScheme = colorSchemeNotifier.value;
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final barColor = isAmoled
            ? Colors.white.withAlpha(20)
            : isDark
            ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant.withAlpha(100),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('save_to_playlist'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (playlists.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Icon(
                            Icons.playlist_add_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            LocaleProvider.tr('no_playlists_yet'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (playlists.isNotEmpty)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.4,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: playlists.length,
                          itemBuilder: (context, i) {
                            final pl = playlists[i];
                            final bool isFirst = i == 0;
                            final bool isLast = i == playlists.length - 1;
                            final bool isOnly = playlists.length == 1;

                            BorderRadius borderRadius;
                            if (isOnly) {
                              borderRadius = BorderRadius.circular(20);
                            } else if (isFirst) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                                bottomLeft: Radius.circular(4),
                                bottomRight: Radius.circular(4),
                              );
                            } else if (isLast) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(4),
                                topRight: Radius.circular(4),
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              );
                            } else {
                              borderRadius = BorderRadius.circular(4);
                            }

                            return Padding(
                              padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                              child: Card(
                                color: barColor,
                                margin: EdgeInsets.zero,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: borderRadius,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: _buildPlaylistArtworkGrid(
                                    pl,
                                    allSongs,
                                    streamingArtworkCache:
                                        playlistArtworkSourcesCache,
                                  ),
                                  title: Text(
                                    pl.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  onTap: () async {
                                    await PlaylistsDB().addSongPathToPlaylist(
                                      pl.id,
                                      item.rawPath,
                                      title: item.title,
                                      artist: item.artist,
                                      videoId: item.videoId,
                                      artUri: item.artUri,
                                      durationText: item.durationText,
                                      durationMs: item.durationMs,
                                    );
                                    playlistsShouldReload.value =
                                        !playlistsShouldReload.value;
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: false,
                    decoration: InputDecoration(
                      hintText: LocaleProvider.tr('new_playlist'),
                      prefixIcon: const Icon(Icons.playlist_add),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check_rounded),
                        onPressed: () async {
                          final name = controller.text.trim();
                          if (name.isNotEmpty) {
                            final id = await PlaylistsDB().createPlaylist(name);
                            await PlaylistsDB().addSongPathToPlaylist(
                              id,
                              item.rawPath,
                              title: item.title,
                              artist: item.artist,
                              videoId: item.videoId,
                              artUri: item.artUri,
                              durationText: item.durationText,
                              durationMs: item.durationMs,
                            );
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        },
                      ),
                      filled: true,
                      fillColor: barColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 16,
                      ),
                    ),
                    onSubmitted: (value) async {
                      final name = value.trim();
                      if (name.isNotEmpty) {
                        final id = await PlaylistsDB().createPlaylist(name);
                        await PlaylistsDB().addSongPathToPlaylist(
                          id,
                          item.rawPath,
                          title: item.title,
                          artist: item.artist,
                          videoId: item.videoId,
                          artUri: item.artUri,
                          durationText: item.durationText,
                          durationMs: item.durationMs,
                        );
                        playlistsShouldReload.value =
                            !playlistsShouldReload.value;
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addStreamingShortcutToQueue(_StreamingRecentItem item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;

    final title = item.title.trim().isNotEmpty
        ? item.title.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist.trim().isNotEmpty
        ? item.artist.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri = (item.artUri?.trim().isNotEmpty ?? false)
        ? item.artUri!.trim()
        : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

    await audioHandler?.customAction('addYtStreamToQueue', {
      'videoId': videoId,
      'title': title,
      'artist': artist,
      'artUri': artUri,
      if (item.durationMs != null && item.durationMs! > 0)
        'durationMs': item.durationMs,
      if (item.durationText != null && item.durationText!.trim().isNotEmpty)
        'durationText': item.durationText!.trim(),
    });
  }

  Future<void> _downloadStreamingShortcut(_StreamingRecentItem item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    await SimpleYtDownload.downloadVideoWithArtist(
      context,
      videoId,
      item.title,
      item.artist,
      thumbUrl: item.artUri,
    );
  }

  Future<void> _showStreamingShortcutOptions(_StreamingRecentItem item) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    final isPinned = await ShortcutsDB().isShortcut(item.rawPath);

    final title = item.title.trim().isNotEmpty
        ? item.title.trim()
        : LocaleProvider.tr('title_unknown');
    final artist = item.artist.trim().isNotEmpty
        ? item.artist.trim()
        : LocaleProvider.tr('artist_unknown');
    final artUri = (item.artUri?.trim().isNotEmpty ?? false)
        ? item.artUri!.trim()
        : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    final videoUrl = 'https://music.youtube.com/watch?v=$videoId';

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: _StreamingArtwork(
                          sources: _streamingArtworkSources(item),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          iconColor: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            artist,
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showStreamingSearchOptions(item);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                            ),
                            const SizedBox(width: 8),
                            TranslatedText(
                              'search',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const TranslatedText('add_to_queue'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _addStreamingShortcutToQueue(item);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.favorite_outline_rounded,
                  weight: 600,
                ),
                title: TranslatedText('add_to_favorites'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await FavoritesDB().addFavoritePath(
                    item.rawPath,
                    title: title,
                    artist: artist,
                    videoId: videoId,
                    artUri: artUri,
                    durationText: item.durationText,
                    durationMs: item.durationMs,
                  );
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: TranslatedText('add_to_playlist'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _handleAddStreamingToPlaylistSingle(context, item);
                },
              ),
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: TranslatedText(
                  isPinned ? 'unpin_shortcut' : 'pin_shortcut',
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  if (isPinned) {
                    await ShortcutsDB().removeShortcut(item.rawPath);
                  } else {
                    await ShortcutsDB().addShortcut(
                      item.rawPath,
                      title: title,
                      artist: artist,
                      videoId: videoId,
                      artUri: artUri,
                      durationText: item.durationText,
                      durationMs: item.durationMs,
                    );
                  }
                  shortcutsShouldReload.value = !shortcutsShouldReload.value;
                },
              ),
              if (artist.trim().isNotEmpty &&
                  artist.trim() != LocaleProvider.tr('artist_unknown'))
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const TranslatedText('go_to_artist'),
                  onTap: () {
                    Navigator.of(context).pop();
                    final name = artist.trim();
                    if (name.isEmpty) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            ArtistScreen(artistName: name),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              const begin = Offset(1.0, 0.0);
                              const end = Offset.zero;
                              const curve = Curves.ease;
                              final tween = Tween(
                                begin: begin,
                                end: end,
                              ).chain(CurveTween(curve: curve));
                              return SlideTransition(
                                position: animation.drive(tween),
                                child: child,
                              );
                            },
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: TranslatedText('download'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _downloadStreamingShortcut(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_rounded),
                title: TranslatedText('share_link'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await SharePlus.instance.share(ShareParams(text: videoUrl));
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: TranslatedText('song_info'),
                onTap: () async {
                  Navigator.of(context).pop();
                  final mediaItem = MediaItem(
                    id: item.rawPath,
                    title: title,
                    artist: artist,
                    artUri: Uri.tryParse(artUri),
                    extras: {
                      'data': item.rawPath,
                      'videoId': videoId,
                      'isStreaming': true,
                      'displayArtUri': artUri,
                    },
                  );
                  await SongInfoDialog.show(
                    context,
                    mediaItem,
                    colorSchemeNotifier,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

  static String? _pathFromMediaItem(MediaItem? item) =>
      item?.extras?['data'] ?? item?.id;

  /// Helper para obtener el AudioHandler de forma segura
  Future<MyAudioHandler?> _getAudioHandler() async {
    final handler = await getAudioServiceSafely();
    return handler.myHandler;
  }

  /*
  // Devuelve la lista de accesos directos para mostrar en quick_access
  List<SongModel> get _accessDirectSongs {
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toList();
    final randomPaths = _randomSongs.map((s) => s.data).toList();
    final allUsedPaths = {...shortcutPaths, ...randomPaths};

    // Mezclar las canciones recientes de forma aleatoria
    final shuffledRecents = List<SongModel>.from(_recentSongs)..shuffle();

    final List<SongModel> combined = [
      ..._shortcutSongs,
      ..._mostPlayed.where((s) => !allUsedPaths.contains(s.data)).take(18),
      ..._randomSongs,
      ...shuffledRecents.where(
        (s) =>
            !allUsedPaths.contains(s.data) &&
            !_mostPlayed.any((mp) => mp.data == s.data),
      ),
    ];
    return combined.take(100).toList();
  }
    */

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeData();
    playlistsShouldReload.addListener(_onPlaylistsShouldReload);
    favoritesShouldReload.addListener(_onFavoritesShouldReload);
    shortcutsShouldReload.addListener(_onShortcutsShouldReload);
    mostPlayedShouldReload.addListener(_onMostPlayedShouldReload);
    colorSchemeNotifier.addListener(_onThemeChanged);
    _homeScrollController.addListener(_onHomeScroll);
    _buscarActualizacion();

    // Inicializar con el valor actual si ya hay algo reproduciéndose
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }

    // Inicializar el estado de reproducción actual
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Escuchar cambios en el estado de reproducción con debounce
    // Solo actualizar si el valor realmente cambió para evitar rebuilds redundantes
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 100), () {
        if (mounted && _isPlayingNotifier.value != state.playing) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });

    // Un solo listener para MediaItem: evita rebuilds duplicados (antes 50ms + 400ms)
    // Solo actualizar si la ruta de la canción realmente cambió
    audioHandler?.mediaItem.listen((item) {
      final newPath = _pathFromMediaItem(item);
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 80), () {
        if (mounted &&
            _pathFromMediaItem(_currentMediaItemNotifier.value) != newPath) {
          _currentMediaItemNotifier.value = item;
        }
      });
    });
  }

  /// Inicializa todos los datos necesarios para la pantalla de inicio
  Future<void> _initializeData() async {
    try {
      await _loadHomeYoutubeCache();

      // Cargar filtros de orden
      await _loadOrderFilter();
      await _loadRecentsSourceFilter();

      // Cargar todas las canciones
      await _loadAllSongs();

      // Cargar canciones más reproducidas
      await _loadMostPlayed();

      // Cargar accesos directos
      await _loadShortcuts();

      // Cargar artistas
      await _loadArtists();

      // Cargar canciones recientes
      await _loadRecentsData();

      // Llenar selección rápida con canciones aleatorias
      await _fillQuickPickWithRandomSongs();

      // Inicializar páginas de selección rápida
      _initQuickPickPages();

      // Cargar playlists
      await _loadPlaylists();

      // Finalizar carga
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      // En caso de error, mostrar la pantalla de todas formas
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _onPlaylistsShouldReload() {
    _loadPlaylists();
    _loadMostPlayed();
  }

  void _onShortcutsShouldReload() {
    refreshShortcuts();
  }

  void _onMostPlayedShouldReload() {
    _loadMostPlayed();
  }

  void _onFavoritesShouldReload() {
    _loadMostPlayed();
  }

  void _onThemeChanged() {
    // Limpiar cachés de widgets cuando cambia el tema para forzar reconstrucción
    _artistWidgetCache.clear();
    _shortcutWidgetCache.clear();
    _streamingShortcutWidgetCache.clear();
    _quickPickWidgetCache.clear();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null &&
        savedIndex >= 0 &&
        savedIndex < OrdenCancionesPlaylist.values.length) {
      setState(() {
        _ordenCancionesPlaylist = OrdenCancionesPlaylist.values[savedIndex];
      });
    }
  }

  Future<void> _loadRecentsSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_recentsSourcePrefsKey);
    if (savedIndex != null &&
        savedIndex >= 0 &&
        savedIndex < RecentSongsSource.values.length) {
      setState(() {
        _recentSongsSource = RecentSongsSource.values[savedIndex];
      });
    }
  }

  Future<void> _saveRecentsSourceFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_recentsSourcePrefsKey, _recentSongsSource.index);
  }

  Future<void> _saveOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orderPrefsKey, _ordenCancionesPlaylist.index);
  }

  void _ordenarCancionesPlaylist() {
    setState(() {
      switch (_ordenCancionesPlaylist) {
        case OrdenCancionesPlaylist.normal:
          _playlistSongs = List.from(_originalPlaylistSongs);
          break;
        case OrdenCancionesPlaylist.alfabetico:
          _playlistSongs.sort((a, b) => a.title.compareTo(b.title));
          break;
        case OrdenCancionesPlaylist.invertido:
          _playlistSongs.sort((a, b) => b.title.compareTo(a.title));
          break;
        case OrdenCancionesPlaylist.ultimoAgregado:
          _playlistSongs = List.from(_originalPlaylistSongs.reversed);
          break;
      }
    });
    _saveOrderFilter();
  }

  Future<void> _loadPinnedSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final pinnedPaths = prefs.getStringList('pinned_songs') ?? [];
    List<SongModel> pinned = [];
    for (final path in pinnedPaths) {
      SongModel? song;
      try {
        song = allSongs.firstWhere((s) => s.data == path);
      } catch (_) {
        try {
          song = _mostPlayed.firstWhere((s) => s.data == path);
        } catch (_) {
          song = null;
        }
      }
      if (song != null) pinned.add(song);
    }
  }

  // Modificar _initQuickPickPages para usar _pinnedSongs y _mostPlayed
  void _initQuickPickPages() {
    _quickPickPages.clear();

    // print('🎵 Inicializando QuickPick - Accesos directos: ${_shortcutSongs.length}, Más escuchadas: ${_mostPlayed.length}, Aleatorias: ${_randomSongs.length}, AllSongs: ${allSongs.length}');

    // Inicializar la selección rápida mezclada
    _shuffleQuickPick();

    // Prioridad: 1) Accesos directos fijos, 2) Canciones más escuchadas, 3) Canciones aleatorias
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
    final randomPaths = _randomSongs.map((s) => s.data).toSet();
    final allUsedPaths = {...shortcutPaths, ...randomPaths};

    final List<SongModel> combined = [];

    // 1. Agregar accesos directos fijos
    for (final song in _shortcutSongs) {
      if (!allUsedPaths.contains(song.data)) {
        combined.add(song);
        allUsedPaths.add(song.data);
      }
    }
    // print('🎵 Después de accesos directos: ${combined.length} canciones');

    // 2. Agregar canciones más escuchadas que no estén ya en uso
    for (final song in _mostPlayed) {
      if (!allUsedPaths.contains(song.data) && combined.length < 18) {
        combined.add(song);
        allUsedPaths.add(song.data);
      }
    }
    // print('🎵 Después de más escuchadas: ${combined.length} canciones');

    // 3. Si aún no tenemos 18 canciones, llenar con canciones aleatorias de _shuffledQuickPick
    if (combined.length < 18) {
      for (final song in _shuffledQuickPick) {
        if (!allUsedPaths.contains(song.data) && combined.length < 18) {
          combined.add(song);
          allUsedPaths.add(song.data);
        }
      }
    }
    // print('🎵 Después de shuffledQuickPick: ${combined.length} canciones');

    // 4. Si aún no tenemos 18 canciones, llenar con canciones aleatorias de allSongs
    if (combined.length < 18 && allSongs.isNotEmpty) {
      final availableSongs = allSongs
          .where((s) => !allUsedPaths.contains(s.data))
          .toList();
      availableSongs.shuffle();

      final neededSongs = 18 - combined.length;
      combined.addAll(availableSongs.take(neededSongs));
      // print('🎵 Después de allSongs fallback: ${combined.length} canciones');
    }

    // Asegurar que tenemos exactamente 18 canciones o las que estén disponibles
    final limited = combined.take(18).toList();

    // Dividir la lista en páginas de 6
    for (int i = 0; i < 3; i++) {
      final start = i * 6;
      final end = (start + 6).clamp(0, limited.length);
      if (start < limited.length) {
        _quickPickPages.add(limited.sublist(start, end));
      }
    }
  }

  // Cuando se fije o desfije una canción, recargar accesos directos
  Future<void> refreshPinnedSongs() async {
    await _loadPinnedSongs();
    await _fillQuickPickWithRandomSongs(forceReload: true);
    _initQuickPickPages();
    setState(() {});
  }

  Future<void> _loadShortcuts() async {
    final shortcutPaths = await ShortcutsDB().getShortcuts();
    final localShortcutPaths = shortcutPaths
        .where((path) => !_isStreamingRecentPath(path))
        .toList();
    List<SongModel> shortcutSongs = [];

    // Asegurar que haya canciones disponibles para hacer el mapeo
    List<SongModel> songsSource = allSongs;
    if (songsSource.isEmpty) {
      try {
        // Usar SongsIndexDB para obtener solo canciones no ignoradas
        songsSource = await SongsIndexDB().getIndexedSongs();
        // Persistir también en el estado para futuras búsquedas
        if (mounted) {
          setState(() {
            allSongs = songsSource;
          });
        }
      } catch (_) {}
    }

    // Cargar accesos directos reales
    for (final path in localShortcutPaths) {
      try {
        final song = songsSource.firstWhere((s) => s.data == path);
        shortcutSongs.add(song);
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        // Invalida widgets cacheados para que reflejen el estado de fijado
        _shortcutWidgetCache.clear();
        _shortcutSongs = shortcutSongs;
      });
    }

    // Las canciones aleatorias se cargan solo una vez en initState
  }

  Future<void> _loadArtists({bool forceRefresh = false}) async {
    // Mantener parámetro para compatibilidad con llamadas de refresh existentes.
    final _ = forceRefresh;
    try {
      final artists = await StreamingArtistsDB().getTopArtists(limit: 20);

      if (mounted) {
        setState(() {
          _artists = artists;
        });
      }

      if (artists.isNotEmpty) {
        _enrichArtistsWithYTImages(List<Map<String, dynamic>>.from(artists));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _artists = [];
        });
      }
    }
  }

  // Función para enriquecer artistas con imágenes de YouTube Music usando cache persistente
  Future<void> _enrichArtistsWithYTImages(
    List<Map<String, dynamic>> artists,
  ) async {
    try {
      // print('🎵 Enriqueciendo ${artists.length} artistas con imágenes de YouTube Music...');

      // Primero, intentar cargar desde cache
      final artistNames = artists.map((a) => a['name'] as String).toList();
      final cachedImages = await ArtistImagesCacheDB.getCachedArtistImages(
        artistNames,
      );

      // print('📦 Imágenes encontradas en cache: ${cachedImages.length}');

      // Crear mapa de cache para búsqueda rápida
      final cacheMap = <String, Map<String, dynamic>>{};
      for (final cached in cachedImages) {
        cacheMap[cached['name']] = cached;
      }

      // Aplicar imágenes desde cache
      bool hasUpdates = false;
      for (int i = 0; i < artists.length; i++) {
        final artist = artists[i];
        final artistName = artist['name'];

        if (cacheMap.containsKey(artistName)) {
          final cached = cacheMap[artistName]!;
          // print('📦 Usando imagen desde cache para: $artistName');

          artists[i] = {
            ...artist,
            'thumbUrl': cached['thumbUrl'],
            'browseId': cached['browseId'],
            'subscribers': cached['subscribers'],
          };
          hasUpdates = true;
        }
      }

      // Actualizar UI con imágenes del cache
      if (hasUpdates && mounted) {
        setState(() {
          _artists = List.from(artists);
        });
        _artistWidgetCache.clear();
        // print('🔄 UI actualizada con imágenes del cache');
      }

      // Si no hay actualizaciones del cache, actualizar la UI de todos modos para mostrar los artistas
      if (!hasUpdates && mounted) {
        setState(() {
          _artists = List.from(artists);
        });
        _artistWidgetCache.clear();
        // print('🔄 UI actualizada sin imágenes del cache');
      }

      // Buscar imágenes faltantes en YouTube Music
      final artistsToSearch = <int>[];
      for (int i = 0; i < artists.length; i++) {
        if (!cacheMap.containsKey(artists[i]['name'])) {
          artistsToSearch.add(i);
        }
      }

      // print('🔍 Artistas a buscar en YouTube Music: ${artistsToSearch.length}');

      for (final i in artistsToSearch) {
        final artist = artists[i];
        final artistName = artist['name'];

        // print('🔍 Buscando imagen para: $artistName');

        try {
          // Buscar el artista en YouTube Music con timeout
          final ytArtists = await searchArtists(
            artistName,
            limit: 1,
          ).timeout(const Duration(seconds: 10));
          // print('🔍 Resultado de búsqueda para $artistName: ${ytArtists.length} artistas encontrados');

          if (ytArtists.isNotEmpty) {
            final ytArtist = ytArtists.first;
            // print('✅ Encontrado en YT: ${ytArtist['name']} - Thumb: ${ytArtist['thumbUrl'] != null ? 'Sí' : 'No'}');

            // Guardar en cache persistente
            await ArtistImagesCacheDB.cacheArtistImage(
              artistName: artistName,
              thumbUrl: ytArtist['thumbUrl'],
              browseId: ytArtist['browseId'],
              subscribers: ytArtist['subscribers'],
            );

            // Actualizar el artista con la información de YouTube Music
            artists[i] = {
              ...artist,
              'thumbUrl': ytArtist['thumbUrl'],
              'browseId': ytArtist['browseId'],
              'subscribers': ytArtist['subscribers'],
            };

            // Actualizar la UI inmediatamente cuando se encuentra una imagen
            if (mounted) {
              // print('🔄 Actualizando UI para ${artistName} con imagen: ${ytArtist['thumbUrl']}');
              setState(() {
                _artists = List.from(artists);
              });

              // Limpiar cache para forzar reconstrucción del widget
              _artistWidgetCache.clear();
              // print('🗑️ Cache de artistas limpiado');
            }
          } else {
            // print('❌ No se encontró en YouTube Music: $artistName');

            // Guardar en cache como "no encontrado" para evitar búsquedas repetidas
            await ArtistImagesCacheDB.cacheArtistImage(
              artistName: artistName,
              thumbUrl: null,
              browseId: null,
              subscribers: null,
            );
          }
        } on TimeoutException {
          // print('⏰ Timeout buscando $artistName en YouTube Music');
        } catch (e) {
          // print('❌ Error buscando $artistName en YouTube Music: $e');
        }

        // Pequeña pausa para evitar rate limiting
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Limpiar cache expirado
      final cleanedCount = await ArtistImagesCacheDB.cleanExpiredCache();
      if (cleanedCount > 0) {
        // print('🧹 Limpiados $cleanedCount elementos expirados del cache');
      }

      // print('🎵 Enriquecimiento completado');
    } catch (e) {
      // print('🎵 Error enriqueciendo artistas con imágenes de YT: $e');
      // Continuar sin las imágenes si hay error
    }
  }

  /// Fuerza la recarga de artistas (útil cuando se actualiza la biblioteca)
  /*Future<void> _reloadArtists() async {
    try {
      // print('🔄 Recargando artistas...');
      final artistsDB = ArtistsDB();
      
      // Forzar reindexación
      if (allSongs.isNotEmpty) {
        await artistsDB.forceReindex(allSongs);
      }
      
      final artists = await artistsDB.getTopArtists(limit: 20);
      // print('🔄 Artistas recargados: ${artists.length}');
      
      if (mounted) {
        // Limpiar cache de artistas para forzar reconstrucción
        _artistWidgetCache.clear();
        setState(() {
          _artists = artists;
        });
        
        // Enriquecer con imágenes en segundo plano
        if (artists.isNotEmpty) {
          _enrichArtistsWithYTImages(artists);
        }
      }
    } catch (e) {
      // print('❌ Error recargando artistas: $e');
      if (mounted) {
        setState(() {
          _artists = [];
        });
      }
    }
  }*/

  // Mostrar modal con canciones del artista
  /*
  Future<void> _showArtistSongsModal(
    BuildContext context,
    String artistName,
    List<SongModel> songs,
  ) async {
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    // Obtener información del artista desde el cache
    final artistInfo = await ArtistImagesCacheDB.getCachedArtistImage(
      artistName,
    );

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    child: ClipOval(
                      child: artistInfo?['thumbUrl'] != null
                          ? CachedNetworkImage(
                              imageUrl: artistInfo!['thumbUrl'] as String,
                              width: 60,
                              height: 60,
                              fit: BoxFit.cover,
                              errorWidget: (context, url, error) {
                                return Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                  ),
                                  child: Icon(
                                    Icons.person,
                                    size: 30,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                );
                              },
                              placeholder: (context, url) => Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Center(child: LoadingIndicator()),
                              ),
                            )
                          : QueryArtworkWidget(
                              id: songs.isNotEmpty ? songs.first.id : -1,
                              type: ArtworkType.AUDIO,
                              nullArtworkWidget: Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Icon(
                                  Icons.person,
                                  size: 30,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artistName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${songs.length} ${LocaleProvider.tr('songs')}',
                          style: TextStyle(
                            color: isAmoled
                                ? Colors.white.withValues(alpha: 0.85)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).pop(); // Cerrar el modal primero
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  ArtistScreen(
                                    artistName: artistName,
                                    browseId: artistInfo?['browseId'],
                                  ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                var tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 20,
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('go_to_artist'),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Songs list
            Expanded(
              child: StreamBuilder<MediaItem?>(
                stream: audioHandler?.mediaItem,
                initialData: audioHandler?.mediaItem.valueOrNull,
                builder: (context, snapshot) {
                  final currentMediaItem = snapshot.data;

                  return Theme(
                    data: Theme.of(context).copyWith(
                      scrollbarTheme: ScrollbarThemeData(
                        thumbColor: WidgetStateProperty.all(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    child: Scrollbar(
                      controller: _artistSongsScrollController,
                      thickness: 6.0,
                      radius: const Radius.circular(8),
                      interactive: true,
                      child: ListView.builder(
                        controller: _artistSongsScrollController,
                        padding: EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top: 8,
                          bottom: MediaQuery.of(context).padding.bottom,
                        ),
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          // Usar la misma lógica que _PlaylistListView para detectar la canción actual
                          final isCurrent =
                              currentMediaItem != null &&
                              currentMediaItem.extras?['data'] == song.data;
                          final isAmoledTheme =
                              colorSchemeNotifier.value ==
                              AppColorScheme.amoled;

                          final colorScheme = colorSchemeNotifier.value;
                          final isAmoled = colorScheme == AppColorScheme.amoled;
                          final isDark =
                              Theme.of(context).brightness == Brightness.dark;
                          final cardColor = isAmoled
                              ? Colors.white.withAlpha(20)
                              : isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.06)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.07);

                          // Calcular borderRadius según posición
                          final bool isFirst = index == 0;
                          final bool isLast = index == songs.length - 1;
                          final bool isOnly = songs.length == 1;

                          BorderRadius borderRadius;
                          if (isOnly) {
                            borderRadius = BorderRadius.circular(20);
                          } else if (isFirst) {
                            borderRadius = const BorderRadius.only(
                              topLeft: Radius.circular(20),
                              topRight: Radius.circular(20),
                              bottomLeft: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            );
                          } else if (isLast) {
                            borderRadius = const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(4),
                              bottomLeft: Radius.circular(20),
                              bottomRight: Radius.circular(20),
                            );
                          } else {
                            borderRadius = BorderRadius.circular(4);
                          }

                          return Padding(
                            padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                            child: Card(
                              color: isCurrent
                                  ? isAmoledTheme
                                        ? cardColor
                                        : Theme.of(
                                            context,
                                          ).colorScheme.primary.withAlpha(
                                            Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? 40
                                                : 25,
                                          )
                                  : cardColor,
                              margin: EdgeInsets.zero,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              child: ClipRRect(
                                borderRadius: borderRadius,
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 0,
                                  ),
                                  leading: FutureBuilder<Uint8List?>(
                                    future: _getCachedArtwork(song.id),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData &&
                                          snapshot.data != null) {
                                        return Container(
                                          width: 50,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            image: DecorationImage(
                                              image: MemoryImage(
                                                snapshot.data!,
                                              ),
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        );
                                      } else {
                                        return Container(
                                          width: 50,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.surfaceContainer,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.music_note,
                                            size: 25,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                  title: Row(
                                    children: [
                                      if (isCurrent)
                                        ValueListenableBuilder<bool>(
                                          valueListenable: _isPlayingNotifier,
                                          builder: (context, playing, child) {
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                right: 8.0,
                                              ),
                                              child: MiniMusicVisualizer(
                                                color: isAmoledTheme
                                                    ? Colors.white
                                                    : Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                                width: 4,
                                                height: 15,
                                                radius: 4,
                                                animate: playing,
                                              ),
                                            );
                                          },
                                        ),
                                      Expanded(
                                        child: Text(
                                          song.displayTitle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: isCurrent
                                              ? Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: isAmoledTheme
                                                          ? Colors.white
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .primary,
                                                    )
                                              : Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    song.displayArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isCurrent
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : isAmoledTheme
                                          ? Colors.white.withValues(alpha: 0.8)
                                          : null,
                                    ),
                                  ),
                                  tileColor: Colors.transparent,
                                  splashColor: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  onTap: () async {
                                    await _playSongAndOpenPlayer(
                                      song,
                                      songs,
                                      queueSource:
                                          '${LocaleProvider.tr('artist')}: $artistName',
                                    );
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
  */

  List<_StreamingRecentItem> _buildStreamingArtistItemsFromMeta(
    String artistName,
    List<Map<String, dynamic>> songsMeta,
  ) {
    final items = <_StreamingRecentItem>[];
    for (final meta in songsMeta) {
      final rawPath = meta['path']?.toString().trim() ?? '';
      final rawVideoId = meta['videoId']?.toString().trim();
      final videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
          ? rawVideoId
          : _extractVideoIdFromPath(rawPath);
      if (videoId == null || videoId.isEmpty) continue;

      final title = meta['title']?.toString().trim();
      final artist = meta['artist']?.toString().trim();
      final durationText = meta['durationText']?.toString().trim();
      final durationMs = _parseDurationMs(meta['durationMs']);
      final artUri = _applyStreamingArtworkQuality(
        meta['artUri']?.toString().trim(),
        videoId: videoId,
      );

      items.add(
        _StreamingRecentItem(
          rawPath: rawPath.isNotEmpty ? rawPath : 'yt:$videoId',
          title: (title != null && title.isNotEmpty)
              ? title
              : LocaleProvider.tr('title_unknown'),
          artist: (artist != null && artist.isNotEmpty) ? artist : artistName,
          videoId: videoId,
          artUri: artUri,
          durationText: (durationText != null && durationText.isNotEmpty)
              ? durationText
              : null,
          durationMs: durationMs,
        ),
      );
    }
    return items;
  }

  List<_StreamingRecentItem> _buildStreamingArtistItemsFromYt(
    String artistName,
    List<YtMusicResult> songs,
  ) {
    final items = <_StreamingRecentItem>[];
    final usedVideoIds = <String>{};

    for (final song in songs) {
      final videoId = song.videoId?.trim();
      if (videoId == null || videoId.isEmpty) continue;
      if (!usedVideoIds.add(videoId)) continue;

      final title = song.title?.trim();
      final artist = song.artist?.trim();
      final artUri = _applyStreamingArtworkQuality(
        song.thumbUrl,
        videoId: videoId,
      );
      final durationText = song.durationText?.trim();
      final durationMs = song.durationMs;

      items.add(
        _StreamingRecentItem(
          rawPath: 'yt:$videoId',
          title: (title != null && title.isNotEmpty)
              ? title
              : LocaleProvider.tr('title_unknown'),
          artist: (artist != null && artist.isNotEmpty) ? artist : artistName,
          videoId: videoId,
          artUri: artUri,
          durationText: (durationText != null && durationText.isNotEmpty)
              ? durationText
              : null,
          durationMs: durationMs,
        ),
      );
    }

    return items;
  }

  Future<List<_StreamingRecentItem>> _loadArtistCatalogSongsForModal({
    required String artistName,
    String? browseId,
    int limit = 40,
  }) async {
    final cachedSongsMeta = await ArtistSongsCacheDB().getArtistSongs(
      artistName,
      browseId: browseId,
    );
    if (cachedSongsMeta.isNotEmpty) {
      return _buildStreamingArtistItemsFromMeta(artistName, cachedSongsMeta);
    }

    String? resolvedBrowseId = browseId?.trim();
    if (resolvedBrowseId == null || resolvedBrowseId.isEmpty) {
      final search = await searchArtists(artistName, limit: 1);
      if (search.isNotEmpty) {
        resolvedBrowseId = search.first['browseId']?.toString().trim();
      }
    }

    if (resolvedBrowseId == null || resolvedBrowseId.isEmpty) {
      return const [];
    }

    final songsData = await getArtistSongs(
      resolvedBrowseId,
      initialLimit: limit,
    );
    final rawResults = songsData['results'];
    if (rawResults is! List) return const [];
    final ytSongs = rawResults.whereType<YtMusicResult>().toList();
    final songs = _buildStreamingArtistItemsFromYt(artistName, ytSongs);

    if (songs.isNotEmpty) {
      await ArtistSongsCacheDB().cacheArtistSongs(
        artistName: artistName,
        browseId: resolvedBrowseId,
        songsMeta: songs
            .map(
              (song) => <String, dynamic>{
                'path': song.rawPath,
                'title': song.title,
                'artist': song.artist,
                if (song.videoId != null && song.videoId!.isNotEmpty)
                  'videoId': song.videoId,
                if (song.artUri != null && song.artUri!.isNotEmpty)
                  'artUri': song.artUri,
                if (song.durationText != null && song.durationText!.isNotEmpty)
                  'durationText': song.durationText,
                if (song.durationMs != null && song.durationMs! > 0)
                  'durationMs': song.durationMs,
              },
            )
            .toList(),
      );
    }

    return songs;
  }

  Future<void> _openArtistSongsModalWithDeferredLoad(
    BuildContext context, {
    required String artistName,
    String? browseId,
  }) async {
    if (!context.mounted) return;
    final songsFuture = _loadArtistCatalogSongsForModal(
      artistName: artistName,
      browseId: browseId,
      limit: 40,
    );
    final artistInfoFuture = ArtistImagesCacheDB.getCachedArtistImage(
      artistName,
    );

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  FutureBuilder<Map<String, dynamic>?>(
                    future: artistInfoFuture,
                    builder: (context, snapshot) {
                      final artistInfo = snapshot.data;
                      return Container(
                        width: 60,
                        height: 60,
                        decoration: const BoxDecoration(shape: BoxShape.circle),
                        child: ClipOval(
                          child: artistInfo?['thumbUrl'] != null
                              ? CachedNetworkImage(
                                  imageUrl: artistInfo!['thumbUrl'] as String,
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.1),
                                        ),
                                        child: Icon(
                                          Icons.person,
                                          size: 30,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                  placeholder: (context, url) => Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.1),
                                    ),
                                    child: Center(child: LoadingIndicator()),
                                  ),
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                  ),
                                  child: Icon(
                                    Icons.person,
                                    size: 30,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artistName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FutureBuilder<Map<String, dynamic>?>(
                    future: artistInfoFuture,
                    builder: (context, snapshot) {
                      final artistInfo = snapshot.data;
                      return InkWell(
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            PageRouteBuilder(
                              pageBuilder:
                                  (context, animation, secondaryAnimation) =>
                                      ArtistScreen(
                                        artistName: artistName,
                                        browseId: artistInfo?['browseId']
                                            ?.toString()
                                            .trim(),
                                      ),
                              transitionsBuilder:
                                  (
                                    context,
                                    animation,
                                    secondaryAnimation,
                                    child,
                                  ) {
                                    const begin = Offset(1.0, 0.0);
                                    const end = Offset.zero;
                                    const curve = Curves.ease;
                                    final tween = Tween(
                                      begin: begin,
                                      end: end,
                                    ).chain(CurveTween(curve: curve));
                                    return SlideTransition(
                                      position: animation.drive(tween),
                                      child: child,
                                    );
                                  },
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer
                                      .withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 20,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                LocaleProvider.tr('go_to_artist'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<_StreamingRecentItem>>(
                future: songsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return Center(child: LoadingIndicator());
                  }

                  final songs = snapshot.data ?? const <_StreamingRecentItem>[];
                  if (songs.isEmpty) {
                    return Center(
                      child: Text(
                        LocaleProvider.tr('no_songs'),
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _artistSongsScrollController,
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 8,
                      bottom: MediaQuery.of(context).padding.bottom,
                    ),
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      final item = songs[index];
                      final colorScheme = colorSchemeNotifier.value;
                      final isAmoledTheme =
                          colorScheme == AppColorScheme.amoled;
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final cardColor = isAmoledTheme
                          ? Colors.white.withAlpha(20)
                          : isDark
                          ? Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06)
                          : Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.07);

                      final bool isFirst = index == 0;
                      final bool isLast = index == songs.length - 1;
                      final bool isOnly = songs.length == 1;
                      BorderRadius borderRadius;
                      if (isOnly) {
                        borderRadius = BorderRadius.circular(20);
                      } else if (isFirst) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        );
                      } else if (isLast) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20),
                        );
                      } else {
                        borderRadius = BorderRadius.circular(4);
                      }

                      return ValueListenableBuilder<MediaItem?>(
                        valueListenable: _currentMediaItemNotifier,
                        builder: (context, currentMediaItem, child) {
                          final itemVideoId = item.videoId?.trim();
                          final currentVideoId = currentMediaItem
                              ?.extras?['videoId']
                              ?.toString()
                              .trim();
                          final isCurrent =
                              (itemVideoId != null &&
                                  itemVideoId.isNotEmpty &&
                                  currentVideoId == itemVideoId) ||
                              currentMediaItem?.id == item.rawPath ||
                              (itemVideoId != null &&
                                  currentMediaItem?.id == 'yt:$itemVideoId');

                          Widget listTileWidget;
                          if (isCurrent) {
                            listTileWidget = ValueListenableBuilder<bool>(
                              valueListenable: _isPlayingNotifier,
                              builder: (context, playing, child) {
                                return ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 50,
                                      height: 50,
                                      child: _StreamingArtwork(
                                        sources: _streamingArtworkSources(item),
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHigh,
                                        iconColor: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  title: Row(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8.0,
                                        ),
                                        child: MiniMusicVisualizer(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          width: 4,
                                          height: 15,
                                          radius: 4,
                                          animate: playing,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          item.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isAmoledTheme
                                                    ? Colors.white
                                                    : Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  subtitle: Text(
                                    _formatStreamingArtistWithDuration(item),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: isAmoledTheme
                                        ? TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: 0.8,
                                            ),
                                          )
                                        : null,
                                  ),
                                  trailing: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary.withAlpha(20),
                                      shape: BoxShape.circle,
                                    ),
                                    child: IconButton(
                                      icon: Icon(
                                        playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        grade: 200,
                                        fill: 1,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                      onPressed: () {
                                        playing
                                            ? audioHandler.myHandler?.pause()
                                            : audioHandler.myHandler?.play();
                                      },
                                    ),
                                  ),
                                  selected: true,
                                  selectedTileColor: Colors.transparent,
                                  onTap: () async {
                                    if (playing) {
                                      await audioHandler.myHandler?.pause();
                                    } else {
                                      await audioHandler.myHandler?.play();
                                    }
                                  },
                                );
                              },
                            );
                          } else {
                            listTileWidget = ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: _StreamingArtwork(
                                    sources: _streamingArtworkSources(item),
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHigh,
                                    iconColor: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              title: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              subtitle: Text(
                                _formatStreamingArtistWithDuration(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: isAmoledTheme
                                    ? TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.8,
                                        ),
                                      )
                                    : null,
                              ),
                              trailing: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withAlpha(20),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    grade: 200,
                                    fill: 1,
                                  ),
                                  onPressed: () async {
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                    if (!mounted) return;
                                    await Future.delayed(
                                      const Duration(milliseconds: 300),
                                    );
                                    await _playStreamingEntry(
                                      item: item,
                                      sourceItems: songs,
                                      queueSource:
                                          '${LocaleProvider.tr('artist')}: $artistName',
                                    );
                                  },
                                ),
                              ),
                              selected: false,
                              selectedTileColor: Colors.transparent,
                              onTap: () async {
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                                if (!mounted) return;
                                await Future.delayed(
                                  const Duration(milliseconds: 300),
                                );
                                await _playStreamingEntry(
                                  item: item,
                                  sourceItems: songs,
                                  queueSource:
                                      '${LocaleProvider.tr('artist')}: $artistName',
                                );
                              },
                            );
                          }

                          return Padding(
                            padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                            child: Card(
                              color: isCurrent
                                  ? isAmoledTheme
                                        ? cardColor
                                        : Theme.of(context).colorScheme.primary
                                              .withAlpha(isDark ? 40 : 25)
                                  : cardColor,
                              margin: EdgeInsets.zero,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              child: listTileWidget,
                            ),
                          );
                        },
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
  }

  /*
  Future<void> _showStreamingArtistSongsModal(
    BuildContext context,
    String artistName,
    List<_StreamingRecentItem> songs,
  ) async {
    final artistInfo = await ArtistImagesCacheDB.getCachedArtistImage(
      artistName,
    );

    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(shape: BoxShape.circle),
                    child: ClipOval(
                      child: artistInfo?['thumbUrl'] != null
                          ? CachedNetworkImage(
                              imageUrl: artistInfo!['thumbUrl'] as String,
                              width: 60,
                              height: 60,
                              fit: BoxFit.cover,
                              errorWidget: (context, url, error) => Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Icon(
                                  Icons.person,
                                  size: 30,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              placeholder: (context, url) => Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                ),
                                child: Center(child: LoadingIndicator()),
                              ),
                            )
                          : Container(
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                              ),
                              child: Icon(
                                Icons.person,
                                size: 30,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artistName,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  ArtistScreen(
                                    artistName: artistName,
                                    browseId: artistInfo?['browseId'],
                                  ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                final tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 20,
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('go_to_artist'),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _artistSongsScrollController,
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 8,
                  bottom: MediaQuery.of(context).padding.bottom,
                ),
                itemCount: songs.length,
                itemBuilder: (context, index) {
                  final item = songs[index];
                  final itemVideoId = item.videoId?.trim();
                  final currentMediaItem = _currentMediaItemNotifier.value;
                  final currentVideoId = currentMediaItem?.extras?['videoId']
                      ?.toString()
                      .trim();
                  final isCurrent =
                      (itemVideoId != null &&
                          itemVideoId.isNotEmpty &&
                          currentVideoId == itemVideoId) ||
                      currentMediaItem?.id == item.rawPath ||
                      (itemVideoId != null &&
                          currentMediaItem?.id == 'yt:$itemVideoId');

                  final colorScheme = colorSchemeNotifier.value;
                  final isAmoledTheme = colorScheme == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final cardColor = isAmoledTheme
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07);

                  final bool isFirst = index == 0;
                  final bool isLast = index == songs.length - 1;
                  final bool isOnly = songs.length == 1;
                  BorderRadius borderRadius;
                  if (isOnly) {
                    borderRadius = BorderRadius.circular(20);
                  } else if (isFirst) {
                    borderRadius = const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    );
                  } else if (isLast) {
                    borderRadius = const BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    );
                  } else {
                    borderRadius = BorderRadius.circular(4);
                  }

                  return Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                    child: Card(
                      color: isCurrent
                          ? isAmoledTheme
                                ? cardColor
                                : Theme.of(context).colorScheme.primary
                                      .withAlpha(isDark ? 40 : 25)
                          : cardColor,
                      margin: EdgeInsets.zero,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: borderRadius),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: borderRadius,
                        ),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 50,
                            height: 50,
                            child: _StreamingArtwork(
                              sources: _streamingArtworkSources(item),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              iconColor: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? Theme.of(
                                  context,
                                ).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: isAmoledTheme
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.primary,
                                )
                              : Theme.of(context).textTheme.titleMedium,
                        ),
                        subtitle: Text(
                          _formatStreamingArtistWithDuration(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isAmoledTheme
                              ? TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                )
                              : null,
                        ),
                        onTap: () async {
                          if (context.mounted) {
                            Navigator.of(context).pop();
                          }
                          if (!mounted) return;
                          await _playStreamingEntry(
                            item: item,
                            sourceItems: songs,
                            queueSource:
                                '${LocaleProvider.tr('artist')}: $artistName',
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
  */

  // Widget para mostrar un artista en círculo
  Widget _buildArtistWidget(Map<String, dynamic> artist, BuildContext context) {
    return AnimatedTapButton(
      onTap: () async {
        HapticFeedback.mediumImpact();
        if (!context.mounted) return;
        final artistName = artist['name']?.toString().trim() ?? '';
        if (artistName.isEmpty) return;
        final browseId = artist['browseId']?.toString().trim();
        await _openArtistSongsModalWithDeferredLoad(
          context,
          artistName: artistName,
          browseId: browseId,
        );
      },
      onLongPress: null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: artist['thumbUrl'] != null
                  ? CachedNetworkImage(
                      imageUrl: artist['thumbUrl'] as String,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) {
                        return Container(
                          decoration: BoxDecoration(
                            color:
                                colorSchemeNotifier.value ==
                                    AppColorScheme.amoled
                                ? Colors.white.withValues(alpha: 0.1)
                                : Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer
                                      .withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(child: Icon(Icons.person, size: 40)),
                        );
                      },
                      placeholder: (context, url) => Container(
                        decoration: BoxDecoration(
                          color:
                              colorSchemeNotifier.value == AppColorScheme.amoled
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(context).colorScheme.secondaryContainer
                                    .withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color:
                            colorSchemeNotifier.value == AppColorScheme.amoled
                            ? Colors.white.withValues(alpha: 0.1)
                            : Theme.of(context).colorScheme.secondaryContainer
                                  .withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: Icon(Icons.person, size: 40)),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 80,
            child: ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
                return Text(
                  artist['name'],
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                    color: colorScheme == AppColorScheme.amoled
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> refreshShortcuts() async {
    await _loadShortcuts();
    await _loadMostPlayed();
    await _fillQuickPickWithRandomSongs(forceReload: true);
    _initQuickPickPages();
    // Limpiar cache cuando se actualizan los shortcuts
    _shortcutWidgetCache.clear();
    _streamingShortcutWidgetCache.clear();
    _quickPickWidgetCache.clear();
    _artistWidgetCache.clear();
    setState(() {});
  }

  // Método optimizado para construir widgets de accesos directos: cachea solo la parte visual, handlers frescos
  Widget _buildStreamingShortcutWidget(
    _StreamingRecentItem item,
    BuildContext context,
  ) {
    final id = item.videoId?.trim() ?? item.rawPath;
    final String shortcutKey = 'streaming_shortcut_${id}_${item.isPinned}';

    Widget cachedVisual;
    if (_streamingShortcutWidgetCache.containsKey(shortcutKey)) {
      cachedVisual = _streamingShortcutWidgetCache[shortcutKey]!;
    } else {
      final artworkSources = _streamingArtworkSources(item);
      cachedVisual = RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                _StreamingArtwork(
                  sources: artworkSources,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer,
                  iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                if (item.isPinned)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: const Icon(
                        Icons.push_pin,
                        color: Colors.white,
                        size: 14,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(140),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        shadows: const [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black54,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      _streamingShortcutWidgetCache[shortcutKey] = cachedVisual;
    }

    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _currentMediaItemNotifier,
      builder: (context, currentMediaItem, child) {
        final itemVideoId = item.videoId?.trim();
        final currentVideoId = currentMediaItem?.extras?['videoId']
            ?.toString()
            .trim();
        final isCurrent =
            (itemVideoId != null &&
                itemVideoId.isNotEmpty &&
                currentVideoId == itemVideoId) ||
            currentMediaItem?.id == item.rawPath ||
            (itemVideoId != null && currentMediaItem?.id == 'yt:$itemVideoId');

        return ValueListenableBuilder<bool>(
          valueListenable: _isPlayingNotifier,
          builder: (context, playing, child) {
            return _buildOptimizedStreamingShortcutTile(
              item: item,
              context: context,
              cachedVisual: cachedVisual,
              isCurrent: isCurrent,
              playing: isCurrent ? playing : false,
            );
          },
        );
      },
    );
  }

  Widget _buildOptimizedStreamingShortcutTile({
    required _StreamingRecentItem item,
    required BuildContext context,
    required Widget cachedVisual,
    required bool isCurrent,
    required bool playing,
  }) {
    Widget finalVisual = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: Container(
        key: ValueKey('${item.rawPath}_$isCurrent'),
        child: Stack(
          children: [
            cachedVisual,
            if (isCurrent)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: MiniMusicVisualizer(
                    color: Colors.white,
                    width: 3,
                    height: 12,
                    radius: 3,
                    animate: playing,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    final childWidget = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        border: Border.all(
          color: isCurrent
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 3,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: finalVisual,
    );

    return AnimatedTapButton(
      onTap: () => _playStreamingShortcut(item),
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        await _showStreamingShortcutOptions(item);
      },
      child: childWidget,
    );
  }

  // Método optimizado para construir widgets de accesos directos: cachea solo la parte visual, handlers frescos
  /*
  Widget _buildShortcutWidget(SongModel song, BuildContext context) {
    final String shortcutKey = 'shortcut_${song.id}_${song.data}';

    // Cachear solo el contenido visual pesado (carátula base, pin, título)
    Widget cachedVisual;
    if (_shortcutWidgetCache.containsKey(shortcutKey)) {
      cachedVisual = _shortcutWidgetCache[shortcutKey]!;
    } else {
      cachedVisual = RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                ArtworkListTile(
                  key: ValueKey('shortcut_art_${song.data}'),
                  songId: song.id,
                  songPath: song.data,
                  width: double.infinity,
                  height: double.infinity,
                  borderRadius: BorderRadius.circular(12),
                ),
                if (_shortcutSongs.any((s) => s.data == song.data))
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(4),
                      child: const Icon(
                        Icons.push_pin,
                        color: Colors.white,
                        size: 14,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withAlpha(140),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Text(
                      song.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        shadows: [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black54,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      _shortcutWidgetCache[shortcutKey] = cachedVisual;
    }

    // Detectar si esta canción es la actual
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _currentMediaItemNotifier,
      builder: (context, currentMediaItem, child) {
        final path = song.data;
        final isCurrent =
            (currentMediaItem?.id != null &&
            path.isNotEmpty &&
            (currentMediaItem!.id == path ||
                currentMediaItem.extras?['data'] == path));

        // Solo usar ValueListenableBuilder para play si es la canción actual
        return ValueListenableBuilder<bool>(
          valueListenable: _isPlayingNotifier,
          builder: (context, playing, child) {
            return _buildOptimizedShortcutTile(
              song: song,
              context: context,
              cachedVisual: cachedVisual,
              isCurrent: isCurrent,
              playing: isCurrent ? playing : false,
            );
          },
        );
      },
    );
  }
  */

  /*
  Widget _buildOptimizedShortcutTile({
    required SongModel song,
    required BuildContext context,
    required Widget cachedVisual,
    required bool isCurrent,
    required bool playing,
  }) {
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    // Usar AnimatedSwitcher para transición suave de la carátula
    Widget finalVisual = AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: Container(
        key: ValueKey(
          '${song.id}_$isCurrent',
        ), // Key única para trigger del AnimatedSwitcher
        child: Stack(
          children: [
            cachedVisual,
            // MiniMusicVisualizer en esquina superior izquierda si es la canción actual
            if (isCurrent)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: MiniMusicVisualizer(
                    color: Colors.white,
                    width: 3,
                    height: 12,
                    radius: 3,
                    animate: playing,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // Usar AnimatedContainer para transición suave del borde
    Widget childWidget = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        border: Border.all(
          color: isCurrent
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 3,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: finalVisual,
    );

    final widget = AnimatedTapButton(
      onTap: () async {
        // Precargar la carátula antes de reproducir
        unawaited(_preloadArtworkForSong(song));
        if (!mounted) return;
        await _playSongAndOpenPlayer(
          song,
          _accessDirectSongs,
          queueSource: LocaleProvider.tr('quick_access_songs'),
        );
      },
      onLongPress: () async {
        HapticFeedback.mediumImpact();
        if (!context.mounted) return;
        final isFavorite = await FavoritesDB().isFavorite(song.data);
        if (!context.mounted) return;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Encabezado con información de la canción
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        // Carátula de la canción
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 60,
                            height: 60,
                            child: _buildModalArtwork(song),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Título y artista
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                song.displayTitle,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.titleMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                song.displayArtist,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isAmoled
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Botón de búsqueda para abrir opciones
                        InkWell(
                          onTap: () async {
                            Navigator.of(context).pop();
                            await _showSearchOptions(song);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer
                                        .withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.search,
                                  size: 20,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainer,
                                ),
                                const SizedBox(width: 8),
                                TranslatedText(
                                  'search',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color:
                                        Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music),
                    title: TranslatedText('add_to_queue'),
                    onTap: () async {
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      await audioHandler.myHandler?.addSongsToQueueEnd([song]);
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      isFavorite
                          ? Icons.delete_outline
                          : Icons.favorite_outline_rounded,
                      weight: isFavorite ? null : 600,
                    ),
                    title: TranslatedText(
                      isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
                    ),
                    onTap: () async {
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      if (isFavorite) {
                        await FavoritesDB().removeFavorite(song.data);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
                      } else {
                        await FavoritesDB().addFavorite(song);
                        favoritesShouldReload.value =
                            !favoritesShouldReload.value;
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: TranslatedText('add_to_playlist'),
                    onTap: () async {
                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                      await _handleAddToPlaylistSingle(context, song);
                    },
                  ),
                  if (song.displayArtist.trim().isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const TranslatedText('go_to_artist'),
                      onTap: () {
                        if (!context.mounted) return;
                        Navigator.of(context).pop();
                        final name = song.displayArtist.trim();
                        if (name.isEmpty) return;
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            pageBuilder:
                                (context, animation, secondaryAnimation) =>
                                    ArtistScreen(artistName: name),
                            transitionsBuilder:
                                (
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                ) {
                                  const begin = Offset(1.0, 0.0);
                                  const end = Offset.zero;
                                  const curve = Curves.ease;
                                  final tween = Tween(
                                    begin: begin,
                                    end: end,
                                  ).chain(CurveTween(curve: curve));
                                  return SlideTransition(
                                    position: animation.drive(tween),
                                    child: child,
                                  );
                                },
                          ),
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: TranslatedText('song_info'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await SongInfoDialog.showFromSong(
                        context,
                        song,
                        colorSchemeNotifier,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
      child: childWidget,
    );

    return widget;
  }
  */

  // Método optimizado para selección rápida: cachea solo el leading (carátula), handlers frescos
  Widget _buildQuickPickWidget(
    _StreamingRecentItem song,
    BuildContext context,
    List<_StreamingRecentItem> pageSongs,
  ) {
    final songKey = (song.videoId?.trim().isNotEmpty ?? false)
        ? 'yt:${song.videoId!.trim()}'
        : song.rawPath;
    final String quickPickKey = 'quickpick_leading_$songKey';
    Widget leading;
    if (_quickPickWidgetCache.containsKey(quickPickKey)) {
      leading = _quickPickWidgetCache[quickPickKey]!;
    } else {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 57,
          height: 60,
          child: _StreamingArtwork(
            sources: _streamingArtworkSources(song),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
      _quickPickWidgetCache[quickPickKey] = leading;
    }

    // Detectar si esta canción es la actual
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _currentMediaItemNotifier,
      builder: (context, currentMediaItem, child) {
        final itemVideoId = song.videoId?.trim();
        final currentVideoId = currentMediaItem?.extras?['videoId']
            ?.toString()
            .trim();
        final isCurrent =
            (itemVideoId != null &&
                itemVideoId.isNotEmpty &&
                currentVideoId == itemVideoId) ||
            currentMediaItem?.id == song.rawPath ||
            (itemVideoId != null && currentMediaItem?.id == 'yt:$itemVideoId');

        final isAmoledTheme =
            colorSchemeNotifier.value == AppColorScheme.amoled;

        // Solo usar ValueListenableBuilder para el estado de reproducción si es la canción actual
        if (isCurrent) {
          return ValueListenableBuilder<bool>(
            valueListenable: _isPlayingNotifier,
            builder: (context, playing, child) {
              return _buildOptimizedQuickPickTile(
                song: song,
                context: context,
                leading: leading,
                isCurrent: isCurrent,
                playing: playing,
                isAmoledTheme: isAmoledTheme,
                pageSongs: pageSongs,
              );
            },
          );
        } else {
          // Para canciones que no están reproduciéndose, no usar listener de estado
          return _buildOptimizedQuickPickTile(
            song: song,
            context: context,
            leading: leading,
            isCurrent: isCurrent,
            playing: false,
            isAmoledTheme: isAmoledTheme,
            pageSongs: pageSongs,
          );
        }
      },
    );
  }

  Widget _buildOptimizedQuickPickTile({
    required _StreamingRecentItem song,
    required BuildContext context,
    required Widget leading,
    required bool isCurrent,
    required bool playing,
    required bool isAmoledTheme,
    required List<_StreamingRecentItem> pageSongs,
  }) {
    return RepaintBoundary(
      child: ListTile(
        key: ValueKey(song.rawPath),
        contentPadding: const EdgeInsets.symmetric(horizontal: 0),
        splashColor: Colors.transparent,
        leading: leading,
        title: Row(
          children: [
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: MiniMusicVisualizer(
                  color: Theme.of(context).colorScheme.primary,
                  width: 4,
                  height: 15,
                  radius: 4,
                  animate: playing,
                ),
              ),
            Expanded(
              child: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isCurrent
                    ? Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: isAmoledTheme
                            ? Colors.white
                            : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      )
                    : Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        subtitle: Text(
          _formatStreamingArtistWithDuration(song),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCurrent
              ? TextStyle(
                  color: isAmoledTheme
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                )
              : isAmoledTheme
              ? TextStyle(color: Colors.white.withValues(alpha: 0.8))
              : null,
        ),
        trailing: const Opacity(opacity: 0, child: Icon(Icons.more_vert)),
        onTap: () async {
          if (!mounted) return;
          await _playStreamingEntry(
            item: song,
            sourceItems: pageSongs,
            queueSource: LocaleProvider.tr('quick_pick_songs'),
            playOnlyTapped: true,
            autoStartRadio: true,
          );
        },
        onLongPress: () async {
          HapticFeedback.mediumImpact();
          if (!mounted) return;
          await _showStreamingShortcutOptions(song);
        },
      ),
    );
  }

  Future<void> _buscarActualizacion() async {
    if (_updateChecked) return;
    _updateChecked = true;
    final updateInfo = await OtaUpdateHelper.checkForUpdate();
    if (mounted && updateInfo != null) {
      setState(() {
        _updateVersion = updateInfo.version;
        _updateApkUrl = updateInfo.apkUrl;
      });
    }
  }

  Future<void> _loadAllSongs() async {
    final songs = await SongsIndexDB().getIndexedSongs();
    setState(() {
      allSongs = songs;
    });
  }

  Future<void> _loadPlaylists() async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    List<Map<String, dynamic>> playlistsWithSongs = [];
    for (final playlist in playlists) {
      // playlist es un PlaylistModel, accede directo a sus campos
      playlistsWithSongs.add({
        'id': playlist.id,
        'name': playlist.name,
        'songs': playlist.songPaths,
      });
    }
    /*  
    setState(() {
      _playlists = playlistsWithSongs;
    });
    */
  }

  Future<void> _loadPlaylistSongs(Map<String, dynamic> playlist) async {
    final songs = await PlaylistsDB().getSongsFromPlaylist(playlist['id']);
    // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
    _artistWidgetCache.clear();
    setState(() {
      _originalPlaylistSongs = List.from(songs);
      _selectedPlaylist = playlist;
      _showingPlaylistSongs = true;
      _showingRecents = false;
      _gradientAlphaNotifier.value = 1.0;
    });
    _ordenarCancionesPlaylist();

    // Precargar carátulas de la playlist
    unawaited(_preloadArtworksForSongs(songs));
  }

  /// Función específica para refrescar las canciones de la playlist actual
  Future<void> _refreshPlaylistSongs() async {
    if (_selectedPlaylist != null) {
      final songs = await PlaylistsDB().getSongsFromPlaylist(
        _selectedPlaylist!['id'],
      );
      setState(() {
        _originalPlaylistSongs = List.from(songs);
      });
      _ordenarCancionesPlaylist();

      // Precargar carátulas de la playlist
      unawaited(_preloadArtworksForSongs(songs));
    }
  }

  Future<void> _loadMostPlayed() async {
    final songs = await MostPlayedDB().getMostPlayed(limit: 40);
    final streamingShortcuts = await _buildStreamingShortcutPool(
      limit: _quickAccessSlots,
      maxMostPlayed: _quickAccessSlots,
    );
    setState(() {
      _mostPlayed = songs;
      _streamingShortcutSongs = streamingShortcuts;
      _streamingShortcutWidgetCache.clear();
    });
    _shuffleQuickPick();

    // Limpiar cache de selección rápida cuando se cargan nuevas canciones
    // _quickPickWidgetCache.clear(); // Evitar parpadeos al actualizar estadísticas

    // Precargar carátulas de canciones más reproducidas
    unawaited(_preloadArtworksForSongs(songs));
  }

  Future<List<_StreamingRecentItem>> _buildStreamingShortcutPool({
    int limit = _quickAccessSlots,
    int maxMostPlayed = _quickAccessSlots,
  }) async {
    final shortcutPaths = await ShortcutsDB().getShortcuts();
    final pinnedStreamingPaths = shortcutPaths
        .where(_isStreamingRecentPath)
        .toList();
    final pinnedItems = await _buildStreamingShortcutsFromPinnedPaths(
      pinnedStreamingPaths,
      maxItems: limit,
    );

    final mostPlayedPaths = await MostPlayedDB().getMostPlayedPaths(
      limit: maxMostPlayed + 40,
    );
    final mostPlayedStreaming = mostPlayedPaths
        .where(_isStreamingRecentPath)
        .toList();
    final mostPlayedItems = await _buildStreamingMostPlayed(
      mostPlayedStreaming,
    );

    final combined = <_StreamingRecentItem>[];
    final used = <String>{};

    String itemKey(_StreamingRecentItem item) {
      final videoId = item.videoId?.trim();
      if (videoId != null && videoId.isNotEmpty) {
        return 'yt:$videoId';
      }
      return item.rawPath.trim();
    }

    void addIfUnique(_StreamingRecentItem item) {
      final key = itemKey(item);
      if (key.isEmpty || used.contains(key)) return;
      used.add(key);
      combined.add(item);
    }

    for (final item in pinnedItems) {
      if (combined.length >= limit) break;
      addIfUnique(item);
    }

    for (final item in mostPlayedItems) {
      if (combined.length >= limit) break;
      addIfUnique(item);
    }

    if (combined.length < limit) {
      final missing = limit - combined.length;
      final favoritePaths = await FavoritesDB().getFavoritePaths();
      final favoriteStreaming =
          favoritePaths.where(_isStreamingRecentPath).toList()..shuffle();
      final favoriteItems = await _buildStreamingFavoritesForShortcuts(
        favoriteStreaming,
        maxItems: missing + 24,
      );
      for (final item in favoriteItems) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    if (combined.length < limit) {
      final missing = limit - combined.length;
      final playlists = await PlaylistsDB().getAllPlaylists();
      playlists.shuffle();
      final playlistItems = await _buildStreamingPlaylistsForShortcuts(
        playlists,
        maxItems: missing + 24,
      );
      for (final item in playlistItems) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    // Fallback: completar huecos restantes con búsquedas aleatorias en YouTube Music.
    if (combined.length < limit) {
      await _ensureSharedYtFallbackPoolLoaded();
      final ytFallback = _sharedYtFallbackPool.take(limit - combined.length);
      for (final item in ytFallback) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    return combined;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingQuickPickPool(
    List<_StreamingRecentItem> recents, {
    int limit = 50,
  }) async {
    final combined = <_StreamingRecentItem>[];
    final used = <String>{};

    String itemKey(_StreamingRecentItem item) {
      final videoId = item.videoId?.trim();
      if (videoId != null && videoId.isNotEmpty) {
        return 'yt:$videoId';
      }
      return item.rawPath.trim();
    }

    void addIfUnique(_StreamingRecentItem item) {
      final key = itemKey(item);
      if (key.isEmpty || used.contains(key)) return;
      used.add(key);
      combined.add(item);
    }

    final recentPlayable =
        recents
            .where((item) => item.videoId?.trim().isNotEmpty ?? false)
            .toList()
          ..shuffle();
    for (final item in recentPlayable) {
      if (combined.length >= limit) break;
      addIfUnique(item);
    }

    if (combined.length < limit) {
      final missing = limit - combined.length;
      final favoritePaths = await FavoritesDB().getFavoritePaths();
      final favoriteStreaming =
          favoritePaths.where(_isStreamingRecentPath).toList()..shuffle();
      final favoriteItems = await _buildStreamingFavoritesForShortcuts(
        favoriteStreaming,
        maxItems: missing + 24,
      );
      for (final item in favoriteItems) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    if (combined.length < limit) {
      final missing = limit - combined.length;
      final playlists = await PlaylistsDB().getAllPlaylists();
      playlists.shuffle();
      final playlistItems = await _buildStreamingPlaylistsForShortcuts(
        playlists,
        maxItems: missing + 24,
      );
      for (final item in playlistItems) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    if (combined.length < limit) {
      await _ensureSharedYtFallbackPoolLoaded();
      for (final item in _sharedYtFallbackPool) {
        if (combined.length >= limit) break;
        addIfUnique(item);
      }
    }

    return combined;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingFallbackFromYt({
    int limit = _quickAccessSlots,
    List<String>? queryPoolOverride,
    Set<String>? excludedVideoIds,
  }) async {
    final queryPool =
        (queryPoolOverride ??
                const <String>[
                  'música',
                  'música tendencias',
                  'música del momento',
                  'música 2026',
                  'Música exitos de los 70, 80, 90',
                  'top hits',
                  'canciones virales',
                  'música popular',
                  'hits latinos',
                  'top songs',
                ])
            .toList()
          ..shuffle();

    final selectedQueries = queryPool.take(4).toList();
    final items = <_StreamingRecentItem>[];
    final usedVideoIds = <String>{...?excludedVideoIds};
    const int batchSize = 2;

    for (int i = 0; i < selectedQueries.length; i += batchSize) {
      if (items.length >= limit) break;
      final batchQueries = selectedQueries.skip(i).take(batchSize).toList();
      final batchResults = await Future.wait(
        batchQueries.map((query) async {
          try {
            return await searchSongsOnly(query, cancelPrevious: false);
          } catch (_) {
            return <YtMusicResult>[];
          }
        }),
      );

      for (final results in batchResults) {
        if (items.length >= limit) break;
        for (final result in results) {
          if (items.length >= limit) break;
          final videoId = result.videoId?.trim();
          if (videoId == null || videoId.isEmpty) continue;
          if (!usedVideoIds.add(videoId)) continue;

          final title = result.title?.trim();
          final artist = result.artist?.trim();
          final artUri = result.thumbUrl?.trim();
          final durationMs = result.durationMs;
          final durationText = result.durationText?.trim();
          items.add(
            _StreamingRecentItem(
              rawPath: 'yt:$videoId',
              title: (title != null && title.isNotEmpty)
                  ? title
                  : LocaleProvider.tr('title_unknown'),
              artist: (artist != null && artist.isNotEmpty)
                  ? artist
                  : LocaleProvider.tr('artist_unknown'),
              videoId: videoId,
              artUri: (artUri != null && artUri.isNotEmpty) ? artUri : null,
              durationText: (durationText != null && durationText.isNotEmpty)
                  ? durationText
                  : null,
              durationMs: durationMs,
            ),
          );
        }
      }
    }

    return items;
  }

  Map<String, dynamic> _streamingItemToCacheMap(_StreamingRecentItem item) {
    return <String, dynamic>{
      'rawPath': item.rawPath,
      'title': item.title,
      'artist': item.artist,
      if (item.videoId != null && item.videoId!.trim().isNotEmpty)
        'videoId': item.videoId!.trim(),
      if (item.artUri != null && item.artUri!.trim().isNotEmpty)
        'artUri': item.artUri!.trim(),
      if (item.durationText != null && item.durationText!.trim().isNotEmpty)
        'durationText': item.durationText!.trim(),
      if (item.durationMs != null && item.durationMs! > 0)
        'durationMs': item.durationMs,
      if (item.isPinned) 'isPinned': true,
    };
  }

  _StreamingRecentItem? _streamingItemFromCacheMap(Map<String, dynamic> raw) {
    final rawPath = raw['rawPath']?.toString().trim() ?? '';
    final videoIdRaw = raw['videoId']?.toString().trim();
    final videoId = (videoIdRaw != null && videoIdRaw.isNotEmpty)
        ? videoIdRaw
        : _extractVideoIdFromPath(rawPath);
    if (videoId == null || videoId.isEmpty) return null;

    final title = raw['title']?.toString().trim();
    final artist = raw['artist']?.toString().trim();
    final artUri = raw['artUri']?.toString().trim();
    final durationText = raw['durationText']?.toString().trim();
    final durationMs = _parseDurationMs(raw['durationMs']);
    final isPinnedRaw = raw['isPinned'];
    final isPinned = isPinnedRaw is bool ? isPinnedRaw : false;

    return _StreamingRecentItem(
      rawPath: rawPath.isNotEmpty ? rawPath : 'yt:$videoId',
      title: (title != null && title.isNotEmpty)
          ? title
          : LocaleProvider.tr('title_unknown'),
      artist: (artist != null && artist.isNotEmpty)
          ? artist
          : LocaleProvider.tr('artist_unknown'),
      videoId: videoId,
      artUri: (artUri != null && artUri.isNotEmpty) ? artUri : null,
      durationText: (durationText != null && durationText.isNotEmpty)
          ? durationText
          : null,
      durationMs: durationMs,
      isPinned: isPinned,
    );
  }

  Future<void> _loadHomeYoutubeCache() async {
    if (_homeYtCacheLoaded) return;
    _homeYtCacheLoaded = true;

    try {
      final cached = await HomeYoutubeCacheDB().getSharedPool();
      if (cached.isEmpty) return;
      final shared = cached
          .map(_streamingItemFromCacheMap)
          .whereType<_StreamingRecentItem>()
          .toList();
      if (shared.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _sharedYtFallbackPool = shared;
      });
    } catch (_) {
      // Ignorar errores de cache para no bloquear la carga.
    }
  }

  Future<void> _saveHomeYoutubeCache(List<_StreamingRecentItem> shared) async {
    try {
      final payload = shared.map(_streamingItemToCacheMap).toList();
      await HomeYoutubeCacheDB().saveSharedPool(payload);
    } catch (_) {
      // Ignorar errores de persistencia para no interrumpir la UI.
    }
  }

  Future<void> _ensureQuickPickYtFallbackLoaded({
    bool forceReload = false,
  }) async {
    if (!forceReload && _quickPickYtFallbackSongs.isNotEmpty) return;

    await _ensureSharedYtFallbackPoolLoaded(forceReload: forceReload);

    final excludedVideoIds = _streamingShortcutSongs
        .map((item) => item.videoId?.trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    final fallback = _sharedYtFallbackPool
        .where((item) {
          final id = item.videoId?.trim();
          if (id == null || id.isEmpty) return false;
          return !excludedVideoIds.contains(id);
        })
        .take(50)
        .toList();

    if (!mounted) return;
    setState(() {
      _quickPickYtFallbackSongs = fallback;
    });
  }

  Future<void> _ensureSharedYtFallbackPoolLoaded({
    bool forceReload = false,
  }) async {
    if (!forceReload && _sharedYtFallbackPool.isNotEmpty) return;
    if (_sharedYtFallbackLoading != null) {
      await _sharedYtFallbackLoading;
      return;
    }

    _sharedYtFallbackLoading = (() async {
      final shared = await _buildStreamingFallbackFromYt(
        limit: 120,
        queryPoolOverride: const [
          'música tendencias',
          'música del momento',
          'top hits',
          'canciones virales',
          'novedades musicales',
          'mix canciones trending',
          'descubrimiento musical',
          'top charts music',
        ],
      );
      if (!mounted) return;
      await _saveHomeYoutubeCache(shared);
      setState(() {
        _sharedYtFallbackPool = shared;
      });
    })();

    try {
      await _sharedYtFallbackLoading;
    } finally {
      _sharedYtFallbackLoading = null;
    }
  }

  Future<void> _preloadArtworksForSongs(List<SongModel> songs) async {
    try {
      for (final song in songs.take(20)) {
        // Usar el sistema de caché del MyAudioHandler en lugar de OnAudioQuery directamente
        unawaited(getOrCacheArtwork(song.id, song.data));
      }
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  Future<void> _preloadArtworkForSong(SongModel song) async {
    try {
      await getOrCacheArtwork(song.id, song.data);
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  bool _isStreamingRecentPath(String path) {
    final normalized = path.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized.startsWith('/')) return false;
    if (normalized.startsWith('file://')) return false;
    if (normalized.startsWith('content://')) return false;
    return true;
  }

  bool _playlistMatchesTargetSource(
    hive_model.PlaylistModel playlist, {
    required bool forStreaming,
  }) {
    if (playlist.songPaths.isEmpty) return true;
    if (forStreaming) return playlist.songPaths.any(_isStreamingRecentPath);
    return playlist.songPaths.any((path) => !_isStreamingRecentPath(path));
  }

  String? _extractVideoIdFromPath(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return null;

    if (path.startsWith('yt:')) {
      final id = path.substring(3).trim();
      return id.isEmpty ? null : id;
    }

    final uri = Uri.tryParse(path);
    if (uri != null) {
      final queryVideoId = uri.queryParameters['v']?.trim();
      if (queryVideoId != null && queryVideoId.isNotEmpty) {
        return queryVideoId;
      }
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        final shortId = uri.pathSegments.first.trim();
        if (shortId.isNotEmpty) {
          return shortId;
        }
      }
    }

    final idLike = RegExp(r'^[a-zA-Z0-9_-]{11}$');
    if (idLike.hasMatch(path)) {
      return path;
    }

    return null;
  }

  String _currentStreamingCoverQuality() {
    final quality = coverQualityNotifier.value;
    if (quality == 'high' || quality == 'medium' || quality == 'low') {
      return quality;
    }
    return 'medium';
  }

  String _ytThumbFileForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 'sddefault.jpg';
      case 'low':
        return 'hqdefault.jpg';
      default:
        return 'maxresdefault.jpg';
    }
  }

  String _googleThumbSizeForQuality(String quality) {
    switch (quality) {
      case 'medium':
        return 's600';
      case 'low':
        return 's300';
      default:
        return 's1200';
    }
  }

  String? _applyStreamingArtworkQuality(String? rawUrl, {String? videoId}) {
    final normalized = rawUrl?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'null') {
      return null;
    }

    final quality = _currentStreamingCoverQuality();
    final lower = normalized.toLowerCase();

    if (lower.contains('googleusercontent.com')) {
      final size = _googleThumbSizeForQuality(quality);
      final replaced = normalized.replaceFirst(RegExp(r'=s\d+\b'), '=$size');
      if (replaced != normalized) return replaced;

      final eqIndex = normalized.lastIndexOf('=');
      if (eqIndex != -1 && eqIndex < normalized.length - 1) {
        final suffix = normalized.substring(eqIndex + 1);
        if (!suffix.contains('/')) {
          return '${normalized.substring(0, eqIndex + 1)}$size';
        }
      }
      return '$normalized=$size';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) return normalized;

    final host = uri.host.toLowerCase();
    if (!host.contains('ytimg.com') && !host.contains('img.youtube.com')) {
      return normalized;
    }

    final qualityFile = _ytThumbFileForQuality(quality);
    final qualityWebp = qualityFile.replaceAll('.jpg', '.webp');
    final segments = List<String>.from(uri.pathSegments);

    if (segments.isNotEmpty) {
      final last = segments.last.toLowerCase();
      final isKnownThumb =
          last.contains('maxresdefault') ||
          last.contains('sddefault') ||
          last.contains('hqdefault') ||
          last.contains('mqdefault');
      if (isKnownThumb) {
        final useWebp = last.endsWith('.webp');
        segments[segments.length - 1] = useWebp ? qualityWebp : qualityFile;
        return uri.replace(pathSegments: segments).toString();
      }
    }

    final id = videoId?.trim();
    if (id != null && id.isNotEmpty) {
      return 'https://i.ytimg.com/vi/$id/$qualityFile';
    }

    return normalized;
  }

  List<String> _streamingFallbackArtworkUrls(String videoId) {
    final qualityFile = _ytThumbFileForQuality(_currentStreamingCoverQuality());
    final urls = <String>[
      'https://i.ytimg.com/vi/$videoId/$qualityFile',
      'https://img.youtube.com/vi/$videoId/sddefault.jpg',
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
    ];
    return urls.toSet().toList();
  }

  Future<_StreamingRecentItem?> _buildStreamingItemFromPath(
    String path, {
    Map<String, dynamic>? meta,
    bool useMetaDurationText = true,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return null;

    final metaVideoId = meta?['videoId']?.toString().trim();
    final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
        ? metaVideoId
        : _extractVideoIdFromPath(normalizedPath);

    final byPath = await DownloadHistoryHive.getDownloadByPath(normalizedPath);
    final byVideo = videoId == null
        ? null
        : await DownloadHistoryHive.getDownloadByVideoId(videoId);
    final history = byPath ?? byVideo;

    final metaTitle = meta?['title']?.toString().trim();
    final metaArtist = meta?['artist']?.toString().trim();
    final metaArtUri = meta?['artUri']?.toString().trim();
    final resolvedMetaArtUri = _applyStreamingArtworkQuality(
      metaArtUri,
      videoId: videoId,
    );
    final metaDurationText = meta?['durationText']?.toString().trim();
    final metaDurationMs = _parseDurationMs(meta?['durationMs']);
    final historyDurationMs = (history != null && history.duration > 0)
        ? history.duration * 1000
        : null;
    final durationMs = metaDurationMs ?? historyDurationMs;

    final durationText =
        useMetaDurationText &&
            metaDurationText != null &&
            metaDurationText.isNotEmpty
        ? metaDurationText
        : (durationMs != null && durationMs > 0)
        ? _formatDurationMs(durationMs)
        : null;

    final title = (metaTitle != null && metaTitle.isNotEmpty)
        ? metaTitle
        : (history?.title.trim().isNotEmpty ?? false)
        ? history!.title.trim()
        : videoId != null && videoId.isNotEmpty
        ? 'YouTube Music ($videoId)'
        : normalizedPath;
    final artist = (metaArtist != null && metaArtist.isNotEmpty)
        ? metaArtist
        : (history?.artist.trim().isNotEmpty ?? false)
        ? history!.artist.trim()
        : LocaleProvider.tr('artist_unknown');

    return _StreamingRecentItem(
      rawPath: normalizedPath,
      title: title,
      artist: artist,
      videoId: videoId,
      artUri: resolvedMetaArtUri,
      durationText: durationText,
      durationMs: durationMs,
    );
  }

  Future<List<_StreamingRecentItem>> _buildStreamingRecents(
    List<String> paths,
  ) async {
    final items = <_StreamingRecentItem>[];
    for (final path in paths) {
      final normalizedPath = path.trim();
      if (normalizedPath.isEmpty) continue;
      final meta = await RecentsDB().getRecentMeta(normalizedPath);
      final item = await _buildStreamingItemFromPath(
        normalizedPath,
        meta: meta,
        useMetaDurationText: true,
      );
      if (item != null) items.add(item);
    }
    return items;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingMostPlayed(
    List<String> paths, {
    int? maxItems,
  }) async {
    final items = <_StreamingRecentItem>[];
    final db = MostPlayedDB();
    for (final path in paths) {
      if (maxItems != null && items.length >= maxItems) break;
      final normalizedPath = path.trim();
      if (normalizedPath.isEmpty) continue;
      final meta = await db.getMostPlayedMeta(normalizedPath);
      final item = await _buildStreamingItemFromPath(
        normalizedPath,
        meta: meta,
        useMetaDurationText: false,
      );
      if (item != null) items.add(item);
    }
    return items;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingFavoritesForShortcuts(
    List<String> paths, {
    int? maxItems,
  }) async {
    final items = <_StreamingRecentItem>[];
    final db = FavoritesDB();
    for (final path in paths) {
      if (maxItems != null && items.length >= maxItems) break;
      final normalizedPath = path.trim();
      if (normalizedPath.isEmpty) continue;
      final meta = await db.getFavoriteMeta(normalizedPath);
      final item = await _buildStreamingItemFromPath(
        normalizedPath,
        meta: meta,
        useMetaDurationText: true,
      );
      if (item != null) items.add(item);
    }
    return items;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingShortcutsFromPinnedPaths(
    List<String> paths, {
    int? maxItems,
  }) async {
    final items = <_StreamingRecentItem>[];
    final db = ShortcutsDB();
    for (final path in paths) {
      if (maxItems != null && items.length >= maxItems) break;
      final normalizedPath = path.trim();
      if (normalizedPath.isEmpty) continue;
      final meta = await db.getShortcutMeta(normalizedPath);
      final item = await _buildStreamingItemFromPath(
        normalizedPath,
        meta: meta,
        useMetaDurationText: true,
      );
      if (item != null) {
        items.add(
          _StreamingRecentItem(
            rawPath: item.rawPath,
            title: item.title,
            artist: item.artist,
            videoId: item.videoId,
            artUri: item.artUri,
            durationText: item.durationText,
            durationMs: item.durationMs,
            isPinned: true,
          ),
        );
      }
    }
    return items;
  }

  Future<List<_StreamingRecentItem>> _buildStreamingPlaylistsForShortcuts(
    List<hive_model.PlaylistModel> playlists, {
    int? maxItems,
  }) async {
    final db = PlaylistsDB();
    final items = <_StreamingRecentItem>[];
    for (final playlist in playlists) {
      for (final rawPath in playlist.songPaths) {
        if (maxItems != null && items.length >= maxItems) break;
        final normalizedPath = rawPath.trim();
        if (normalizedPath.isEmpty || !_isStreamingRecentPath(normalizedPath)) {
          continue;
        }
        final meta = await db.getPlaylistSongMeta(playlist.id, normalizedPath);
        final item = await _buildStreamingItemFromPath(
          normalizedPath,
          meta: meta,
          useMetaDurationText: true,
        );
        if (item != null) items.add(item);
      }
      if (maxItems != null && items.length >= maxItems) break;
    }
    return items;
  }

  Future<void> _toggleRecentsSource() async {
    setState(() {
      _recentSongsSource = _recentSongsSource == RecentSongsSource.local
          ? RecentSongsSource.streaming
          : RecentSongsSource.local;
    });
    await _saveRecentsSourceFilter();
    _onSearchRecentsChanged();
  }

  List<String> _streamingArtworkSources(_StreamingRecentItem item) {
    final sources = <String>[];
    final id = item.videoId?.trim();
    final rawArt = _applyStreamingArtworkQuality(item.artUri, videoId: id);
    if (rawArt != null && rawArt.isNotEmpty) {
      sources.add(rawArt);
    }
    if (id != null && id.isNotEmpty) {
      sources.addAll(_streamingFallbackArtworkUrls(id));
    }
    return sources.toSet().toList();
  }

  Future<void> _playStreamingEntry({
    required _StreamingRecentItem item,
    required List<_StreamingRecentItem> sourceItems,
    required String queueSource,
    bool playOnlyTapped = false,
    bool autoStartRadio = false,
  }) async {
    final videoId = item.videoId?.trim();
    if (videoId == null || videoId.isEmpty) return;
    if (playLoadingNotifier.value) return;

    playLoadingNotifier.value = true;
    openPlayerPanelNotifier.value = true;

    try {
      final handler = await getAudioServiceSafely();
      if (handler == null) {
        playLoadingNotifier.value = false;
        return;
      }

      final playbackSource = playOnlyTapped
          ? <_StreamingRecentItem>[item]
          : sourceItems;
      if (playbackSource.isEmpty) return;
      final queueItems = playbackSource
          .where((entry) => (entry.videoId?.trim().isNotEmpty ?? false))
          .map((entry) {
            final entryVideoId = entry.videoId!.trim();
            final entryArtUri =
                _applyStreamingArtworkQuality(
                  entry.artUri,
                  videoId: entryVideoId,
                ) ??
                _streamingFallbackArtworkUrls(entryVideoId).first;
            return <String, dynamic>{
              'videoId': entryVideoId,
              'title': entry.title.trim().isNotEmpty
                  ? entry.title.trim()
                  : LocaleProvider.tr('title_unknown'),
              'artist': entry.artist.trim().isNotEmpty
                  ? entry.artist.trim()
                  : LocaleProvider.tr('artist_unknown'),
              'artUri': entryArtUri,
              if (entry.durationMs != null && entry.durationMs! > 0)
                'durationMs': entry.durationMs,
              if (entry.durationText != null &&
                  entry.durationText!.trim().isNotEmpty)
                'durationText': entry.durationText!.trim(),
            };
          })
          .toList();
      if (queueItems.isEmpty) return;

      int initialQueueIndex = queueItems.indexWhere(
        (entry) => entry['videoId'] == videoId,
      );
      if (initialQueueIndex < 0) {
        initialQueueIndex = 0;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_queue_source', queueSource);

      await handler
          .customAction('playYtStreamQueue', {
            'items': queueItems,
            'initialIndex': initialQueueIndex,
            'autoPlay': true,
            if (autoStartRadio) 'autoStartRadio': true,
          })
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Ignorar para no mostrar error si inició correctamente entre transiciones.
      playLoadingNotifier.value = false;
    }
  }

  Future<void> _playStreamingRecent(_StreamingRecentItem item) async {
    await _playStreamingEntry(
      item: item,
      sourceItems: _streamingRecents,
      queueSource: LocaleProvider.tr('recent_songs_title'),
    );
  }

  Future<void> _playStreamingShortcut(_StreamingRecentItem item) async {
    await _playStreamingEntry(
      item: item,
      sourceItems: _streamingShortcutSongs,
      queueSource: LocaleProvider.tr('quick_access_songs'),
      playOnlyTapped: true,
      autoStartRadio: true,
    );
  }

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      final recentPaths = await RecentsDB().getRecentPaths();
      final streamingPaths = recentPaths.where(_isStreamingRecentPath).toList();
      final streamingRecents = await _buildStreamingRecents(streamingPaths);
      final quickPickPool = await _buildStreamingQuickPickPool(
        streamingRecents,
      );
      setState(() {
        _recentSongs = recents;
        _streamingRecents = streamingRecents;
        _shuffledStreamingRecentsQuickPick = quickPickPool;
        if (_shuffledStreamingRecentsQuickPick.isNotEmpty) {
          _quickPickYtFallbackSongs = [];
        }
        _showingRecents = true;
        _gradientAlphaNotifier.value = 1.0;
      });
      if (_shuffledStreamingRecentsQuickPick.isEmpty) {
        unawaited(_ensureQuickPickYtFallbackLoaded());
      }

      // Precargar carátulas de canciones recientes
      unawaited(_preloadArtworksForSongs(recents));
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _streamingRecents = [];
        _shuffledStreamingRecentsQuickPick = [];
        _quickPickYtFallbackSongs = [];
        _showingRecents = true;
        _gradientAlphaNotifier.value = 1.0;
      });
      unawaited(_ensureQuickPickYtFallbackLoaded());
    }
  }

  // Método para cargar solo los datos de recientes sin mostrar la UI
  Future<void> _loadRecentsData() async {
    try {
      final recents = await RecentsDB().getRecents();
      final recentPaths = await RecentsDB().getRecentPaths();
      final streamingPaths = recentPaths.where(_isStreamingRecentPath).toList();
      final streamingRecents = await _buildStreamingRecents(streamingPaths);
      final quickPickPool = await _buildStreamingQuickPickPool(
        streamingRecents,
      );
      setState(() {
        _recentSongs = recents;
        _streamingRecents = streamingRecents;
        _shuffledStreamingRecentsQuickPick = quickPickPool;
        if (_shuffledStreamingRecentsQuickPick.isNotEmpty) {
          _quickPickYtFallbackSongs = [];
        }
        // No cambiamos _showingRecents aquí
      });
      if (_shuffledStreamingRecentsQuickPick.isEmpty) {
        unawaited(_ensureQuickPickYtFallbackLoaded());
      }

      // Precargar carátulas de canciones recientes
      unawaited(_preloadArtworksForSongs(recents));
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _streamingRecents = [];
        _shuffledStreamingRecentsQuickPick = [];
        _quickPickYtFallbackSongs = [];
        // No cambiamos _showingRecents aquí
      });
      unawaited(_ensureQuickPickYtFallbackLoaded());
    }
  }

  void _openRecentsFast() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_showingRecents || _showingPlaylistSongs || _showingDiscovery) {
      setState(() {
        _showingRecents = true;
        _showingPlaylistSongs = false;
        _showingDiscovery = false;
        _gradientAlphaNotifier.value = 1.0;
      });
    }
    _onSearchRecentsChanged();
    _recentsWarmLoad ??= _loadRecentsData().whenComplete(() {
      _recentsWarmLoad = null;
    });
  }

  void _onSearchRecentsChanged() {
    final query = _quitarDiacriticos(_searchRecentsController.text.trim());
    if (query.isEmpty) {
      setState(() {
        _filteredRecents = [];
        _filteredStreamingRecents = [];
      });
      return;
    }
    setState(() {
      _filteredRecents = _recentSongs.where((song) {
        final title = _quitarDiacriticos(song.displayTitle);
        final artist = _quitarDiacriticos(song.displayArtist);
        return title.contains(query) || artist.contains(query);
      }).toList();
      _filteredStreamingRecents = _streamingRecents.where((item) {
        final title = _quitarDiacriticos(item.title);
        final artist = _quitarDiacriticos(item.artist);
        return title.contains(query) || artist.contains(query);
      }).toList();
    });
  }

  void _onSearchPlaylistChanged() {
    final query = _quitarDiacriticos(_searchPlaylistController.text.trim());
    if (query.isEmpty) {
      setState(() => _filteredPlaylistSongs = []);
      return;
    }
    List<SongModel> filteredList = _playlistSongs.where((song) {
      final title = _quitarDiacriticos(song.displayTitle);
      final artist = _quitarDiacriticos(song.displayArtist);
      return title.contains(query) || artist.contains(query);
    }).toList();

    setState(() {
      _filteredPlaylistSongs = filteredList;
    });
  }

  String _quitarDiacriticos(String texto) {
    const conAcentos = 'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ';
    const sinAcentos = 'aaaaaeeeeiiiiooooouuuuaaaaaeeeeiiiiooooouuuu';
    for (int i = 0; i < conAcentos.length; i++) {
      texto = texto.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return texto.toLowerCase();
  }

  // Agrega la key global arriba en HomeScreenState
  final GlobalKey ytScreenKey = GlobalKey();

  bool canPopInternally() {
    // Retorna true si hay navegación interna dentro de Home
    return _showingRecents || _showingPlaylistSongs || _showingDiscovery;
  }

  void handleInternalPop() {
    // Manejar navegación interna de home screen
    if (_showingRecents || _showingPlaylistSongs || _showingDiscovery) {
      // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
      _artistWidgetCache.clear();
      setState(() {
        _showingRecents = false;
        _showingPlaylistSongs = false;
        _showingDiscovery = false;
      });
    }
  }

  void _onHomeScroll() {
    if (!mounted) return;
    final o = _homeScrollController.offset;
    final newAlpha = (1.0 - (o / 180.0).clamp(0.0, 1.0));
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastGradientAlphaUpdateMs > _gradientThrottleMs) {
      _gradientAlphaNotifier.value = newAlpha;
      _lastGradientAlphaUpdateMs = now;
    }
    _gradientSyncTimer?.cancel();
    _gradientSyncTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      final finalAlpha =
          (1.0 - (_homeScrollController.offset / 180.0).clamp(0.0, 1.0));
      _gradientAlphaNotifier.value = finalAlpha;
    });
  }

  /// Generar cuadrícula de carátulas para una playlist
  Widget _buildPlaylistArtworkGrid(
    hive_model.PlaylistModel playlist,
    List<SongModel> allSongs, {
    Map<String, List<String>> streamingArtworkCache =
        const <String, List<String>>{},
  }) {
    final filtered = playlist.songPaths
        .where((path) => path.trim().isNotEmpty)
        .toList();
    final latestPaths = filtered.reversed.take(4).toList();

    final List<Widget> artworks = latestPaths.map((path) {
      final normalizedPath = path.trim();
      if (_isStreamingRecentPath(normalizedPath)) {
        return _StreamingArtwork(
          sources: _streamingPlaylistArtworkSources(
            playlist.id,
            normalizedPath,
            streamingArtworkCache,
          ),
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
        );
      }

      final songIndex = allSongs.indexWhere(
        (song) => song.data == normalizedPath,
      );
      if (songIndex == -1) {
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
          ),
        );
      }
      final song = allSongs[songIndex];
      return ArtworkListTile(
        songId: song.id,
        songPath: song.data,
        borderRadius: BorderRadius.zero,
      );
    }).toList();

    return SizedBox(
      width: 48,
      height: 48,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildArtworkLayout(artworks),
      ),
    );
  }

  List<String> _streamingPlaylistArtworkSources(
    String playlistId,
    String path,
    Map<String, List<String>> streamingArtworkCache,
  ) {
    final cacheKey = '$playlistId::$path';
    final cached = streamingArtworkCache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    final videoId = _extractVideoIdFromPath(path);
    if (videoId == null || videoId.isEmpty) return const [];
    return _streamingFallbackArtworkUrls(videoId);
  }

  Future<Map<String, List<String>>> _buildPlaylistArtworkSourcesCache(
    List<hive_model.PlaylistModel> playlists,
  ) async {
    final cache = <String, List<String>>{};
    for (final playlist in playlists) {
      final paths = playlist.songPaths
          .where((p) => p.trim().isNotEmpty)
          .toList()
          .reversed
          .take(4);
      for (final rawPath in paths) {
        final path = rawPath.trim();
        if (!_isStreamingRecentPath(path)) continue;
        final meta = await PlaylistsDB().getPlaylistSongMeta(playlist.id, path);
        final metaArtUri = meta?['artUri']?.toString().trim();
        final metaVideoId = meta?['videoId']?.toString().trim();
        final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
            ? metaVideoId
            : _extractVideoIdFromPath(path);

        final sources = <String>[];
        final resolvedMetaArtUri = _applyStreamingArtworkQuality(
          metaArtUri,
          videoId: videoId,
        );
        if (resolvedMetaArtUri != null && resolvedMetaArtUri.isNotEmpty) {
          sources.add(resolvedMetaArtUri);
        }
        if (videoId != null && videoId.isNotEmpty) {
          sources.addAll(_streamingFallbackArtworkUrls(videoId));
        }
        if (sources.isNotEmpty) {
          cache['${playlist.id}::$path'] = sources.toSet().toList();
        }
      }
    }
    return cache;
  }

  Widget _buildArtworkLayout(List<Widget> artworks) {
    switch (artworks.length) {
      case 0:
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
          ),
        );

      case 1:
        return artworks[0];

      case 2:
      case 3:
        // Caso 2 y 3: mostramos 2 (lado a lado)
        return Row(
          children: [
            Expanded(child: artworks[0]),
            Expanded(child: artworks[1]),
          ],
        );

      default:
        // 4 o más canciones: Cuadrícula 2x2
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: artworks[0]),
                  Expanded(child: artworks[1]),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: artworks[2]),
                  Expanded(child: artworks[3]),
                ],
              ),
            ),
          ],
        );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playlistsShouldReload.removeListener(_onPlaylistsShouldReload);
    favoritesShouldReload.removeListener(_onFavoritesShouldReload);
    shortcutsShouldReload.removeListener(_onShortcutsShouldReload);
    mostPlayedShouldReload.removeListener(_onMostPlayedShouldReload);
    colorSchemeNotifier.removeListener(_onThemeChanged);
    _pageController.dispose();
    _quickPickPageController.dispose();
    _gradientSyncTimer?.cancel();
    _homeScrollController.dispose();
    _recentsScrollController.dispose();
    _playlistSongsScrollController.dispose();
    _artistSongsScrollController.dispose();
    _gradientAlphaNotifier.dispose();
    _searchRecentsController.dispose();
    _searchRecentsFocus.dispose();
    _searchPlaylistController.dispose();
    _searchPlaylistFocus.dispose();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (_showingRecents && _searchRecentsFocus.hasFocus) {
        _searchRecentsFocus.unfocus();
      }
      if (_showingPlaylistSongs && _searchPlaylistFocus.hasFocus) {
        _searchPlaylistFocus.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastBottomInset = View.of(context).viewInsets.bottom;
    // Limpiar caches cuando cambian las dependencias (como el tema)
    _artistWidgetCache.clear();
    _shortcutWidgetCache.clear();
    _quickPickWidgetCache.clear();
  }

  Future<void> _playSongAndOpenPlayer(
    SongModel song,
    List<SongModel> queue, {
    String? queueSource,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (playLoadingNotifier.value) return;
    // Desactiva visualmente el shuffle de inmediato
    try {
      audioHandler.myHandler?.isShuffleNotifier.value = false;
    } catch (_) {}

    // Obtener la carátula para la pantalla del reproductor
    final songId = song.id;
    final songPath = song.data;

    // Crear MediaItem temporal y actualizar inmediatamente para evitar visualizar la canción anterior
    // ArtworkHeroCached.clearFallback();

    // Iniciar carga de carátula
    final artUriFuture = getOrCacheArtwork(songId, songPath);
    await (artUriFuture);

    Uri? cachedArtUri;
    try {
      // Intentar obtener si es rápido (cache)
      cachedArtUri = await artUriFuture.timeout(
        const Duration(milliseconds: 25),
      );
    } catch (_) {
      // Si no es rápido, actualizar cuando esté listo para evitar el flash del placeholder
      artUriFuture.then((uri) {
        if (uri != null && mounted) {
          final handler = audioHandler.myHandler;
          final current = handler?.mediaItem.value;
          // Verificar que seguimos en la misma canción
          if (current != null && current.extras?['songId'] == songId) {
            final updatedItem = current.copyWith(artUri: uri);
            handler?.mediaItem.add(updatedItem);
          }
        }
      });
    }

    if (audioHandler != null) {
      final tempMediaItem = MediaItem(
        id: song.data,
        title: song.displayTitle,
        artist: song.displayArtist,
        duration: (song.duration != null && song.duration! > 0)
            ? Duration(milliseconds: song.duration!)
            : null,
        artUri: cachedArtUri,
        extras: {
          'songId': song.id,
          'albumId': song.albumId,
          'data': song.data,
          'queueIndex': 0,
        },
      );
      audioHandler.myHandler?.mediaItem.add(tempMediaItem);
    }

    // Abrir el panel del reproductor con la nueva animación
    if (!mounted) return;
    openPlayerPanelNotifier.value = true;

    // Activar indicador de carga
    playLoadingNotifier.value = true;

    // Reproducir la canción después de un breve delay para que se abra el panel
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        // Primero reproducir la canción
        _playSong(song, queue, queueSource: queueSource);

        // Luego agregar las canciones aleatorias al reproductor (si es necesario)
        if (queueSource == LocaleProvider.tr('quick_access_songs') ||
            queueSource == LocaleProvider.tr('quick_pick_songs')) {
          // Esperar un poco para que la reproducción se estabilice
          Future.delayed(const Duration(milliseconds: 200), () {
            unawaited(_addRandomSongsToPlayerQueue(queue));
          });
        }
      }
    });
  }

  Future<void> _playSong(
    SongModel song,
    List<SongModel> queue, {
    String? queueSource,
  }) async {
    final index = queue.indexWhere((s) => s.data == song.data);

    if (index == -1) return;

    // Obtener AudioService de forma segura
    final handler = audioHandler.myHandler;

    // Limpiar la cola y el MediaItem antes de mostrar la nueva canción (Comportamiento Favorites)
    handler?.queue.add([]);

    // Limpiar el fallback de las carátulas para evitar parpadeo
    // ArtworkHeroCached.clearFallback();

    // Guardar el origen en SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    String origen =
        queueSource ??
        (_showingPlaylistSongs && _selectedPlaylist != null
            ? "${_selectedPlaylist?['name'] ?? ''}"
            : _showingRecents
            ? LocaleProvider.tr('recent_songs_title')
            : "Home");
    await prefs.setString('last_queue_source', origen);
    await handler?.setQueueFromSongs(queue, initialIndex: index);
    await handler?.play();
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
  }

  /*
  Future<void> _handleLongPress(BuildContext context, SongModel song) async {
    HapticFeedback.mediumImpact();
    final isFavorite = await FavoritesDB().isFavorite(song.data);

    if (!context.mounted) return;
    final isAmoled =
        Theme.of(context).brightness == Brightness.dark &&
        Theme.of(context).colorScheme.surface == Colors.black;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Encabezado con información de la canción
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Carátula de la canción
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 60,
                        height: 60,
                        child: _buildModalArtwork(song),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Título y artista
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.displayTitle,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.displayArtist,
                            style: TextStyle(
                              fontSize: 14,
                              color: isAmoled
                                  ? Colors.white.withValues(alpha: 0.85)
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Botón de búsqueda para abrir opciones
                    InkWell(
                      onTap: () async {
                        Navigator.of(context).pop();
                        await _showSearchOptions(song);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                            ),
                            const SizedBox(width: 8),
                            TranslatedText(
                              'search',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Theme.of(context).colorScheme.onPrimary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: TranslatedText('add_to_queue'),
                onTap: () async {
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  await audioHandler.myHandler?.addSongsToQueueEnd([song]);
                },
              ),
              ListTile(
                leading: Icon(
                  isFavorite
                      ? Icons.delete_outline
                      : Icons.favorite_outline_rounded,
                  weight: isFavorite ? null : 600,
                ),
                title: TranslatedText(
                  isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
                ),
                onTap: () async {
                  Navigator.of(context).pop();

                  if (isFavorite) {
                    await FavoritesDB().removeFavorite(song.data);
                    favoritesShouldReload.value = !favoritesShouldReload.value;
                  } else {
                    await _addToFavorites(song);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: TranslatedText('add_to_playlist'),
                onTap: () async {
                  if (!context.mounted) return;
                  Navigator.of(context).pop();
                  await _handleAddToPlaylistSingle(context, song);
                },
              ),
              if (song.displayArtist.trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const TranslatedText('go_to_artist'),
                  onTap: () {
                    Navigator.of(context).pop();
                    final name = song.displayArtist.trim();
                    if (name.isEmpty) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            ArtistScreen(artistName: name),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              const begin = Offset(1.0, 0.0);
                              const end = Offset.zero;
                              const curve = Curves.ease;
                              final tween = Tween(
                                begin: begin,
                                end: end,
                              ).chain(CurveTween(curve: curve));
                              return SlideTransition(
                                position: animation.drive(tween),
                                child: child,
                              );
                            },
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: TranslatedText('song_info'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await SongInfoDialog.showFromSong(
                    context,
                    song,
                    colorSchemeNotifier,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
  */

  Future<void> _removeFromPlaylistMassive() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final selectedSongs =
        (_searchPlaylistController.text.isNotEmpty
                ? _filteredPlaylistSongs
                : _playlistSongs)
            .where((s) => _selectedPlaylistSongIds.contains(s.id));
    final count = _selectedPlaylistSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: TranslatedText('remove_from_playlist'),
        content: Text(
          count == 1
              ? LocaleProvider.tr('confirm_remove_from_playlist')
              : "${LocaleProvider.tr('confirm_remove_from_playlist')} ($count)",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: TranslatedText('cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: TranslatedText('remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final song in selectedSongs) {
      await PlaylistsDB().removeSongFromPlaylist(
        _selectedPlaylist!['id'],
        song.data,
      );
    }
    await _loadPlaylistSongs(_selectedPlaylist!);
    setState(() {
      _isSelectingPlaylistSongs = false;
      _selectedPlaylistSongIds.clear();
    });
  }

  Future<void> _addToFavoritesMassive() async {
    final selectedSongs =
        (_searchPlaylistController.text.isNotEmpty
                ? _filteredPlaylistSongs
                : _playlistSongs)
            .where((s) => _selectedPlaylistSongIds.contains(s.id));
    for (final song in selectedSongs) {
      await FavoritesDB().addFavorite(song);
    }
    favoritesShouldReload.value = !favoritesShouldReload.value;
    setState(() {
      _isSelectingPlaylistSongs = false;
      _selectedPlaylistSongIds.clear();
    });
  }

  void _onPlaylistSongSelected(SongModel song) {
    if (_isSelectingPlaylistSongs) {
      setState(() {
        if (_selectedPlaylistSongIds.contains(song.id)) {
          _selectedPlaylistSongIds.remove(song.id);
          if (_selectedPlaylistSongIds.isEmpty) {
            _isSelectingPlaylistSongs = false;
          }
        } else {
          _selectedPlaylistSongIds.add(song.id);
        }
      });
      return;
    }
    // La reproducción debe hacerse por debounce desde el onTap del ListTile
  }

  Future<void> _showAddFromRecentsToCurrentPlaylistDialog() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final recents = await RecentsDB().getRecents();
    if (!mounted) return;
    final Set<int> selectedIds = {};
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: TranslatedText('add_from_recents'),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: recents.isEmpty
                    ? Center(child: TranslatedText('no_songs'))
                    : ListView.builder(
                        itemCount: recents.length,
                        itemBuilder: (context, index) {
                          final song = recents[index];
                          final isSelected = selectedIds.contains(song.id);
                          return ListTile(
                            onTap: () {
                              setStateDialog(() {
                                if (isSelected) {
                                  selectedIds.remove(song.id);
                                } else {
                                  selectedIds.add(song.id);
                                }
                              });
                            },
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Checkbox(
                                  value: isSelected,
                                  onChanged: (checked) {
                                    setStateDialog(() {
                                      if (checked == true) {
                                        selectedIds.add(song.id);
                                      } else {
                                        selectedIds.remove(song.id);
                                      }
                                    });
                                  },
                                ),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: ArtworkListTile(
                                    songId: song.id,
                                    songPath: song.data,
                                    size: 40,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(
                              song.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            subtitle: Text(
                              _formatArtistWithDuration(song),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: TranslatedText('cancel'),
                ),
                TextButton(
                  onPressed: selectedIds.isEmpty
                      ? null
                      : () async {
                          final toAdd = recents.where(
                            (s) => selectedIds.contains(s.id),
                          );
                          for (final song in toAdd) {
                            await PlaylistsDB().addSongToPlaylist(
                              _selectedPlaylist!['id'],
                              song,
                            );
                          }
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            await _loadPlaylistSongs(_selectedPlaylist!);

                            // Notificar a otras pantallas que deben actualizar las playlists
                            playlistsShouldReload.value =
                                !playlistsShouldReload.value;
                          }
                        },
                  child: TranslatedText('add'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showDiscoveryInfoDialog() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isAmoled && isDark
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white24, width: 1)
              : BorderSide.none,
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        icon: Icon(
          Icons.auto_awesome_rounded,
          size: 32,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        title: Text(
          LocaleProvider.tr('info'),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          LocaleProvider.tr('discovery_info_desc'),
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
          ),
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const TranslatedText('ok'),
          ),
        ],
      ),
    );
  }

  void _shuffleQuickPick() {
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
    final randomPaths = _randomSongs.map((s) => s.data).toSet();
    final allUsedPaths = {...shortcutPaths, ...randomPaths};

    // Crear una lista combinada con canciones más escuchadas y aleatorias
    final List<SongModel> combinedSongs = [];

    // Agregar canciones más escuchadas que no estén ya en uso
    for (final song in _mostPlayed) {
      if (!allUsedPaths.contains(song.data)) {
        combinedSongs.add(song);
        allUsedPaths.add(song.data);
      }
    }

    // Agregar canciones aleatorias que no estén ya en uso
    for (final song in _randomSongs) {
      if (!allUsedPaths.contains(song.data)) {
        combinedSongs.add(song);
        allUsedPaths.add(song.data);
      }
    }

    // Si no hay suficientes canciones, usar canciones de allSongs
    if (combinedSongs.length < 50 && allSongs.isNotEmpty) {
      final availableSongs = allSongs
          .where((s) => !allUsedPaths.contains(s.data))
          .toList();
      availableSongs.shuffle();

      final neededSongs = 50 - combinedSongs.length;
      combinedSongs.addAll(availableSongs.take(neededSongs));
    }

    // Mezclar todas las canciones
    combinedSongs.shuffle();
    _shuffledQuickPick = combinedSongs;

    // Limpiar cache de selección rápida cuando se actualiza la lista
    // _quickPickWidgetCache.clear(); // Comentado para evitar parpadeos al reordenar
  }

  // Función para agregar 50 canciones aleatorias SOLO al reproductor (no visualmente)
  Future<void> _addRandomSongsToPlayerQueue(
    List<SongModel> currentQueue,
  ) async {
    try {
      final songsIndexDB = SongsIndexDB();

      // Obtener canciones aleatorias frescas de la base de datos
      final randomPaths = await songsIndexDB.getRandomSongs(limit: 50);

      // Convertir rutas a SongModel y filtrar duplicados
      final Set<String> usedPaths = currentQueue.map((s) => s.data).toSet();
      // También excluir canciones que ya están en accesos directos fijos
      final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
      // Y excluir también las canciones más escuchadas
      final mostPlayedPaths = _mostPlayed.map((s) => s.data).toSet();
      usedPaths.addAll(shortcutPaths);
      usedPaths.addAll(mostPlayedPaths);

      final List<SongModel> randomSongsForPlayer = [];

      for (final path in randomPaths) {
        if (!usedPaths.contains(path) && randomSongsForPlayer.length < 50) {
          try {
            final song = allSongs.firstWhere((s) => s.data == path);
            randomSongsForPlayer.add(song);
            usedPaths.add(path);
          } catch (_) {
            // Si no se encuentra en allSongs, intentar obtenerla de la base de datos indexada
            try {
              final songs = await SongsIndexDB().getIndexedSongs();
              final foundSong = songs.firstWhere((s) => s.data == path);
              randomSongsForPlayer.add(foundSong);
              usedPaths.add(path);
            } catch (_) {}
          }
        }
      }

      // Agregar las canciones aleatorias al final de la cola actual del reproductor
      if (randomSongsForPlayer.isNotEmpty) {
        final audioHandler = await _getAudioHandler();
        if (audioHandler != null) {
          // Agregar las canciones aleatorias al final de la cola
          await audioHandler.addSongsToQueueEnd(randomSongsForPlayer);
          // print('✅ Agregadas ${randomSongsForPlayer.length} canciones aleatorias al reproductor');
        }
      } else {
        // print('⚠️ No se encontraron canciones aleatorias para agregar');
      }
    } catch (e) {
      // En caso de error, no hacer nada para no interrumpir la reproducción
      // print('❌ Error agregando canciones aleatorias al reproductor: $e');
    }
  }

  // Función para llenar la selección rápida con canciones aleatorias adicionales
  Future<void> _fillQuickPickWithRandomSongs({bool forceReload = false}) async {
    // Evitar cargas duplicadas a menos que se fuerce la recarga
    if (_randomSongsLoaded && !forceReload) return;

    // Si se fuerza la recarga, resetear la bandera
    if (forceReload) {
      _randomSongsLoaded = false;
    }

    try {
      final songsIndexDB = SongsIndexDB();

      // Obtener canciones aleatorias de la base de datos
      final randomPaths = await songsIndexDB.getRandomSongs(limit: 50);
      // print('🎵 Obtenidas ${randomPaths.length} canciones aleatorias de la DB');

      // Convertir rutas a SongModel y filtrar duplicados
      final Set<String> usedPaths = _shuffledQuickPick
          .map((s) => s.data)
          .toSet();
      final List<SongModel> newRandomSongs = [];

      for (final path in randomPaths) {
        if (!usedPaths.contains(path) && newRandomSongs.length < 50) {
          try {
            final song = allSongs.firstWhere((s) => s.data == path);
            newRandomSongs.add(song);
            usedPaths.add(path);
          } catch (_) {
            // Si no se encuentra en allSongs, intentar obtenerla de la base de datos indexada
            try {
              final songs = await SongsIndexDB().getIndexedSongs();
              final foundSong = songs.firstWhere((s) => s.data == path);
              newRandomSongs.add(foundSong);
              usedPaths.add(path);
            } catch (_) {}
          }
        }
      }

      // print('🎵 Canciones aleatorias convertidas: ${newRandomSongs.length}');

      // Si no se obtuvieron suficientes canciones de la base de datos, usar allSongs como fallback
      if (newRandomSongs.length < 30 && allSongs.isNotEmpty) {
        final availableSongs = allSongs
            .where((s) => !usedPaths.contains(s.data))
            .toList();
        availableSongs.shuffle();

        final neededSongs = 50 - newRandomSongs.length;
        newRandomSongs.addAll(availableSongs.take(neededSongs));
        // print('🎵 Agregadas ${neededSongs} canciones de allSongs como fallback');
      }

      // Actualizar _randomSongs con las nuevas canciones aleatorias
      if (mounted) {
        setState(() {
          _randomSongs = newRandomSongs;
          _randomSongsLoaded = true; // Marcar como cargado
        });
        // print('🎵 Total de canciones aleatorias cargadas: ${_randomSongs.length}');
      }

      // Limpiar cache de selección rápida cuando se actualiza la lista
      // _quickPickWidgetCache.clear(); // Comentado para evitar parpadeos
    } catch (e) {
      // print('❌ Error cargando canciones aleatorias: $e');
      // En caso de error, usar canciones de allSongs como fallback
      if (allSongs.isNotEmpty) {
        final availableSongs = allSongs
            .where(
              (s) => !_shuffledQuickPick.any(
                (existing) => existing.data == s.data,
              ),
            )
            .toList();
        availableSongs.shuffle();

        if (mounted) {
          setState(() {
            _randomSongs = availableSongs.take(50).toList();
            _randomSongsLoaded = true; // Marcar como cargado
          });
          // print('🎵 Usando fallback con ${_randomSongs.length} canciones de allSongs');
        }
      }
    }
  }

  String _formatArtistWithDuration(SongModel song) {
    final artist = (song.displayArtist.trim().isEmpty)
        ? LocaleProvider.tr('unknown_artist')
        : song.displayArtist;

    if (song.duration != null && song.duration! > 0) {
      final duration = Duration(milliseconds: song.duration!);
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');

      String durationString;
      if (hours > 0) {
        durationString =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$seconds';
      } else {
        durationString = '$minutes:$seconds';
      }

      return '$artist • $durationString';
    }

    return artist;
  }

  int? _parseDurationMs(dynamic raw) {
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw > 0) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  String _formatDurationMs(int durationMs) {
    final duration = Duration(milliseconds: durationMs);
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatStreamingArtistWithDuration(_StreamingRecentItem item) {
    final artist = item.artist.trim().isEmpty
        ? LocaleProvider.tr('artist_unknown')
        : item.artist;

    final durationText = item.durationText?.trim();
    if (durationText != null && durationText.isNotEmpty) {
      return '$artist • $durationText';
    }

    final durationMs = item.durationMs;
    if (durationMs != null && durationMs > 0) {
      return '$artist • ${_formatDurationMs(durationMs)}';
    }

    return artist;
  }

  @override
  Widget build(BuildContext context) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Gradiente de arriba a abajo - Solo para AMOLED
    final scaffoldBgColor = Theme.of(context).scaffoldBackgroundColor;
    final alpha = isDark ? 0.2 : 0.1;

    final gradientDecoration = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.blue.withValues(alpha: alpha),
          Colors.purple.withValues(alpha: alpha * 0.6),
          Colors.black.withValues(alpha: alpha * 1.2),
          scaffoldBgColor,
        ],
        stops: const [0.0, 0.3, 0.5, 0.6],
      ),
    );

    // Mostrar pantalla de carga mientras se cargan las bases de datos
    if (_isLoading) {
      return Container(
        decoration: isAmoled ? gradientDecoration : null,
        child: Scaffold(
          backgroundColor: isAmoled ? Colors.transparent : null,
          appBar: AppBar(
            backgroundColor: isAmoled
                ? Colors.transparent
                : Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: Row(
              children: [
                SvgPicture.asset(
                  'assets/icon/icon_foreground.svg',
                  width: 32,
                  height: 32,
                  colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.inverseSurface,
                    BlendMode.srcIn,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "Aura",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Text(
                  "Music",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.auto_awesome_rounded, size: 28),
                tooltip: LocaleProvider.tr('discovery'),
                onPressed: () {
                  setState(() {
                    _showingDiscovery = true;
                    _showingRecents = false;
                    _showingPlaylistSongs = false;
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.history, size: 28),
                tooltip: LocaleProvider.tr('recent_songs'),
                onPressed: _loadRecents,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 28),
                tooltip: LocaleProvider.tr('settings'),
                onPressed: () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          SettingsScreen(
                            setThemeMode: widget.setThemeMode,
                            setColorScheme: widget.setColorScheme,
                          ),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                            const begin = Offset(1.0, 0.0);
                            const end = Offset.zero;
                            const curve = Curves.ease;
                            final tween = Tween(
                              begin: begin,
                              end: end,
                            ).chain(CurveTween(curve: curve));
                            return SlideTransition(
                              position: animation.drive(tween),
                              child: child,
                            );
                          },
                    ),
                  );
                },
              ),
            ],
          ),
          body: Center(child: LoadingIndicator()),
        ),
      );
    }

    final quickPickSongsPerPage = 4;
    final List<_StreamingRecentItem> extendedQuickPick =
        _shuffledStreamingRecentsQuickPick.isNotEmpty
        ? List<_StreamingRecentItem>.from(_shuffledStreamingRecentsQuickPick)
        : (() {
            final fallback = _streamingRecents
                .where((item) => item.videoId?.trim().isNotEmpty ?? false)
                .toList();
            if (fallback.isNotEmpty) {
              fallback.shuffle();
              return fallback;
            }
            if (_quickPickYtFallbackSongs.isNotEmpty) {
              return List<_StreamingRecentItem>.from(_quickPickYtFallbackSongs);
            }
            return const <_StreamingRecentItem>[];
          })();
    final limitedQuickPick = extendedQuickPick.take(20).toList();
    final quickPickPageCount = limitedQuickPick.isEmpty
        ? 0
        : (limitedQuickPick.length / quickPickSongsPerPage).ceil();
    final menuColor = isAmoled
        ? Colors.grey.shade900
        : Theme.of(context).colorScheme.surfaceContainerHigh;

    final scaffold = Scaffold(
      backgroundColor: isAmoled ? Colors.transparent : null,
      appBar: AppBar(
        backgroundColor: isAmoled
            ? Colors.transparent
            : Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: (_showingRecents || _showingPlaylistSongs || _showingDiscovery)
            ? (_isSelectingPlaylistSongs
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: LocaleProvider.tr('cancel_selection'),
                      onPressed: () {
                        setState(() {
                          _isSelectingPlaylistSongs = false;
                          _selectedPlaylistSongIds.clear();
                        });
                      },
                    )
                  : IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                        maxWidth: 40,
                        maxHeight: 40,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark
                              ? Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.06)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondary.withValues(alpha: 0.07),
                        ),
                        child: const Icon(Icons.arrow_back, size: 24),
                      ),
                      onPressed: () {
                        // Limpiar cache de artistas para forzar reconstrucción con contexto correcto
                        _artistWidgetCache.clear();
                        setState(() {
                          _showingRecents = false;
                          _showingPlaylistSongs = false;
                          _showingDiscovery = false;
                        });
                      },
                    ))
            : null,
        title: Row(
          children: [
            Expanded(
              child: _showingRecents
                  ? TranslatedText(
                      'recent',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w500),
                    )
                  : _showingDiscovery
                  ? TranslatedText(
                      'discovery',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w500),
                    )
                  : _showingPlaylistSongs
                  ? (_isSelectingPlaylistSongs
                        ? Text(
                            '${_selectedPlaylistSongIds.length} ${LocaleProvider.tr('selected')}',
                          )
                        : ((_selectedPlaylist?['name'] ?? '').isNotEmpty
                              ? Text(
                                  (_selectedPlaylist?['name'] ?? '').length > 15
                                      ? (_selectedPlaylist?['name'] ?? '')
                                                .substring(0, 15) +
                                            '...'
                                      : (_selectedPlaylist?['name'] ?? ''),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.9),
                                  ),
                                )
                              : TranslatedText(
                                  'playlists',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )))
                  : Row(
                      children: [
                        SvgPicture.asset(
                          'assets/icon/icon_foreground.svg',
                          width: 32,
                          height: 32,
                          colorFilter: ColorFilter.mode(
                            Theme.of(context).colorScheme.inverseSurface,
                            BlendMode.srcIn,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "Aura",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "Music",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
        actions:
            (!_showingRecents && !_showingPlaylistSongs && !_showingDiscovery)
            ? [
                IconButton(
                  icon: const Icon(Icons.auto_awesome_rounded, size: 28),
                  tooltip: LocaleProvider.tr('discovery'),
                  onPressed: () {
                    setState(() {
                      _showingDiscovery = true;
                      _showingRecents = false;
                      _showingPlaylistSongs = false;
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.history, size: 28),
                  tooltip: LocaleProvider.tr('recent_songs'),
                  onPressed: _openRecentsFast,
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 28),
                  tooltip: LocaleProvider.tr('settings'),
                  onPressed: () {
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            SettingsScreen(
                              setThemeMode: widget.setThemeMode,
                              setColorScheme: widget.setColorScheme,
                            ),
                        transitionsBuilder:
                            (context, animation, secondaryAnimation, child) {
                              const begin = Offset(1.0, 0.0);
                              const end = Offset.zero;
                              const curve = Curves.ease;
                              final tween = Tween(
                                begin: begin,
                                end: end,
                              ).chain(CurveTween(curve: curve));
                              return SlideTransition(
                                position: animation.drive(tween),
                                child: child,
                              );
                            },
                      ),
                    );
                  },
                ),
              ]
            : _showingRecents
            ? [
                IconButton(
                  icon: const Icon(
                    Icons.shuffle_rounded,
                    size: 28,
                    weight: 600,
                  ),
                  tooltip: LocaleProvider.tr('shuffle'),
                  onPressed: () {
                    if (_recentSongsSource == RecentSongsSource.local) {
                      final List<SongModel> songsToShow =
                          _searchRecentsController.text.isNotEmpty
                          ? _filteredRecents
                          : _recentSongs;
                      if (songsToShow.isNotEmpty) {
                        final random = (songsToShow.toList()..shuffle()).first;
                        unawaited(_preloadArtworkForSong(random));
                        _playSongAndOpenPlayer(random, songsToShow);
                      }
                      return;
                    }

                    final List<_StreamingRecentItem> streamingToShow =
                        _searchRecentsController.text.isNotEmpty
                        ? _filteredStreamingRecents
                        : _streamingRecents;
                    final playable = streamingToShow
                        .where(
                          (item) => item.videoId?.trim().isNotEmpty ?? false,
                        )
                        .toList();
                    if (playable.isNotEmpty) {
                      final random = (playable.toList()..shuffle()).first;
                      _playStreamingRecent(random);
                    }
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: LocaleProvider.tr('want_more_options'),
                  color: menuColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onSelected: (value) {
                    if (value == 'switch_source') {
                      _toggleRecentsSource();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'switch_source',
                      child: Row(
                        children: [
                          Icon(
                            _recentSongsSource == RecentSongsSource.local
                                ? Icons.cloud_outlined
                                : Icons.music_note_rounded,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _recentSongsSource == RecentSongsSource.local
                                ? LocaleProvider.tr('show_streaming_songs')
                                : LocaleProvider.tr('show_local_songs'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ]
            : _showingDiscovery
            ? [
                IconButton(
                  icon: const Icon(Icons.info_outline, size: 28),
                  tooltip: 'Información',
                  onPressed: _showDiscoveryInfoDialog,
                ),
              ]
            : _showingPlaylistSongs
            ? [
                if (_isSelectingPlaylistSongs) ...[
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: LocaleProvider.tr('remove_from_playlist'),
                    onPressed: _selectedPlaylistSongIds.isEmpty
                        ? null
                        : _removeFromPlaylistMassive,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.favorite_outline_rounded,
                      weight: 600,
                    ),
                    tooltip: LocaleProvider.tr('add_to_favorites'),
                    onPressed: _selectedPlaylistSongIds.isEmpty
                        ? null
                        : _addToFavoritesMassive,
                  ),
                  IconButton(
                    icon: const Icon(Icons.select_all),
                    tooltip: LocaleProvider.tr('select_all'),
                    onPressed: () {
                      final songsToShow =
                          _searchPlaylistController.text.isNotEmpty
                          ? _filteredPlaylistSongs
                          : _playlistSongs;
                      setState(() {
                        if (_selectedPlaylistSongIds.length ==
                            songsToShow.length) {
                          // Si todos están seleccionados, deseleccionar todos
                          _selectedPlaylistSongIds.clear();
                          if (_selectedPlaylistSongIds.isEmpty) {
                            _isSelectingPlaylistSongs = false;
                          }
                        } else {
                          // Seleccionar todos
                          _selectedPlaylistSongIds.addAll(
                            songsToShow.map((s) => s.id),
                          );
                        }
                      });
                    },
                  ),
                ] else ...[
                  IconButton(
                    icon: const Icon(
                      Icons.shuffle_rounded,
                      size: 28,
                      weight: 600,
                    ),
                    tooltip: LocaleProvider.tr('shuffle'),
                    onPressed: () {
                      final List<SongModel> songsToShow =
                          _searchPlaylistController.text.isNotEmpty
                          ? _filteredPlaylistSongs
                          : _playlistSongs;
                      if (songsToShow.isNotEmpty) {
                        final random = (songsToShow.toList()..shuffle()).first;
                        // Precargar la carátula antes de reproducir
                        unawaited(_preloadArtworkForSong(random));
                        _playSongAndOpenPlayer(
                          random,
                          songsToShow,
                          queueSource: _selectedPlaylist?['name'] ?? '',
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, size: 28),
                    tooltip: LocaleProvider.tr('add_from_recents'),
                    onPressed: _showAddFromRecentsToCurrentPlaylistDialog,
                  ),
                  PopupMenuButton<OrdenCancionesPlaylist>(
                    icon: const Icon(Icons.sort, size: 28),
                    tooltip: LocaleProvider.tr('filters'),
                    onSelected: (orden) {
                      setState(() {
                        _ordenCancionesPlaylist = orden;
                        _ordenarCancionesPlaylist();
                      });
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: OrdenCancionesPlaylist.normal,
                        child: TranslatedText('last_added'),
                      ),
                      PopupMenuItem(
                        value: OrdenCancionesPlaylist.ultimoAgregado,
                        child: TranslatedText('invert_order'),
                      ),
                      PopupMenuItem(
                        value: OrdenCancionesPlaylist.alfabetico,
                        child: TranslatedText('alphabetical_az'),
                      ),
                      PopupMenuItem(
                        value: OrdenCancionesPlaylist.invertido,
                        child: TranslatedText('alphabetical_za'),
                      ),
                    ],
                  ),
                ],
              ]
            : null,
        bottom: (_showingRecents || _showingPlaylistSongs)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Builder(
                    builder: (context) {
                      final colorScheme = colorSchemeNotifier.value;
                      final isAmoled = colorScheme == AppColorScheme.amoled;
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final barColor = isAmoled
                          ? Colors.white.withAlpha(20)
                          : isDark
                          ? Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06)
                          : Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.07);

                      return TextField(
                        controller: _showingRecents
                            ? _searchRecentsController
                            : _searchPlaylistController,
                        focusNode: _showingRecents
                            ? _searchRecentsFocus
                            : _searchPlaylistFocus,
                        onChanged: (_) => _showingRecents
                            ? _onSearchRecentsChanged()
                            : _onSearchPlaylistChanged(),
                        cursorColor: Theme.of(context).colorScheme.primary,
                        decoration: InputDecoration(
                          hintText: LocaleProvider.tr(
                            'search_by_title_or_artist',
                          ),
                          hintStyle: TextStyle(
                            color: isAmoled
                                ? Colors.white.withAlpha(160)
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                            fontSize: 15,
                          ),
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon:
                              (_showingRecents
                                  ? _searchRecentsController.text.isNotEmpty
                                  : _searchPlaylistController.text.isNotEmpty)
                              ? IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    if (_showingRecents) {
                                      _searchRecentsController.clear();
                                      _onSearchRecentsChanged();
                                      setState(() {});
                                    } else {
                                      _searchPlaylistController.clear();
                                      _onSearchPlaylistChanged();
                                      setState(() {});
                                    }
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: barColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              )
            : null,
      ),
      body: ValueListenableBuilder<MediaItem?>(
        valueListenable: _currentMediaItemNotifier,
        builder: (context, currentMediaItem, child) {
          final bottomPadding = MediaQuery.of(context).padding.bottom;
          final space =
              (currentMediaItem != null ? 100.0 : 0.0) + bottomPadding;

          if (_showingDiscovery) {
            return const HomeDiscoveryScreen();
          }

          if (_showingRecents) {
            if (_recentSongsSource == RecentSongsSource.streaming) {
              final List<_StreamingRecentItem> streamingToShow =
                  _searchRecentsController.text.isNotEmpty
                  ? _filteredStreamingRecents
                  : _streamingRecents;
              if (streamingToShow.isEmpty) {
                final isDark = Theme.of(context).brightness == Brightness.dark;
                return ExpressiveRefreshIndicator(
                  onRefresh: () async {
                    await _loadRecents();
                  },
                  color: Theme.of(context).colorScheme.primary,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(
                      height: MediaQuery.of(context).size.height - 200,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDark
                                    ? Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.04)
                                    : Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.05),
                              ),
                              child: Icon(
                                Icons.cloud_outlined,
                                size: 50,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TranslatedText(
                              _searchRecentsController.text.isNotEmpty
                                  ? 'no_results'
                                  : 'no_streaming_songs',
                              style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }
              final colorScheme = colorSchemeNotifier.value;
              final isAmoled = colorScheme == AppColorScheme.amoled;
              final isDark = Theme.of(context).brightness == Brightness.dark;
              final cardColor = isAmoled
                  ? Colors.white.withAlpha(20)
                  : isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.06)
                  : Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.07);
              final isAmoledTheme =
                  colorSchemeNotifier.value == AppColorScheme.amoled;

              return ExpressiveRefreshIndicator(
                onRefresh: () async {
                  await _loadRecents();
                },
                color: Theme.of(context).colorScheme.primary,
                child: RawScrollbar(
                  controller: _recentsScrollController,
                  thumbColor: Theme.of(context).colorScheme.primary,
                  thickness: 6.0,
                  radius: const Radius.circular(8),
                  interactive: true,
                  padding: EdgeInsets.only(bottom: space),
                  child: ListView.builder(
                    controller: _recentsScrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      left: 16.0,
                      right: 16.0,
                      top: 8.0,
                      bottom: space,
                    ),
                    itemCount: streamingToShow.length,
                    itemBuilder: (context, index) {
                      final item = streamingToShow[index];
                      final itemVideoId = item.videoId?.trim();
                      final currentVideoId = currentMediaItem
                          ?.extras?['videoId']
                          ?.toString()
                          .trim();
                      final isCurrent =
                          (itemVideoId != null &&
                              itemVideoId.isNotEmpty &&
                              currentVideoId == itemVideoId) ||
                          currentMediaItem?.id == item.rawPath ||
                          (itemVideoId != null &&
                              currentMediaItem?.id == 'yt:$itemVideoId');

                      final bool isFirst = index == 0;
                      final bool isLast = index == streamingToShow.length - 1;
                      final bool isOnly = streamingToShow.length == 1;
                      BorderRadius borderRadius;
                      if (isOnly) {
                        borderRadius = BorderRadius.circular(20);
                      } else if (isFirst) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(20),
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        );
                      } else if (isLast) {
                        borderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20),
                        );
                      } else {
                        borderRadius = BorderRadius.circular(4);
                      }

                      final artworkSources = _streamingArtworkSources(item);
                      final artworkFallbackBackground = Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh;
                      final artworkFallbackIconColor = Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant;

                      Widget listTileWidget;
                      if (isCurrent) {
                        listTileWidget = ValueListenableBuilder<bool>(
                          valueListenable: _isPlayingNotifier,
                          builder: (context, playing, child) {
                            return ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: borderRadius,
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: _StreamingArtwork(
                                    sources: artworkSources,
                                    backgroundColor: artworkFallbackBackground,
                                    iconColor: artworkFallbackIconColor,
                                  ),
                                ),
                              ),
                              title: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: MiniMusicVisualizer(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 4,
                                      height: 15,
                                      radius: 4,
                                      animate: playing,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: isAmoledTheme
                                                ? Colors.white
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                _formatStreamingArtistWithDuration(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: isAmoled
                                    ? TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.8,
                                        ),
                                      )
                                    : null,
                              ),
                              trailing: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withAlpha(20),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  icon: Icon(
                                    playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    grade: 200,
                                    fill: 1,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  onPressed: () {
                                    playing
                                        ? audioHandler.myHandler?.pause()
                                        : audioHandler.myHandler?.play();
                                  },
                                ),
                              ),
                              selected: true,
                              selectedTileColor: Colors.transparent,
                              onTap: () async {
                                if (playing) {
                                  await audioHandler.myHandler?.pause();
                                } else {
                                  await audioHandler.myHandler?.play();
                                }
                              },
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (context) => SafeArea(
                                    child: ListTile(
                                      leading: const Icon(Icons.delete_outline),
                                      title: const TranslatedText(
                                        'remove_from_recents',
                                      ),
                                      onTap: () async {
                                        Navigator.of(context).pop();
                                        await RecentsDB().removeRecent(
                                          item.rawPath,
                                        );
                                        await _loadRecents();
                                      },
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      } else {
                        listTileWidget = ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: borderRadius,
                          ),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 50,
                              height: 50,
                              child: _StreamingArtwork(
                                sources: artworkSources,
                                backgroundColor: artworkFallbackBackground,
                                iconColor: artworkFallbackIconColor,
                              ),
                            ),
                          ),
                          title: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isCurrent
                                ? Theme.of(
                                    context,
                                  ).textTheme.titleMedium?.copyWith(
                                    color: isAmoledTheme
                                        ? Colors.white
                                        : Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  )
                                : Theme.of(context).textTheme.titleMedium,
                          ),
                          subtitle: Text(
                            _formatStreamingArtistWithDuration(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: isAmoled
                                ? TextStyle(
                                    color: Colors.white.withValues(alpha: 0.8),
                                  )
                                : null,
                          ),
                          trailing: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withAlpha(20),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                grade: 200,
                                fill: 1,
                              ),
                              onPressed: () => _playStreamingRecent(item),
                            ),
                          ),
                          onTap: () => _playStreamingRecent(item),
                          onLongPress: () {
                            showModalBottomSheet(
                              context: context,
                              builder: (context) => SafeArea(
                                child: ListTile(
                                  leading: const Icon(Icons.delete_outline),
                                  title: const TranslatedText(
                                    'remove_from_recents',
                                  ),
                                  onTap: () async {
                                    Navigator.of(context).pop();
                                    await RecentsDB().removeRecent(
                                      item.rawPath,
                                    );
                                    await _loadRecents();
                                  },
                                ),
                              ),
                            );
                          },
                        );
                      }

                      final bool isLastItem =
                          index == streamingToShow.length - 1;
                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: isLastItem ? 0 : 4),
                          child: Card(
                            color: isCurrent
                                ? isAmoledTheme
                                      ? cardColor
                                      : Theme.of(context).colorScheme.primary
                                            .withAlpha(isDark ? 40 : 25)
                                : cardColor,
                            margin: EdgeInsets.zero,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                            ),
                            child: ClipRRect(
                              borderRadius: borderRadius,
                              child: listTileWidget,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            }
            final List<SongModel> songsToShow =
                _searchRecentsController.text.isNotEmpty
                ? _filteredRecents
                : _recentSongs;
            if (songsToShow.isEmpty) {
              final isDark = Theme.of(context).brightness == Brightness.dark;

              return ExpressiveRefreshIndicator(
                onRefresh: () async {
                  await _loadRecents();
                },
                color: Theme.of(context).colorScheme.primary,
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: MediaQuery.of(context).size.height - 200,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.04)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.05),
                            ),
                            child: Icon(
                              Icons.history,
                              size: 50,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TranslatedText(
                            _searchRecentsController.text.isNotEmpty
                                ? 'no_results'
                                : 'no_recent_songs',
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
            final colorScheme = colorSchemeNotifier.value;
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final cardColor = isAmoled
                ? Colors.white.withAlpha(20)
                : isDark
                ? Theme.of(
                    context,
                  ).colorScheme.secondary.withValues(alpha: 0.06)
                : Theme.of(
                    context,
                  ).colorScheme.secondary.withValues(alpha: 0.07);

            return ExpressiveRefreshIndicator(
              onRefresh: () async {
                await _loadRecents();
              },
              color: Theme.of(context).colorScheme.primary,
              child: RawScrollbar(
                controller: _recentsScrollController,
                thumbColor: Theme.of(context).colorScheme.primary,
                thickness: 6.0,
                radius: const Radius.circular(8),
                interactive: true,
                padding: EdgeInsets.only(bottom: space),
                child: ListView.builder(
                  controller: _recentsScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    left: 16.0,
                    right: 16.0,
                    top: 8.0,
                    bottom: space,
                  ),
                  itemCount: songsToShow.length,
                  itemBuilder: (context, index) {
                    final song = songsToShow[index];
                    final path = song.data;
                    final isCurrent =
                        (currentMediaItem?.id != null &&
                        path.isNotEmpty &&
                        (currentMediaItem!.id == path ||
                            currentMediaItem.extras?['data'] == path));
                    final isAmoledTheme =
                        colorSchemeNotifier.value == AppColorScheme.amoled;

                    // Determinar el borderRadius según la posición
                    final bool isFirst = index == 0;
                    final bool isLast = index == songsToShow.length - 1;
                    final bool isOnly = songsToShow.length == 1;

                    BorderRadius borderRadius;
                    if (isOnly) {
                      borderRadius = BorderRadius.circular(20);
                    } else if (isFirst) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      );
                    } else if (isLast) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                      );
                    } else {
                      borderRadius = BorderRadius.circular(4);
                    }

                    Widget listTileWidget;

                    // Solo usar ValueListenableBuilder para la canción actual
                    if (isCurrent) {
                      listTileWidget = ValueListenableBuilder<bool>(
                        valueListenable: _isPlayingNotifier,
                        builder: (context, playing, child) {
                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                            ),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: ArtworkListTile(
                                songId: song.id,
                                songPath: song.data,
                                size: 50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            title: Row(
                              children: [
                                if (isCurrent)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: MiniMusicVisualizer(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      width: 4,
                                      height: 15,
                                      radius: 4,
                                      animate: playing ? true : false,
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    song.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: isCurrent
                                        ? Theme.of(
                                            context,
                                          ).textTheme.titleMedium?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: isAmoledTheme
                                                ? Colors.white
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                          )
                                        : Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              _formatArtistWithDuration(song),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withAlpha(20),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: Icon(
                                  isCurrent && playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  grade: 200,
                                  fill: 1,
                                  color: isCurrent
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                onPressed: () {
                                  if (isCurrent) {
                                    playing
                                        ? audioHandler.myHandler?.pause()
                                        : audioHandler.myHandler?.play();
                                  } else {
                                    unawaited(_preloadArtworkForSong(song));
                                    _playSongAndOpenPlayer(song, songsToShow);
                                  }
                                },
                              ),
                            ),
                            selected: isCurrent,
                            selectedTileColor: Colors.transparent,
                            onTap: () async {
                              // Precargar la carátula antes de reproducir
                              unawaited(_preloadArtworkForSong(song));
                              if (!mounted) return;
                              await _playSongAndOpenPlayer(song, songsToShow);
                            },
                            onLongPress: () {
                              showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                builder: (context) => SafeArea(
                                  child: SingleChildScrollView(
                                    child: FutureBuilder<bool>(
                                      future: FavoritesDB().isFavorite(
                                        song.data,
                                      ),
                                      builder: (context, snapshot) {
                                        final isFav = snapshot.data ?? false;
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Encabezado con información de la canción
                                            Container(
                                              padding: const EdgeInsets.all(16),
                                              child: Row(
                                                children: [
                                                  // Carátula de la canción
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                    child: SizedBox(
                                                      width: 60,
                                                      height: 60,
                                                      child: _buildModalArtwork(
                                                        song,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 16),
                                                  // Título y artista
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Text(
                                                          song.displayTitle,
                                                          maxLines: 1,
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        const SizedBox(
                                                          height: 4,
                                                        ),
                                                        Text(
                                                          song.displayArtist,
                                                          style: TextStyle(
                                                            fontSize: 14,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  // Botón de búsqueda para abrir opciones
                                                  InkWell(
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await _showSearchOptions(
                                                        song,
                                                      );
                                                    },
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 16,
                                                            vertical: 8,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color:
                                                            Theme.of(
                                                                  context,
                                                                ).brightness ==
                                                                Brightness.dark
                                                            ? Theme.of(context)
                                                                  .colorScheme
                                                                  .primary
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .onPrimaryContainer
                                                                  .withValues(
                                                                    alpha: 0.7,
                                                                  ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              12,
                                                            ),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                            Icons.search,
                                                            size: 20,
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    ).brightness ==
                                                                    Brightness
                                                                        .dark
                                                                ? Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onPrimary
                                                                : Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .surfaceContainer,
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          TranslatedText(
                                                            'search',
                                                            style: TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              fontSize: 14,
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      ).brightness ==
                                                                      Brightness
                                                                          .dark
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onPrimary
                                                                  : Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .surfaceContainer,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.queue_music,
                                              ),
                                              title: TranslatedText(
                                                'add_to_queue',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await audioHandler.myHandler
                                                    ?.addSongsToQueueEnd([
                                                      song,
                                                    ]);
                                              },
                                            ),
                                            ListTile(
                                              leading: Icon(
                                                isFav
                                                    ? Icons.delete_outline
                                                    : Icons.favorite_border,
                                              ),
                                              title: TranslatedText(
                                                isFav
                                                    ? 'remove_from_favorites'
                                                    : 'add_to_favorites',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                if (isFav) {
                                                  await FavoritesDB()
                                                      .removeFavorite(
                                                        song.data,
                                                      );
                                                  favoritesShouldReload.value =
                                                      !favoritesShouldReload
                                                          .value;
                                                } else {
                                                  await _addToFavorites(song);
                                                }
                                              },
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              title: TranslatedText(
                                                'remove_from_recents',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await RecentsDB().removeRecent(
                                                  song.data,
                                                );
                                                await _loadRecents();
                                              },
                                            ),
                                            if (song.displayArtist
                                                .trim()
                                                .trim()
                                                .isNotEmpty)
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.person_outline,
                                                ),
                                                title: const TranslatedText(
                                                  'go_to_artist',
                                                ),
                                                onTap: () {
                                                  Navigator.of(context).pop();
                                                  final name = song
                                                      .displayArtist
                                                      .trim()
                                                      .trim();
                                                  if (name.isEmpty) {
                                                    return;
                                                  }
                                                  Navigator.of(context).push(
                                                    PageRouteBuilder(
                                                      pageBuilder:
                                                          (
                                                            context,
                                                            animation,
                                                            secondaryAnimation,
                                                          ) => ArtistScreen(
                                                            artistName: name,
                                                          ),
                                                      transitionsBuilder:
                                                          (
                                                            context,
                                                            animation,
                                                            secondaryAnimation,
                                                            child,
                                                          ) {
                                                            const begin =
                                                                Offset(
                                                                  1.0,
                                                                  0.0,
                                                                );
                                                            const end =
                                                                Offset.zero;
                                                            const curve =
                                                                Curves.ease;
                                                            final tween =
                                                                Tween(
                                                                  begin: begin,
                                                                  end: end,
                                                                ).chain(
                                                                  CurveTween(
                                                                    curve:
                                                                        curve,
                                                                  ),
                                                                );
                                                            return SlideTransition(
                                                              position:
                                                                  animation
                                                                      .drive(
                                                                        tween,
                                                                      ),
                                                              child: child,
                                                            );
                                                          },
                                                    ),
                                                  );
                                                },
                                              ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.info_outline,
                                              ),
                                              title: TranslatedText(
                                                'song_info',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await SongInfoDialog.showFromSong(
                                                  context,
                                                  song,
                                                  colorSchemeNotifier,
                                                );
                                              },
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    } else {
                      // Para canciones que no están reproduciéndose, no usar StreamBuilder
                      listTileWidget = ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: borderRadius,
                        ),
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: ArtworkListTile(
                            songId: song.id,
                            songPath: song.data,
                            size: 50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        title: Row(
                          children: [
                            if (isCurrent)
                              Padding(
                                padding: const EdgeInsets.only(right: 8.0),
                                child: MiniMusicVisualizer(
                                  color: Theme.of(context).colorScheme.primary,
                                  width: 4,
                                  height: 15,
                                  radius: 4,
                                  animate: false, // No playing
                                ),
                              ),
                            Expanded(
                              child: Text(
                                song.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: isCurrent
                                    ? Theme.of(
                                        context,
                                      ).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: isAmoledTheme
                                            ? Colors.white
                                            : Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                      )
                                    : Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          _formatArtistWithDuration(song),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isAmoledTheme
                              ? TextStyle(
                                  color: Colors.white.withValues(alpha: 0.8),
                                )
                              : null,
                        ),
                        trailing: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primary.withAlpha(20),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: const Icon(
                              Icons.play_arrow_rounded,
                              grade: 200,
                              fill: 1,
                            ),
                            onPressed: () {
                              // Precargar la carátula antes de reproducir
                              unawaited(_preloadArtworkForSong(song));
                              _playSongAndOpenPlayer(song, songsToShow);
                            },
                          ),
                        ),
                        selected: isCurrent,
                        selectedTileColor: isAmoledTheme
                            ? Colors.white.withValues(alpha: 0.1)
                            : Theme.of(context).colorScheme.primaryContainer,
                        onTap: () async {
                          // Precargar la carátula antes de reproducir
                          unawaited(_preloadArtworkForSong(song));
                          if (!mounted) return;
                          await _playSongAndOpenPlayer(song, songsToShow);
                        },
                        onLongPress: () {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            builder: (context) => SafeArea(
                              child: SingleChildScrollView(
                                child: FutureBuilder<bool>(
                                  future: FavoritesDB().isFavorite(song.data),
                                  builder: (context, snapshot) {
                                    final isFav = snapshot.data ?? false;
                                    return Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // Encabezado con información de la canción
                                        Container(
                                          padding: const EdgeInsets.all(16),
                                          child: Row(
                                            children: [
                                              // Carátula de la canción
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: SizedBox(
                                                  width: 60,
                                                  height: 60,
                                                  child: _buildModalArtwork(
                                                    song,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              // Título y artista
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      song.displayTitle,
                                                      maxLines: 1,
                                                      style: Theme.of(
                                                        context,
                                                      ).textTheme.titleMedium,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      song.displayArtist,
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        color: isAmoled
                                                            ? Colors.white
                                                                  .withValues(
                                                                    alpha: 0.85,
                                                                  )
                                                            : null,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              // Botón de búsqueda para abrir opciones
                                              InkWell(
                                                onTap: () async {
                                                  Navigator.of(context).pop();
                                                  await _showSearchOptions(
                                                    song,
                                                  );
                                                },
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 8,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        Theme.of(
                                                              context,
                                                            ).brightness ==
                                                            Brightness.dark
                                                        ? Theme.of(
                                                            context,
                                                          ).colorScheme.primary
                                                        : Theme.of(context)
                                                              .colorScheme
                                                              .onPrimaryContainer
                                                              .withValues(
                                                                alpha: 0.7,
                                                              ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons.search,
                                                        size: 20,
                                                        color:
                                                            Theme.of(
                                                                  context,
                                                                ).brightness ==
                                                                Brightness.dark
                                                            ? Theme.of(context)
                                                                  .colorScheme
                                                                  .onPrimary
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .surfaceContainer,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      TranslatedText(
                                                        'search',
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          fontSize: 14,
                                                          color:
                                                              Theme.of(
                                                                    context,
                                                                  ).brightness ==
                                                                  Brightness
                                                                      .dark
                                                              ? Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onPrimary
                                                              : Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .surfaceContainer,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.queue_music,
                                          ),
                                          title: TranslatedText('add_to_queue'),
                                          onTap: () async {
                                            Navigator.of(context).pop();
                                            await audioHandler.myHandler
                                                ?.addSongsToQueueEnd([song]);
                                          },
                                        ),
                                        ListTile(
                                          leading: Icon(
                                            isFav
                                                ? Icons.delete_outline
                                                : Icons.favorite_border,
                                          ),
                                          title: TranslatedText(
                                            isFav
                                                ? 'remove_from_favorites'
                                                : 'add_to_favorites',
                                          ),
                                          onTap: () async {
                                            Navigator.of(context).pop();
                                            if (isFav) {
                                              await FavoritesDB()
                                                  .removeFavorite(song.data);
                                              favoritesShouldReload.value =
                                                  !favoritesShouldReload.value;
                                            } else {
                                              await _addToFavorites(song);
                                            }
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          title: TranslatedText(
                                            'remove_from_recents',
                                          ),
                                          onTap: () async {
                                            Navigator.of(context).pop();
                                            await RecentsDB().removeRecent(
                                              song.data,
                                            );
                                            await _loadRecents();
                                          },
                                        ),
                                        if (song.displayArtist
                                            .trim()
                                            .trim()
                                            .isNotEmpty)
                                          ListTile(
                                            leading: const Icon(
                                              Icons.person_outline,
                                            ),
                                            title: const TranslatedText(
                                              'go_to_artist',
                                            ),
                                            onTap: () {
                                              Navigator.of(context).pop();
                                              final name = song.displayArtist
                                                  .trim()
                                                  .trim();
                                              if (name.isEmpty) {
                                                return;
                                              }
                                              Navigator.of(context).push(
                                                PageRouteBuilder(
                                                  pageBuilder:
                                                      (
                                                        context,
                                                        animation,
                                                        secondaryAnimation,
                                                      ) => ArtistScreen(
                                                        artistName: name,
                                                      ),
                                                  transitionsBuilder:
                                                      (
                                                        context,
                                                        animation,
                                                        secondaryAnimation,
                                                        child,
                                                      ) {
                                                        const begin = Offset(
                                                          1.0,
                                                          0.0,
                                                        );
                                                        const end = Offset.zero;
                                                        const curve =
                                                            Curves.ease;
                                                        final tween =
                                                            Tween(
                                                              begin: begin,
                                                              end: end,
                                                            ).chain(
                                                              CurveTween(
                                                                curve: curve,
                                                              ),
                                                            );
                                                        return SlideTransition(
                                                          position: animation
                                                              .drive(tween),
                                                          child: child,
                                                        );
                                                      },
                                                ),
                                              );
                                            },
                                          ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.info_outline,
                                          ),
                                          title: TranslatedText('song_info'),
                                          onTap: () async {
                                            Navigator.of(context).pop();
                                            await SongInfoDialog.showFromSong(
                                              context,
                                              song,
                                              colorSchemeNotifier,
                                            );
                                          },
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    }

                    // Determinar si es el último para el padding
                    final bool isLastItem = index == songsToShow.length - 1;

                    return RepaintBoundary(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: isLastItem ? 0 : 4),
                        child: Card(
                          color: isCurrent
                              ? isAmoledTheme
                                    ? cardColor
                                    : Theme.of(context).colorScheme.primary
                                          .withAlpha(isDark ? 40 : 25)
                              : cardColor,
                          margin: EdgeInsets.zero,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: borderRadius,
                          ),
                          child: ClipRRect(
                            borderRadius: borderRadius,
                            child: listTileWidget,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          }

          return _showingPlaylistSongs
              ? ExpressiveRefreshIndicator(
                  onRefresh: _refreshPlaylistSongs,
                  color: Theme.of(context).colorScheme.primary,
                  child: Builder(
                    builder: (context) {
                      final List<SongModel> songsToShow =
                          _searchPlaylistController.text.isNotEmpty
                          ? _filteredPlaylistSongs
                          : _playlistSongs;
                      if (songsToShow.isEmpty) {
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;

                        return SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: SizedBox(
                            height: MediaQuery.of(context).size.height - 200,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 80,
                                    height: 80,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isDark
                                          ? Theme.of(context)
                                                .colorScheme
                                                .secondary
                                                .withValues(alpha: 0.04)
                                          : Theme.of(context)
                                                .colorScheme
                                                .secondary
                                                .withValues(alpha: 0.05),
                                    ),
                                    child: Icon(
                                      Icons.playlist_remove_outlined,
                                      size: 50,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.7),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TranslatedText(
                                    _searchPlaylistController.text.isNotEmpty
                                        ? 'no_results'
                                        : 'no_songs_in_playlist',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }
                      final colorScheme = colorSchemeNotifier.value;
                      final isAmoled = colorScheme == AppColorScheme.amoled;
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final cardColor = isAmoled
                          ? Colors.white.withAlpha(20)
                          : isDark
                          ? Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06)
                          : Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.07);

                      return RawScrollbar(
                        controller: _playlistSongsScrollController,
                        thumbColor: Theme.of(context).colorScheme.primary,
                        thickness: 6.0,
                        radius: const Radius.circular(8),
                        interactive: true,
                        padding: EdgeInsets.only(bottom: space),
                        child: ListView.builder(
                          controller: _playlistSongsScrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.only(
                            left: 16.0,
                            right: 16.0,
                            top: 8.0,
                            bottom: space,
                          ),
                          itemCount: songsToShow.length,
                          itemBuilder: (context, index) {
                            final song = songsToShow[index];
                            final path = song.data;
                            final isCurrent =
                                (currentMediaItem?.id != null &&
                                path.isNotEmpty &&
                                (currentMediaItem!.id == path ||
                                    currentMediaItem.extras?['data'] == path));
                            final isAmoledTheme =
                                colorSchemeNotifier.value ==
                                AppColorScheme.amoled;

                            // Determinar el borderRadius según la posición
                            final bool isFirst = index == 0;
                            final bool isLast = index == songsToShow.length - 1;
                            final bool isOnly = songsToShow.length == 1;

                            BorderRadius borderRadius;
                            if (isOnly) {
                              borderRadius = BorderRadius.circular(20);
                            } else if (isFirst) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(20),
                                topRight: Radius.circular(20),
                                bottomLeft: Radius.circular(4),
                                bottomRight: Radius.circular(4),
                              );
                            } else if (isLast) {
                              borderRadius = const BorderRadius.only(
                                topLeft: Radius.circular(4),
                                topRight: Radius.circular(4),
                                bottomLeft: Radius.circular(20),
                                bottomRight: Radius.circular(20),
                              );
                            } else {
                              borderRadius = BorderRadius.circular(4);
                            }

                            Widget listTileWidget;
                            // Solo usar ValueListenableBuilder para la canción actual
                            if (isCurrent) {
                              listTileWidget = ValueListenableBuilder<bool>(
                                valueListenable: _isPlayingNotifier,
                                builder: (context, playing, child) {
                                  return ListTile(
                                    shape: RoundedRectangleBorder(
                                      borderRadius: borderRadius,
                                    ),
                                    onTap: () async {
                                      if (_isSelectingPlaylistSongs) {
                                        _onPlaylistSongSelected(song);
                                      } else {
                                        if (!mounted) return;
                                        await _playSongAndOpenPlayer(
                                          song,
                                          songsToShow,
                                        );
                                      }
                                    },
                                    onLongPress: () async {
                                      if (_isSelectingPlaylistSongs) {
                                        setState(() {
                                          if (_selectedPlaylistSongIds.contains(
                                            song.id,
                                          )) {
                                            _selectedPlaylistSongIds.remove(
                                              song.id,
                                            );
                                            if (_selectedPlaylistSongIds
                                                .isEmpty) {
                                              _isSelectingPlaylistSongs = false;
                                            }
                                          } else {
                                            _selectedPlaylistSongIds.add(
                                              song.id,
                                            );
                                          }
                                        });
                                      } else {
                                        final isFav = await FavoritesDB()
                                            .isFavorite(song.data);
                                        if (!context.mounted) return;
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          builder: (context) => SafeArea(
                                            child: SingleChildScrollView(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  // Encabezado con información de la canción
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.all(
                                                          16,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        // Carátula de la canción
                                                        ClipRRect(
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
                                                          child: SizedBox(
                                                            width: 60,
                                                            height: 60,
                                                            child:
                                                                _buildModalArtwork(
                                                                  song,
                                                                ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 16,
                                                        ),
                                                        // Título y artista
                                                        Expanded(
                                                          child: Column(
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Text(
                                                                song.displayTitle,
                                                                maxLines: 1,
                                                                style: Theme.of(
                                                                  context,
                                                                ).textTheme.titleMedium,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                              const SizedBox(
                                                                height: 4,
                                                              ),
                                                              Text(
                                                                song.displayArtist,
                                                                style:
                                                                    TextStyle(
                                                                      fontSize:
                                                                          14,
                                                                    ),
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        // Botón de búsqueda para abrir opciones
                                                        InkWell(
                                                          onTap: () async {
                                                            Navigator.of(
                                                              context,
                                                            ).pop();
                                                            await _showSearchOptions(
                                                              song,
                                                            );
                                                          },
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                12,
                                                              ),
                                                          child: Container(
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal:
                                                                      16,
                                                                  vertical: 8,
                                                                ),
                                                            decoration: BoxDecoration(
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      ).brightness ==
                                                                      Brightness
                                                                          .dark
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .primary
                                                                  : Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onPrimaryContainer
                                                                        .withValues(
                                                                          alpha:
                                                                              0.7,
                                                                        ),
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    12,
                                                                  ),
                                                            ),
                                                            child: Row(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                Icon(
                                                                  Icons.search,
                                                                  size: 20,
                                                                  color:
                                                                      Theme.of(
                                                                            context,
                                                                          ).brightness ==
                                                                          Brightness
                                                                              .dark
                                                                      ? Theme.of(
                                                                          context,
                                                                        ).colorScheme.onPrimary
                                                                      : Theme.of(
                                                                          context,
                                                                        ).colorScheme.surfaceContainer,
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                TranslatedText(
                                                                  'search',
                                                                  style: TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                    fontSize:
                                                                        14,
                                                                    color:
                                                                        Theme.of(
                                                                              context,
                                                                            ).brightness ==
                                                                            Brightness.dark
                                                                        ? Theme.of(
                                                                            context,
                                                                          ).colorScheme.onPrimary
                                                                        : Theme.of(
                                                                            context,
                                                                          ).colorScheme.surfaceContainer,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.queue_music,
                                                    ),
                                                    title: TranslatedText(
                                                      'add_to_queue',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await audioHandler
                                                          .myHandler
                                                          ?.addSongsToQueueEnd([
                                                            song,
                                                          ]);
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: Icon(
                                                      isFav
                                                          ? Icons.delete_outline
                                                          : Icons
                                                                .favorite_border,
                                                    ),
                                                    title: TranslatedText(
                                                      isFav
                                                          ? 'remove_from_favorites'
                                                          : 'add_to_favorites',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      if (isFav) {
                                                        await FavoritesDB()
                                                            .removeFavorite(
                                                              song.data,
                                                            );
                                                        favoritesShouldReload
                                                                .value =
                                                            !favoritesShouldReload
                                                                .value;
                                                      } else {
                                                        await FavoritesDB()
                                                            .addFavorite(song);
                                                        favoritesShouldReload
                                                                .value =
                                                            !favoritesShouldReload
                                                                .value;
                                                      }
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.playlist_remove,
                                                    ),
                                                    title: TranslatedText(
                                                      'remove_from_playlist',
                                                    ),
                                                    onTap: () async {
                                                      if (!context.mounted) {
                                                        return;
                                                      }
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await PlaylistsDB()
                                                          .removeSongFromPlaylist(
                                                            _selectedPlaylist!['id'],
                                                            song.data,
                                                          );
                                                      await _loadPlaylistSongs(
                                                        _selectedPlaylist!,
                                                      );
                                                    },
                                                  ),
                                                  if (song.displayArtist
                                                      .trim()
                                                      .trim()
                                                      .isNotEmpty)
                                                    ListTile(
                                                      leading: const Icon(
                                                        Icons.person_outline,
                                                      ),
                                                      title:
                                                          const TranslatedText(
                                                            'go_to_artist',
                                                          ),
                                                      onTap: () {
                                                        Navigator.of(
                                                          context,
                                                        ).pop();
                                                        final name = song
                                                            .displayArtist
                                                            .trim()
                                                            .trim();
                                                        if (name.isEmpty) {
                                                          return;
                                                        }
                                                        Navigator.of(
                                                          context,
                                                        ).push(
                                                          PageRouteBuilder(
                                                            pageBuilder:
                                                                (
                                                                  context,
                                                                  animation,
                                                                  secondaryAnimation,
                                                                ) => ArtistScreen(
                                                                  artistName:
                                                                      name,
                                                                ),
                                                            transitionsBuilder:
                                                                (
                                                                  context,
                                                                  animation,
                                                                  secondaryAnimation,
                                                                  child,
                                                                ) {
                                                                  const begin =
                                                                      Offset(
                                                                        1.0,
                                                                        0.0,
                                                                      );
                                                                  const end =
                                                                      Offset
                                                                          .zero;
                                                                  const curve =
                                                                      Curves
                                                                          .ease;
                                                                  final tween =
                                                                      Tween(
                                                                        begin:
                                                                            begin,
                                                                        end:
                                                                            end,
                                                                      ).chain(
                                                                        CurveTween(
                                                                          curve:
                                                                              curve,
                                                                        ),
                                                                      );
                                                                  return SlideTransition(
                                                                    position: animation
                                                                        .drive(
                                                                          tween,
                                                                        ),
                                                                    child:
                                                                        child,
                                                                  );
                                                                },
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.check_box_outlined,
                                                    ),
                                                    title: TranslatedText(
                                                      'select',
                                                    ),
                                                    onTap: () {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      setState(() {
                                                        _isSelectingPlaylistSongs =
                                                            true;
                                                        _selectedPlaylistSongIds
                                                            .add(song.id);
                                                      });
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.info_outline,
                                                    ),
                                                    title: TranslatedText(
                                                      'song_info',
                                                    ),
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      await SongInfoDialog.showFromSong(
                                                        context,
                                                        song,
                                                        colorSchemeNotifier,
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    leading: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isSelectingPlaylistSongs)
                                          Checkbox(
                                            value: _selectedPlaylistSongIds
                                                .contains(song.id),
                                            onChanged: (checked) {
                                              setState(() {
                                                if (checked == true) {
                                                  _selectedPlaylistSongIds.add(
                                                    song.id,
                                                  );
                                                } else {
                                                  _selectedPlaylistSongIds
                                                      .remove(song.id);
                                                  if (_selectedPlaylistSongIds
                                                      .isEmpty) {
                                                    _isSelectingPlaylistSongs =
                                                        false;
                                                  }
                                                }
                                              });
                                            },
                                          ),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: ArtworkListTile(
                                            songId: song.id,
                                            songPath: song.data,
                                            size: 50,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    title: Row(
                                      children: [
                                        if (isCurrent)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8.0,
                                            ),
                                            child: MiniMusicVisualizer(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              width: 4,
                                              height: 15,
                                              radius: 4,
                                              animate: playing ? true : false,
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            song.displayTitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: isCurrent
                                                ? Theme.of(context)
                                                      .textTheme
                                                      .titleMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: isAmoledTheme
                                                            ? Colors.white
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .primary,
                                                      )
                                                : Theme.of(
                                                    context,
                                                  ).textTheme.titleMedium,
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      _formatArtistWithDuration(song),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      icon: Icon(
                                        isCurrent && playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        grade: 200,
                                        fill: 1,
                                      ),
                                      onPressed: () {
                                        if (isCurrent) {
                                          playing
                                              ? audioHandler.myHandler?.pause()
                                              : audioHandler.myHandler?.play();
                                        } else {
                                          // Precargar la carátula antes de reproducir
                                          unawaited(
                                            _preloadArtworkForSong(song),
                                          );
                                          _playSongAndOpenPlayer(
                                            song,
                                            songsToShow,
                                          );
                                        }
                                      },
                                    ),
                                    selected: isCurrent,
                                    selectedTileColor: isCurrent
                                        ? (isAmoledTheme
                                              ? Colors.transparent
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .primaryContainer
                                                    .withValues(alpha: 0.8))
                                        : null,
                                  );
                                },
                              );
                            } else {
                              // Para canciones que no están reproduciéndose, no usar StreamBuilder
                              final playing =
                                  audioHandler?.playbackState.value.playing ??
                                  false;
                              listTileWidget = ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: borderRadius,
                                ),
                                onTap: () async {
                                  if (_isSelectingPlaylistSongs) {
                                    _onPlaylistSongSelected(song);
                                  } else {
                                    if (!mounted) return;
                                    await _playSongAndOpenPlayer(
                                      song,
                                      songsToShow,
                                    );
                                  }
                                },
                                onLongPress: () async {
                                  if (_isSelectingPlaylistSongs) {
                                    setState(() {
                                      if (_selectedPlaylistSongIds.contains(
                                        song.id,
                                      )) {
                                        _selectedPlaylistSongIds.remove(
                                          song.id,
                                        );
                                        if (_selectedPlaylistSongIds.isEmpty) {
                                          _isSelectingPlaylistSongs = false;
                                        }
                                      } else {
                                        _selectedPlaylistSongIds.add(song.id);
                                      }
                                    });
                                  } else {
                                    final isFav = await FavoritesDB()
                                        .isFavorite(song.data);
                                    if (!context.mounted) return;
                                    showModalBottomSheet(
                                      context: context,
                                      isScrollControlled: true,
                                      builder: (context) => SafeArea(
                                        child: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Encabezado con información de la canción
                                              Container(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                child: Row(
                                                  children: [
                                                    // Carátula de la canción
                                                    ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: SizedBox(
                                                        width: 60,
                                                        height: 60,
                                                        child:
                                                            _buildModalArtwork(
                                                              song,
                                                            ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 16),
                                                    // Título y artista
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            song.displayTitle,
                                                            maxLines: 1,
                                                            style:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          const SizedBox(
                                                            height: 4,
                                                          ),
                                                          Text(
                                                            song.displayArtist,
                                                            style: TextStyle(
                                                              fontSize: 14,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    // Botón de búsqueda para abrir opciones
                                                    InkWell(
                                                      onTap: () async {
                                                        Navigator.of(
                                                          context,
                                                        ).pop();
                                                        await _showSearchOptions(
                                                          song,
                                                        );
                                                      },
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 16,
                                                              vertical: 8,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color:
                                                              Theme.of(
                                                                    context,
                                                                  ).brightness ==
                                                                  Brightness
                                                                      .dark
                                                              ? Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .primary
                                                              : Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onPrimaryContainer
                                                                    .withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                12,
                                                              ),
                                                        ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              Icons.search,
                                                              size: 20,
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      ).brightness ==
                                                                      Brightness
                                                                          .dark
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onPrimary
                                                                  : Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .surfaceContainer,
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            TranslatedText(
                                                              'search',
                                                              style: TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                fontSize: 14,
                                                                color:
                                                                    Theme.of(
                                                                          context,
                                                                        ).brightness ==
                                                                        Brightness
                                                                            .dark
                                                                    ? Theme.of(
                                                                        context,
                                                                      ).colorScheme.onPrimary
                                                                    : Theme.of(
                                                                        context,
                                                                      ).colorScheme.surfaceContainer,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.queue_music,
                                                ),
                                                title: TranslatedText(
                                                  'add_to_queue',
                                                ),
                                                onTap: () async {
                                                  if (!context.mounted) {
                                                    return;
                                                  }
                                                  Navigator.of(context).pop();
                                                  await audioHandler.myHandler
                                                      ?.addSongsToQueueEnd([
                                                        song,
                                                      ]);
                                                },
                                              ),
                                              ListTile(
                                                leading: Icon(
                                                  isFav
                                                      ? Icons.delete_outline
                                                      : Icons
                                                            .favorite_outline_rounded,
                                                  weight: isFav ? null : 600,
                                                ),
                                                title: TranslatedText(
                                                  isFav
                                                      ? 'remove_from_favorites'
                                                      : 'add_to_favorites',
                                                ),
                                                onTap: () async {
                                                  if (!context.mounted) {
                                                    return;
                                                  }
                                                  Navigator.of(context).pop();
                                                  if (isFav) {
                                                    await FavoritesDB()
                                                        .removeFavorite(
                                                          song.data,
                                                        );
                                                    favoritesShouldReload
                                                            .value =
                                                        !favoritesShouldReload
                                                            .value;
                                                  } else {
                                                    await FavoritesDB()
                                                        .addFavorite(song);
                                                    favoritesShouldReload
                                                            .value =
                                                        !favoritesShouldReload
                                                            .value;
                                                  }
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.playlist_remove,
                                                ),
                                                title: TranslatedText(
                                                  'remove_from_playlist',
                                                ),
                                                onTap: () async {
                                                  if (!context.mounted) {
                                                    return;
                                                  }
                                                  Navigator.of(context).pop();
                                                  await PlaylistsDB()
                                                      .removeSongFromPlaylist(
                                                        _selectedPlaylist!['id'],
                                                        song.data,
                                                      );
                                                  await _loadPlaylistSongs(
                                                    _selectedPlaylist!,
                                                  );
                                                },
                                              ),
                                              if (song.displayArtist
                                                  .trim()
                                                  .trim()
                                                  .isNotEmpty)
                                                ListTile(
                                                  leading: const Icon(
                                                    Icons.person_outline,
                                                  ),
                                                  title: const TranslatedText(
                                                    'go_to_artist',
                                                  ),
                                                  onTap: () {
                                                    Navigator.of(context).pop();
                                                    final name = song
                                                        .displayArtist
                                                        .trim()
                                                        .trim();
                                                    if (name.isEmpty) {
                                                      return;
                                                    }
                                                    Navigator.of(context).push(
                                                      PageRouteBuilder(
                                                        pageBuilder:
                                                            (
                                                              context,
                                                              animation,
                                                              secondaryAnimation,
                                                            ) => ArtistScreen(
                                                              artistName: name,
                                                            ),
                                                        transitionsBuilder:
                                                            (
                                                              context,
                                                              animation,
                                                              secondaryAnimation,
                                                              child,
                                                            ) {
                                                              const begin =
                                                                  Offset(
                                                                    1.0,
                                                                    0.0,
                                                                  );
                                                              const end =
                                                                  Offset.zero;
                                                              const curve =
                                                                  Curves.ease;
                                                              final tween =
                                                                  Tween(
                                                                    begin:
                                                                        begin,
                                                                    end: end,
                                                                  ).chain(
                                                                    CurveTween(
                                                                      curve:
                                                                          curve,
                                                                    ),
                                                                  );
                                                              return SlideTransition(
                                                                position:
                                                                    animation
                                                                        .drive(
                                                                          tween,
                                                                        ),
                                                                child: child,
                                                              );
                                                            },
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.check_box_outlined,
                                                ),
                                                title: TranslatedText('select'),
                                                onTap: () {
                                                  Navigator.of(context).pop();
                                                  setState(() {
                                                    _isSelectingPlaylistSongs =
                                                        true;
                                                    _selectedPlaylistSongIds
                                                        .add(song.id);
                                                  });
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(
                                                  Icons.info_outline,
                                                ),
                                                title: TranslatedText(
                                                  'song_info',
                                                ),
                                                onTap: () async {
                                                  Navigator.of(context).pop();
                                                  await SongInfoDialog.showFromSong(
                                                    context,
                                                    song,
                                                    colorSchemeNotifier,
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                },
                                leading: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_isSelectingPlaylistSongs)
                                      Checkbox(
                                        value: _selectedPlaylistSongIds
                                            .contains(song.id),
                                        onChanged: (checked) {
                                          setState(() {
                                            if (checked == true) {
                                              _selectedPlaylistSongIds.add(
                                                song.id,
                                              );
                                            } else {
                                              _selectedPlaylistSongIds.remove(
                                                song.id,
                                              );
                                              if (_selectedPlaylistSongIds
                                                  .isEmpty) {
                                                _isSelectingPlaylistSongs =
                                                    false;
                                              }
                                            }
                                          });
                                        },
                                      ),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: ArtworkListTile(
                                        songId: song.id,
                                        songPath: song.data,
                                        size: 50,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                  ],
                                ),
                                title: Row(
                                  children: [
                                    if (isCurrent)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8.0,
                                        ),
                                        child: MiniMusicVisualizer(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          width: 4,
                                          height: 15,
                                          radius: 4,
                                          animate: playing,
                                        ),
                                      ),
                                    Expanded(
                                      child: Text(
                                        song.displayTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: isCurrent
                                            ? Theme.of(
                                                context,
                                              ).textTheme.titleMedium?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isAmoledTheme
                                                    ? Colors.white
                                                    : Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                              )
                                            : Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  _formatArtistWithDuration(song),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    isCurrent && playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    grade: 200,
                                    fill: 1,
                                  ),
                                  onPressed: () {
                                    if (isCurrent) {
                                      playing
                                          ? audioHandler.myHandler?.pause()
                                          : audioHandler.myHandler?.play();
                                    } else {
                                      // Precargar la carátula antes de reproducir
                                      unawaited(_preloadArtworkForSong(song));
                                      _playSongAndOpenPlayer(song, songsToShow);
                                    }
                                  },
                                ),
                                selected: isCurrent,
                                selectedTileColor: Colors.transparent,
                              );
                            }

                            // Determinar si es el último para el padding
                            final bool isLastItem =
                                index == songsToShow.length - 1;

                            return RepaintBoundary(
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: isLastItem ? 0 : 4,
                                ),
                                child: Card(
                                  color: isCurrent
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primary.withAlpha(
                                          Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? 40
                                              : 25,
                                        )
                                      : cardColor,
                                  margin: EdgeInsets.zero,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: borderRadius,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: borderRadius,
                                    child: listTileWidget,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                )
              : ExpressiveRefreshIndicator(
                  onRefresh: () async {
                    // print('🔄 Iniciando refresh completo...');
                    await _ensureSharedYtFallbackPoolLoaded(forceReload: true);
                    // Actualizar accesos directos y selección rápida
                    await _loadAllSongs();
                    await _loadRecentsData();
                    await _loadMostPlayed();
                    await _loadShortcuts();
                    await _loadArtists(
                      forceRefresh: true,
                    ); // Forzar reindexación de artistas
                    await _fillQuickPickWithRandomSongs(forceReload: true);
                    _initQuickPickPages();
                    // Limpiar cache para forzar reconstrucción
                    _shortcutWidgetCache.clear();
                    _streamingShortcutWidgetCache.clear();
                    _quickPickWidgetCache.clear();
                    // print('🔄 Refresh completado');
                    _artistWidgetCache.clear();
                    setState(() {});
                  },
                  color: Theme.of(context).colorScheme.primary,
                  child: SingleChildScrollView(
                    controller: _homeScrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(bottom: space),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_updateVersion != null &&
                            _updateVersion!.isNotEmpty &&
                            _updateApkUrl != null) ...[
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 4,
                            ),
                            child: Material(
                              color:
                                  colorSchemeNotifier.value ==
                                      AppColorScheme.amoled
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context)
                                        .colorScheme
                                        .secondaryContainer
                                        .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(12),
                              child: ListTile(
                                leading: Icon(
                                  Icons.system_update,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                                title: ValueListenableBuilder<String>(
                                  valueListenable: languageNotifier,
                                  builder: (context, lang, child) {
                                    return Text(
                                      '${LocaleProvider.tr('new_version_available')} $_updateVersion ${LocaleProvider.tr('available')}',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    );
                                  },
                                ),
                                trailing: TextButton(
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: Text(
                                    LocaleProvider.tr('update'),
                                    style: TextStyle(
                                      color:
                                          colorSchemeNotifier.value ==
                                              AppColorScheme.amoled
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.onPrimary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onPrimary,
                                    ),
                                  ),
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      PageRouteBuilder(
                                        pageBuilder:
                                            (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                            ) => const UpdateScreen(),
                                        transitionsBuilder:
                                            (
                                              context,
                                              animation,
                                              secondaryAnimation,
                                              child,
                                            ) {
                                              const begin = Offset(1.0, 0.0);
                                              const end = Offset.zero;
                                              const curve = Curves.ease;
                                              final tween = Tween(
                                                begin: begin,
                                                end: end,
                                              ).chain(CurveTween(curve: curve));
                                              return SlideTransition(
                                                position: animation.drive(
                                                  tween,
                                                ),
                                                child: child,
                                              );
                                            },
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: ValueListenableBuilder<AppColorScheme>(
                            valueListenable: colorSchemeNotifier,
                            builder: (context, colorScheme, _) {
                              final isDark =
                                  Theme.of(context).brightness ==
                                  Brightness.dark;
                              final isAmoled =
                                  colorScheme == AppColorScheme.amoled;
                              final barColor = isAmoled
                                  ? Colors.white.withAlpha(20)
                                  : isDark
                                  ? Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.06)
                                  : Theme.of(context).colorScheme.secondary
                                        .withValues(alpha: 0.07);
                              return Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () {
                                    widget.onTabChange?.call(1);
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          focusYtSearchNotifier.value = true;
                                        });
                                  },
                                  borderRadius: BorderRadius.circular(28),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: barColor,
                                      borderRadius: BorderRadius.circular(28),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.search,
                                          size: 24,
                                          color: isAmoled
                                              ? Colors.white.withAlpha(160)
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 12),
                                        Text(
                                          LocaleProvider.tr(
                                            'search_in_youtube_music',
                                          ),
                                          style: TextStyle(
                                            fontSize: 15,
                                            color: isAmoled
                                                ? Colors.white.withAlpha(160)
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              TranslatedText(
                                'quick_access',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  Icons.play_circle_outline,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                                tooltip: LocaleProvider.tr('play_all'),
                                onPressed: _streamingShortcutSongs.isEmpty
                                    ? null
                                    : () => _playStreamingShortcut(
                                        _streamingShortcutSongs.first,
                                      ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 0),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // Calcular el ancho disponible para cada elemento
                              final availableWidth =
                                  constraints.maxWidth -
                                  16; // Padding horizontal
                              final itemWidth =
                                  (availableWidth - 24) /
                                  3; // 3 columnas con spacing
                              final itemHeight =
                                  itemWidth; // Mantener aspecto cuadrado
                              final gridHeight =
                                  (itemHeight * 2) +
                                  12 +
                                  16; // 2 filas + spacing + padding

                              return SizedBox(
                                height: gridHeight,
                                child: PageView(
                                  controller: _pageController,
                                  onPageChanged: (_) {},
                                  children: List.generate(3, (pageIndex) {
                                    final items = _streamingShortcutSongs
                                        .skip(pageIndex * 6)
                                        .take(6)
                                        .toList();
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      child: GridView.builder(
                                        padding: const EdgeInsets.only(
                                          top: 8,
                                          bottom: 8,
                                        ),
                                        shrinkWrap: true,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        itemCount: 6,
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: 3,
                                              mainAxisSpacing: 12,
                                              crossAxisSpacing: 10,
                                              childAspectRatio:
                                                  itemWidth / itemHeight,
                                            ),
                                        itemBuilder: (context, index) {
                                          if (index < items.length) {
                                            final item = items[index];
                                            return _buildStreamingShortcutWidget(
                                              item,
                                              context,
                                            );
                                          } else {
                                            return Container(
                                              decoration: BoxDecoration(
                                                color: Colors.transparent,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Icon(
                                                Icons.music_note,
                                                color: Colors.transparent,
                                                size:
                                                    itemWidth *
                                                    0.3, // Tamaño del ícono adaptativo
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                    );
                                  }),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: SmoothPageIndicator(
                            controller: _pageController,
                            count: 3,
                            effect: WormEffect(
                              dotHeight: 8,
                              dotWidth: 8,
                              activeDotColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              dotColor: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.24),
                            ),
                          ),
                        ),
                        // Sección de Artistas

                        // Solo mostrar la sección de artistas si hay artistas disponibles
                        if (_artists.isNotEmpty) ...[
                          const SizedBox(height: 32),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                const TranslatedText(
                                  'artists',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 120,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: _artists.length,
                              itemBuilder: (context, index) {
                                final artist = _artists[index];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  child: _buildArtistWidget(artist, context),
                                );
                              },
                            ),
                          ),
                        ],
                        // Solo mostrar la sección de selección rápida si hay canciones disponibles
                        if (limitedQuickPick.isNotEmpty) ...[
                          const SizedBox(height: 32),

                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                TranslatedText(
                                  'quick_pick',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: Icon(
                                    Icons.play_circle_outline,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                  tooltip: LocaleProvider.tr('play_all'),
                                  onPressed: () {
                                    _playStreamingEntry(
                                      item: limitedQuickPick.first,
                                      sourceItems: extendedQuickPick,
                                      queueSource: LocaleProvider.tr(
                                        'quick_pick_songs',
                                      ),
                                      playOnlyTapped: true,
                                      autoStartRadio: true,
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Column(
                            children: [
                              SizedBox(
                                height: 320,
                                child: PageView.builder(
                                  controller: _quickPickPageController,
                                  itemCount: quickPickPageCount,
                                  itemBuilder: (context, pageIndex) {
                                    final songs = limitedQuickPick
                                        .skip(pageIndex * quickPickSongsPerPage)
                                        .take(quickPickSongsPerPage)
                                        .toList();
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 0,
                                      ),
                                      child: ListView.builder(
                                        shrinkWrap: true,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        itemCount: songs.length,
                                        itemBuilder: (context, index) {
                                          final song = songs[index];
                                          return Padding(
                                            padding: EdgeInsets.only(
                                              bottom: index < songs.length - 1
                                                  ? 8.0
                                                  : 0,
                                            ),
                                            // Usar el método optimizado que cachea los widgets
                                            child: _buildQuickPickWidget(
                                              song,
                                              context,
                                              extendedQuickPick,
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 12),
                              // Solo mostrar el indicador si hay más de una página
                              if (quickPickPageCount > 1)
                                SmoothPageIndicator(
                                  controller: _quickPickPageController,
                                  count: quickPickPageCount,
                                  effect: WormEffect(
                                    dotHeight: 8,
                                    dotWidth: 8,
                                    activeDotColor: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    dotColor: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.24),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        /*
                          const SizedBox(height: 32),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                TranslatedText(
                                  'playlists',
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),

                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.refresh,
                                        size: 28,
                                      ),
                                      tooltip: LocaleProvider.tr('reload'),
                                      onPressed: _loadPlaylists,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add, size: 28),
                                      tooltip: LocaleProvider.tr(
                                        'create_new_playlist',
                                      ),
                                      padding: const EdgeInsets.only(left: 8),
                                      onPressed: () async {
                                        final controller =
                                            TextEditingController();
                                        final result = await showDialog<String>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              side: isAmoled && isDark
                                                  ? const BorderSide(
                                                      color: Colors.white,
                                                      width: 1,
                                                    )
                                                  : BorderSide.none,
                                            ),
                                            title: TranslatedText(
                                              'new_playlist',
                                            ),
                                            content: TextField(
                                              controller: controller,
                                              autofocus: true,
                                              decoration: InputDecoration(
                                                labelText: LocaleProvider.tr(
                                                  'playlist_name',
                                                ),
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  context,
                                                ).pop(),
                                                child: TranslatedText(
                                                  'cancel',
                                                ),
                                              ),
                                              TextButton(
                                                onPressed: () {
                                                  Navigator.of(
                                                    context,
                                                  ).pop(
                                                    controller.text.trim(),
                                                  );
                                                },
                                                child: TranslatedText(
                                                  'create',
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (result != null &&
                                            result.isNotEmpty) {
                                          await PlaylistsDB().createPlaylist(
                                            result,
                                          );
                                          await _loadPlaylists();

                                          // Notificar a otras pantallas que deben actualizar las playlists
                                          playlistsShouldReload.value =
                                              !playlistsShouldReload.value;
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            // Aquí mostramos las playlists
                            if (_playlists.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 40,
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 80,
                                        height: 80,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isDark
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.04)
                                              : Theme.of(context)
                                                    .colorScheme
                                                    .secondary
                                                    .withValues(alpha: 0.05),
                                        ),
                                        child: Icon(
                                          Icons.queue_music_outlined,
                                          size: 50,
                                          color: Theme.of(context).colorScheme.onSurface.withValues(
                                            alpha: 0.7,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      TranslatedText(
                                        'no_playlists',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: Theme.of(context).colorScheme.onSurface
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _playlists.length,
                                itemBuilder: (context, index) {
                                  final playlist = _playlists[index];
                                  return Column(
                                    children: [
                                      ListTile(
                                        leading: _buildPlaylistArtworkGrid(
                                          playlist,
                                        ),
                                        title: Text(
                                          playlist['name'],
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: () {
                                          _loadPlaylistSongs(playlist);
                                        },
                                        onLongPress: () async {
                                          showModalBottomSheet(
                                            context: context,
                                            builder: (context) => SafeArea(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.edit,
                                                    ),
                                                    title: TranslatedText(
                                                      'rename_playlist',
                                                    ),
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      final controller =
                                                          TextEditingController(
                                                            text:
                                                                playlist['name'],
                                                          );
                                                      final result = await showDialog<String>(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  16,
                                                                ),
                                                            side:
                                                                isAmoled &&
                                                                    isDark
                                                                ? const BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1,
                                                                  )
                                                                : BorderSide
                                                                      .none,
                                                          ),
                                                          title: TranslatedText(
                                                            'rename_playlist',
                                                          ),
                                                          content: TextField(
                                                            controller:
                                                                controller,
                                                            autofocus: true,
                                                            decoration:
                                                                InputDecoration(
                                                                  labelText:
                                                                      LocaleProvider.tr(
                                                                        'new_name',
                                                                      ),
                                                                ),
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(),
                                                              child:
                                                                  TranslatedText(
                                                                    'cancel',
                                                                  ),
                                                            ),
                                                            TextButton(
                                                              onPressed: () {
                                                                Navigator.of(
                                                                  context,
                                                                ).pop(
                                                                  controller
                                                                      .text
                                                                      .trim(),
                                                                );
                                                              },
                                                              child:
                                                                  TranslatedText(
                                                                    'save',
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                      if (result != null &&
                                                          result.isNotEmpty &&
                                                          result !=
                                                              playlist['name']) {
                                                        await PlaylistsDB()
                                                            .renamePlaylist(
                                                              playlist['id'],
                                                              result,
                                                            );
                                                        await _loadPlaylists();
                                                      }
                                                    },
                                                  ),
                                                  ListTile(
                                                    leading: const Icon(
                                                      Icons.delete_outline,
                                                    ),
                                                    title: TranslatedText(
                                                      'delete_playlist',
                                                    ),
                                                    onTap: () async {
                                                      Navigator.of(
                                                        context,
                                                      ).pop();
                                                      final confirm = await showDialog<bool>(
                                                        context: context,
                                                        builder: (context) => AlertDialog(
                                                          shape: RoundedRectangleBorder(
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  16,
                                                                ),
                                                            side:
                                                                isAmoled &&
                                                                    isDark
                                                                ? const BorderSide(
                                                                    color: Colors
                                                                        .white,
                                                                    width: 1,
                                                                  )
                                                                : BorderSide
                                                                      .none,
                                                          ),
                                                          title: TranslatedText(
                                                            'delete_playlist',
                                                          ),
                                                          content: TranslatedText(
                                                            'delete_playlist_confirm',
                                                          ),
                                                          actions: [
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(false),
                                                              child:
                                                                  TranslatedText(
                                                                    'cancel',
                                                                  ),
                                                            ),
                                                            TextButton(
                                                              onPressed: () =>
                                                                  Navigator.of(
                                                                    context,
                                                                  ).pop(true),
                                                              child:
                                                                  TranslatedText(
                                                                    'delete',
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                      if (confirm == true) {
                                                        await PlaylistsDB()
                                                            .deletePlaylist(
                                                              playlist['id'],
                                                            );
                                                        await _loadPlaylists();
                                                      }
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 20),
                                    ],
                                  );
                                },
                              ),
                          */
                      ],
                    ),
                  ),
                );
        },
      ),
    );
    if (!isAmoled || _showingRecents || _showingDiscovery) return scaffold;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _GradientScrollPainter(
                alphaNotifier: _gradientAlphaNotifier,
                scaffoldBgColor: scaffoldBgColor,
                baseAlpha: alpha,
              ),
            ),
          ),
        ),
        scaffold,
      ],
    );
  }

  /*
  Widget _buildPlaylistArtworkGrid(Map<String, dynamic> playlist) {
    final rawList = playlist['songs'] as List?;
    // Filtra solo rutas válidas (no nulos ni vacíos)
    final filtered = (rawList ?? [])
        .where((e) => e != null && e.toString().isNotEmpty)
        .map((e) => e.toString())
        .toList();

    // Obtén las canciones reales que existen
    final List<SongModel> validSongs = [];
    for (final songPath in filtered) {
      final songIndex = allSongs.indexWhere((s) => s.data == songPath);
      if (songIndex != -1) {
        validSongs.add(allSongs[songIndex]);
      }
    }

    // Crear widget dependiendo del número de canciones
    return SizedBox(
      width: 57,
      height: 57,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildArtworkLayout(validSongs),
      ),
    );
  }
  */

  /*
  Widget _buildArtworkLayout(List<SongModel> songs) {
    switch (songs.length) {
      case 0:
        // Sin canciones: un solo ícono centrado
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Center(
            child: Icon(
              Icons.music_note,
              color: Theme.of(context).colorScheme.onSurface,
              size: 24,
            ),
          ),
        );

      case 1:
        // Una canción: carátula completa
        return ArtworkListTile(
          songId: songs[0].id,
          songPath: songs[0].data,
          width: 57,
          height: 57,
          borderRadius: BorderRadius.zero,
        );

      case 2:
        // Dos canciones: lado a lado
        return Row(
          children: [
            Expanded(
              child: QueryArtworkWidget(
                id: songs[0].id,
                type: ArtworkType.AUDIO,
                artworkHeight: 57,
                artworkWidth: 28.5,
                artworkBorder: BorderRadius.zero,
                nullArtworkWidget: Container(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Icon(
                    Icons.music_note,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 12,
                  ),
                ),
              ),
            ),
            Expanded(
              child: QueryArtworkWidget(
                id: songs[1].id,
                type: ArtworkType.AUDIO,
                artworkHeight: 57,
                artworkWidth: 28.5,
                artworkBorder: BorderRadius.zero,
                nullArtworkWidget: Container(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  child: Icon(
                    Icons.music_note,
                    color: Theme.of(context).colorScheme.onSurface,
                    size: 12,
                  ),
                ),
              ),
            ),
          ],
        );

      case 3:
        // Tres canciones: 2 arriba, 1 abajo centrada
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: QueryArtworkWidget(
                      id: songs[0].id,
                      type: ArtworkType.AUDIO,
                      artworkHeight: 28.5,
                      artworkWidth: 28.5,
                      artworkBorder: BorderRadius.zero,
                      nullArtworkWidget: Container(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: QueryArtworkWidget(
                      id: songs[1].id,
                      type: ArtworkType.AUDIO,
                      artworkHeight: 28.5,
                      artworkWidth: 28.5,
                      artworkBorder: BorderRadius.zero,
                      nullArtworkWidget: Container(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 28.5,
                  height: 28.5,
                  child: QueryArtworkWidget(
                    id: songs[2].id,
                    type: ArtworkType.AUDIO,
                    artworkHeight: 28.5,
                    artworkWidth: 28.5,
                    artworkBorder: BorderRadius.zero,
                    nullArtworkWidget: Container(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Icon(
                        Icons.music_note,
                        color: Theme.of(context).colorScheme.onSurface,
                        size: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

      default:
        // 4 o más canciones: grid 2x2 con las primeras 4
        return GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(4, (index) {
            final song = songs[index];
            return QueryArtworkWidget(
              id: song.id,
              type: ArtworkType.AUDIO,
              artworkHeight: 28.5,
              artworkWidth: 28.5,
              artworkBorder: BorderRadius.zero,
              nullArtworkWidget: Container(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Icon(
                  Icons.music_note,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 12,
                ),
              ),
            );
          }),
        );
    }
  }
  */

  // Función para construir la carátula del modal
  Widget _buildModalArtwork(SongModel song) {
    return ArtworkListTile(
      songId: song.id,
      songPath: song.data,
      size: 60,
      borderRadius: BorderRadius.circular(8),
    );
  }

  // Función para buscar la canción en YouTube
  Future<void> _searchSongOnYouTube(SongModel song) async {
    try {
      final title = song.displayTitle;
      final artist = song.displayArtist;

      // Crear la consulta de búsqueda
      String searchQuery = title;
      if (artist.isNotEmpty) {
        searchQuery = '$artist $title';
      }

      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(searchQuery);
      final youtubeSearchUrl =
          'https://www.youtube.com/results?search_query=$encodedQuery';

      // Intentar abrir YouTube en el navegador o en la app
      final url = Uri.parse(youtubeSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // ignore: use_build_context_synchronously
      }
    } catch (e) {
      // ignore: avoid_print
    }
  }

  // Función para buscar la canción en YouTube Music
  Future<void> _searchSongOnYouTubeMusic(SongModel song) async {
    try {
      final title = song.displayTitle;
      final artist = song.displayArtist;

      // Crear la consulta de búsqueda
      String searchQuery = title;
      if (artist.isNotEmpty) {
        searchQuery = '$artist $title';
      }

      // Codificar la consulta para la URL
      final encodedQuery = Uri.encodeComponent(searchQuery);

      // URL correcta para búsqueda en YouTube Music
      final ytMusicSearchUrl =
          'https://music.youtube.com/search?q=$encodedQuery';

      // Intentar abrir YouTube Music en el navegador o en la app
      final url = Uri.parse(ytMusicSearchUrl);

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // ignore: use_build_context_synchronously
      }
    } catch (e) {
      // ignore: avoid_print
    }
  }

  Future<void> _searchStreamingOnYouTube(_StreamingRecentItem item) async {
    try {
      String searchQuery = item.title.trim();
      final artist = item.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${item.title.trim()}';
      }

      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse(
        'https://www.youtube.com/results?search_query=$encodedQuery',
      );

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _searchStreamingOnYouTubeMusic(_StreamingRecentItem item) async {
    try {
      String searchQuery = item.title.trim();
      final artist = item.artist.trim();
      if (artist.isNotEmpty &&
          artist != LocaleProvider.tr('artist_unknown').trim()) {
        searchQuery = '$artist ${item.title.trim()}';
      }

      final encodedQuery = Uri.encodeComponent(searchQuery);
      final url = Uri.parse('https://music.youtube.com/search?q=$encodedQuery');

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Widget _buildActionOption({
    required BuildContext context,
    required String title,
    required VoidCallback onTap,
    IconData? icon,
    Widget? leading,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              if (leading != null)
                SizedBox(width: 24, height: 24, child: Center(child: leading))
              else if (icon != null)
                Icon(
                  icon,
                  color: Theme.of(context).colorScheme.onPrimary,
                  size: 24,
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Función para mostrar opciones de búsqueda
  Future<void> _showSearchOptions(SongModel song) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'search_song',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'search_options',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildActionOption(
                      context: context,
                      title: 'YouTube',
                      leading: Image.asset(
                        'assets/icon/Youtube_logo.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTube(song);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildActionOption(
                      context: context,
                      title: 'YT Music',
                      leading: Image.asset(
                        'assets/icon/Youtube_Music_icon.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTubeMusic(song);
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
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
  }

  Future<void> _showStreamingSearchOptions(_StreamingRecentItem item) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search_rounded, size: 32),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'search_song',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildActionOption(
                      context: context,
                      title: 'YouTube',
                      leading: Image.asset(
                        'assets/icon/Youtube_logo.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchStreamingOnYouTube(item);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildActionOption(
                      context: context,
                      title: 'YT Music',
                      leading: Image.asset(
                        'assets/icon/Youtube_Music_icon.png',
                        width: 24,
                        height: 24,
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchStreamingOnYouTubeMusic(item);
                      },
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'cancel',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
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
  }
}

class AnimatedTapButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const AnimatedTapButton({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<AnimatedTapButton> createState() => _AnimatedTapButtonState();
}

class _AnimatedTapButtonState extends State<AnimatedTapButton> {
  bool _pressed = false;

  void _handleTapUp(_) async {
    await Future.delayed(const Duration(milliseconds: 70));
    if (mounted) setState(() => _pressed = false);
  }

  void _handleTapCancel() async {
    await Future.delayed(const Duration(milliseconds: 70));
    if (mounted) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedScale(
        scale: _pressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Pinta el gradiente AMOLED. Al pasar [repaint] al super, solo se repinta
/// (paint) cuando cambia el scroll — sin setState ni rebuild.
class _GradientScrollPainter extends CustomPainter {
  _GradientScrollPainter({
    required this.alphaNotifier,
    required this.scaffoldBgColor,
    required this.baseAlpha,
  }) : super(repaint: alphaNotifier);

  final ValueNotifier<double> alphaNotifier;
  final Color scaffoldBgColor;
  final double baseAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final a = baseAlpha * alphaNotifier.value;
    if (a <= 0) return;
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.blue.withValues(alpha: a),
        Colors.purple.withValues(alpha: a * 0.6),
        Colors.black.withValues(alpha: a * 1.2),
        scaffoldBgColor,
      ],
      stops: const [0.0, 0.3, 0.5, 0.6],
    );
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));
  }

  @override
  bool shouldRepaint(covariant _GradientScrollPainter oldDelegate) => false;
}
