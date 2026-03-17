import 'package:flutter/material.dart';
import 'package:android_nav_setting/android_nav_setting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:music/widgets/title_marquee.dart';
import 'package:music/main.dart';
import 'package:share_plus/share_plus.dart';
import 'package:music/widgets/slider.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/dislikes_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/utils/db/download_history_hive.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';
import 'dart:ui' as ui;
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/widgets/song_info_dialog.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/gesture_preferences.dart';
import 'package:music/screens/artist/artist_screen.dart';

import 'package:music/screens/home/equalizer_screen.dart';
import 'package:music/utils/simple_yt_download.dart';
import 'package:like_button/like_button.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/theme_controller.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:music/widgets/sliding_up_panel/sliding_up_panel.dart'
    as standard_panel;
import 'package:music/screens/play/current_playlist_screen.dart';
import 'package:music/screens/play/current_lyrics_screen.dart';
import 'package:audio_session/audio_session.dart';
import 'package:music/utils/yt_search/stream_provider.dart';

enum PanelContent { playlist, lyrics }

final OnAudioQuery _audioQuery = OnAudioQuery();

class _PlaylistStreamingArtwork extends StatefulWidget {
  final List<String> sources;

  const _PlaylistStreamingArtwork({required this.sources});

  @override
  State<_PlaylistStreamingArtwork> createState() =>
      _PlaylistStreamingArtworkState();
}

class _PlaylistStreamingArtworkState extends State<_PlaylistStreamingArtwork> {
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
      child: const Icon(Icons.music_note_rounded, color: Colors.transparent),
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
  final VoidCallback? onClose;
  final ValueChanged<bool>? onPlaylistStateChanged;
  final ValueNotifier<double>? panelPositionNotifier;

  const FullPlayerScreen({
    super.key,
    this.initialMediaItem,
    this.initialArtworkUri,
    this.onClose,
    this.onPlaylistStateChanged,
    this.panelPositionNotifier,
  });

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  bool _showLyrics = false;
  String? _syncedLyrics;
  bool _loadingLyrics = false;
  List<LyricLine> _lyricLines = [];
  int _currentLyricIndex = 0;
  bool _apiUnavailable = false;
  bool _noConnection = false;
  final ScrollController _lyricsScrollController = ScrollController();
  String? _lastMediaItemId;
  Timer? _seekDebounceTimer;
  int? _lastSeekMs;
  DateTime _lastSeekTime = DateTime.fromMillisecondsSinceEpoch(0);
  final int _seekThrottleMs = 300;
  Duration? _lastKnownPosition;

  // Estado para rastrear si la carátula se está cargando
  final ValueNotifier<bool> _artworkLoadingNotifier = ValueNotifier<bool>(
    false,
  );

  // Preferencias de gestos
  bool _disableOpenPlaylistGesture = false;

  bool _disableChangeSongGesture = false;

  // Key para el botón de favoritos
  GlobalKey<LikeButtonState> _likeButtonKey = GlobalKey<LikeButtonState>();
  String? _lastArtworkSongId;
  VoidCallback? _gestureListener;
  Timer? _streamingArtworkDebounceTimer;
  String? _pendingStreamingArtworkSongKey;
  static const Duration _streamingArtworkDebounceDelay = Duration(
    milliseconds: 140,
  );
  Timer? _sourceSwitchTransitionTimer;
  bool _suppressSourceSwitchTransitions = false;
  bool? _lastMediaItemWasStreaming;
  static const Duration _sourceSwitchTransitionSuppression = Duration(
    milliseconds: 420,
  );
  MediaItem? _stabilizedMediaItem;
  Timer? _sourceBounceGuardTimer;
  bool? _sourceBounceTargetIsStreaming;
  static const Duration _sourceBounceGuardDuration = Duration(
    milliseconds: 850,
  );
  final Set<String> _artworkDiskPreloadGuard = <String>{};
  Timer? _precacheNextTimer;

  // Control de indicadores de doble toque
  bool _showDoubleTapIndicators = false;
  bool _showLeftIndicator = false;
  bool _showRightIndicator = false;
  Timer? _hideIndicatorsTimer;
  bool _isGestureNavigation = false;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // Flag para usar initialArtworkUri solo en el primer build
  // bool _usedInitialArtwork = false;
  // Optimizaciones de rendimiento
  late final Future<SharedPreferences> _prefsFuture;
  final ValueNotifier<double?> _dragValueSecondsNotifier =
      ValueNotifier<double?>(null);
  String? _currentSongDataPath;
  double? _dragStartY;
  bool _isCurrentFavorite = false;
  bool _isCurrentDisliked = false;
  // final int _lyricsUpdateCounter = 0;
  final ValueNotifier<int> _lyricsUpdateNotifier = ValueNotifier<int>(0);

  // Cache del widget de fondo AMOLED para evitar reconstrucciones
  Widget? _cachedAmoledBackground;
  String? _cachedBackgroundSongId;

  // Cache de la imagen con blur pre-renderizada (blur estático)
  ui.Image? _cachedBlurredImage;
  String? _cachedBlurredImageSongId;

  // Notifier para la posición del panel de playlist (0.0 = cerrado, 1.0 = abierto)

  // Estado para controlar la visibilidad del fondo cuando se abren letras
  final bool _playerModalOpen = false;

  PanelContent _panelContent = PanelContent.playlist;

  // Controlador para el panel de playlist interno
  final standard_panel.PanelController _playlistPanelController =
      standard_panel.PanelController();
  final ValueNotifier<bool> _hidePlayerContentNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _hidePanelContentNotifier = ValueNotifier(true);
  Timer? _hidePanelTimer;
  bool _isPlaylistPanelOpen = false;
  int _lyricsResetCounter = 0;
  int _playlistResetCounter = 0;

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

  int? _durationMsFromMediaItem(MediaItem mediaItem) {
    final fromDuration = mediaItem.duration?.inMilliseconds;
    if (fromDuration != null && fromDuration > 0) return fromDuration;

    final raw =
        mediaItem.extras?['durationMs'] ?? mediaItem.extras?['duration'];
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw > 0) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  String? _durationTextFromMediaItem(MediaItem mediaItem) {
    final raw = mediaItem.extras?['durationText']?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;

    final durationMs = _durationMsFromMediaItem(mediaItem);
    if (durationMs != null && durationMs > 0) {
      return _formatDuration(Duration(milliseconds: durationMs));
    }
    return null;
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

  Uri? _displayArtUriFor(MediaItem mediaItem) {
    final raw = mediaItem.extras?['displayArtUri']?.toString().trim();
    if (raw != null && raw.isNotEmpty) {
      final parsed = Uri.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return mediaItem.artUri;
  }

  void _handleMediaSourceTransition(MediaItem mediaItem) {
    final isStreaming = mediaItem.extras?['isStreaming'] == true;
    final didSwitchSource =
        _lastMediaItemWasStreaming != null &&
        _lastMediaItemWasStreaming != isStreaming;

    _lastMediaItemWasStreaming = isStreaming;
    if (!didSwitchSource) return;

    _sourceSwitchTransitionTimer?.cancel();
    _suppressSourceSwitchTransitions = true;
    _sourceSwitchTransitionTimer = Timer(
      _sourceSwitchTransitionSuppression,
      () {
        if (!mounted) return;
        setState(() {
          _suppressSourceSwitchTransitions = false;
        });
      },
    );
  }

  MediaItem? _resolveStableMediaItem(MediaItem? incomingMediaItem) {
    if (incomingMediaItem == null) {
      // Mantener último item solo mientras haya guardia activa para absorber rebotes.
      if (_sourceBounceTargetIsStreaming != null &&
          _stabilizedMediaItem != null) {
        return _stabilizedMediaItem;
      }
      _stabilizedMediaItem = null;
      return null;
    }

    final incomingIsStreaming =
        incomingMediaItem.extras?['isStreaming'] == true;
    final guardedTargetSource = _sourceBounceTargetIsStreaming;

    // Si llega un item de la fuente opuesta durante la guardia, ignorarlo.
    if (guardedTargetSource != null &&
        incomingIsStreaming != guardedTargetSource) {
      return _stabilizedMediaItem ?? incomingMediaItem;
    }

    final previousMediaItem = _stabilizedMediaItem;
    if (previousMediaItem != null) {
      final previousIsStreaming =
          previousMediaItem.extras?['isStreaming'] == true;
      if (previousIsStreaming != incomingIsStreaming) {
        _sourceBounceTargetIsStreaming = incomingIsStreaming;
        _sourceBounceGuardTimer?.cancel();
        _sourceBounceGuardTimer = Timer(_sourceBounceGuardDuration, () {
          _sourceBounceGuardTimer = null;
          _sourceBounceTargetIsStreaming = null;
        });
      }
    }

    _stabilizedMediaItem = incomingMediaItem;
    return incomingMediaItem;
  }

  void _setStreamingArtworkLoadingDebounced({
    required bool hasLocalArtUri,
    required String? songKey,
  }) {
    if (hasLocalArtUri) {
      _streamingArtworkDebounceTimer?.cancel();
      _streamingArtworkDebounceTimer = null;
      _pendingStreamingArtworkSongKey = null;
      if (_artworkLoadingNotifier.value) {
        _artworkLoadingNotifier.value = false;
      }
      return;
    }

    _pendingStreamingArtworkSongKey = songKey;
    _streamingArtworkDebounceTimer?.cancel();
    _streamingArtworkDebounceTimer = Timer(_streamingArtworkDebounceDelay, () {
      if (!mounted) return;

      final currentMediaItem = audioHandler?.mediaItem.value;
      final currentSongKey =
          currentMediaItem?.extras?['songId']?.toString() ??
          currentMediaItem?.id;
      if (songKey != null && currentSongKey != songKey) return;
      if (_pendingStreamingArtworkSongKey != songKey) return;

      _artworkLoadingNotifier.value = true;
    });
  }

  Widget buildArtwork(MediaItem mediaItem, double size) {
    final artUri = _displayArtUriFor(mediaItem);

    // Prioridad 1: Si hay artUri, usarlo directamente
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local, usar Image.file (más rápido)
      if (scheme == 'file' || scheme == 'content') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(
            File(artUri.toFilePath()),
            width: size,
            height: size,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (context, error, stackTrace) => _defaultArtwork(size),
          ),
        );
      }

      // Si es una URL de red, usar CachedNetworkImage con optimizaciones
      if (scheme == 'http' || scheme == 'https') {
        final cacheSize = (size * MediaQuery.of(context).devicePixelRatio)
            .round();
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CachedNetworkImage(
            imageUrl: artUri.toString(),
            width: size,
            height: size,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            errorWidget: (context, url, error) => _defaultArtwork(size),
            // Decodificar al tamaño objetivo reduce trabajo de render.
            memCacheWidth: cacheSize,
            memCacheHeight: cacheSize,
          ),
        );
      }
    }

    // Prioridad 2: Verificar caché si no hay artUri
    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];

    if (songId != null && songPath != null) {
      final cachedArtwork = _getCachedArtwork(songPath);
      if (cachedArtwork != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(
            File(cachedArtwork.toFilePath()),
            width: size,
            height: size,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (context, error, stackTrace) => _defaultArtwork(size),
          ),
        );
      } else {
        // Si no está en cache, cargar de forma asíncrona
        _loadArtworkAsync(songId, songPath);
      }
    }

    // Si no hay carátula disponible, mostrar placeholder
    return _defaultArtwork(size);
  }

  Widget _defaultArtwork(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
        color: Colors.transparent,
      ),
    );
  }

  Widget _buildModalArtwork(MediaItem mediaItem) {
    final artUri = _displayArtUriFor(mediaItem);
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local
      if (scheme == 'file' || scheme == 'content') {
        try {
          return Image.file(
            File(artUri.toFilePath()),
            width: 60,
            height: 60,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildModalPlaceholder(),
          );
        } catch (e) {
          return _buildModalPlaceholder();
        }
      }

      // Si es una URL de red
      if (scheme == 'http' || scheme == 'https') {
        return CachedNetworkImage(
          imageUrl: artUri.toString(),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          errorWidget: (context, url, error) => _buildModalPlaceholder(),
          placeholder: (context, url) => Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            child: LoadingIndicator(),
          ),
        );
      }
    }

    // Si no hay artUri, verificar caché primero
    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];

    if (songId != null && songPath != null) {
      // Verificar si está en caché primero
      final cachedArtwork = _getCachedArtwork(songPath);
      if (cachedArtwork != null) {
        // print('✅ MODAL: Usando carátula desde caché para: ${songPath.split('/').last}');
        return Image.file(
          File(cachedArtwork.toFilePath()),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildModalPlaceholder(),
        );
      } else {
        // Si no está en cache, cargar de forma asíncrona
        _loadArtworkAsync(songId, songPath);
        // print('⚠️ MODAL: Carátula no en caché, usando placeholder para: ${songPath.split('/').last}');
      }
    }

    // Fallback si no hay carátula o no se puede cargar
    return _buildModalPlaceholder();
  }

  Widget _buildModalPlaceholder() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.music_note, size: 30),
    );
  }

  Future<void> _searchSongOnYouTube(MediaItem mediaItem) async {
    try {
      // 1. Intentar obtener videoId desde extras
      var videoId = mediaItem.extras?['videoId']?.toString();

      // 2. Si no está en extras o está vacío, intentar desde el historial (por path/id)
      if (videoId == null || videoId.trim().isEmpty) {
        final historyItem = await DownloadHistoryHive.getDownloadByPath(
          mediaItem.id,
        );
        if (historyItem != null) {
          videoId = historyItem.videoId;
        }
      }

      final Uri url;

      if (videoId != null && videoId.trim().isNotEmpty) {
        final normalizedId = videoId.trim();
        // print('Video ID: $normalizedId');
        url = Uri.parse('https://www.youtube.com/watch?v=$normalizedId');
      } else {
        // print('No Video ID');
        final title = mediaItem.title;
        final artist = mediaItem.artist ?? '';

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
        url = Uri.parse(youtubeSearchUrl);
      }

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
  Future<void> _searchSongOnYouTubeMusic(MediaItem mediaItem) async {
    try {
      // 1. Intentar obtener videoId desde extras
      var videoId = mediaItem.extras?['videoId']?.toString();

      // 2. Si no está en extras o está vacío, intentar desde el historial (por path/id)
      if (videoId == null || videoId.trim().isEmpty) {
        final historyItem = await DownloadHistoryHive.getDownloadByPath(
          mediaItem.id,
        );
        if (historyItem != null) {
          videoId = historyItem.videoId;
        }
      }

      final Uri url;

      if (videoId != null && videoId.trim().isNotEmpty) {
        final normalizedId = videoId.trim();
        // print('Video ID: $normalizedId');
        url = Uri.parse('https://music.youtube.com/watch?v=$normalizedId');
      } else {
        // print('No Video ID');
        final title = mediaItem.title;
        final artist = mediaItem.artist ?? '';

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
        url = Uri.parse(ytMusicSearchUrl);
      }

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        // ignore: use_build_context_synchronously
      }
    } catch (e) {
      // ignore: avoid_print
    }
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
      child: Ink(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(28),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      ),
    );
  }

  Future<void> _closePlayerBeforeArtistNavigation() async {
    if (widget.onClose != null) {
      widget.onClose!();
      await Future.delayed(Duration.zero);
      return;
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      await Future.delayed(Duration.zero);
    }
  }

  // Función para mostrar opciones de búsqueda
  Future<void> _showSearchOptions(MediaItem mediaItem) async {
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
                        _searchSongOnYouTube(mediaItem);
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
                        _searchSongOnYouTubeMusic(mediaItem);
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

  Future<void> _loadLyrics(MediaItem mediaItem) async {
    if (!mounted) return;
    setState(() {
      _loadingLyrics = true;
      _lyricLines = [];
      _currentLyricIndex = 0;
      _apiUnavailable = false;
      _noConnection = false;
    });

    final result = await SyncedLyricsService.getSyncedLyricsWithResult(
      mediaItem,
    );
    if (!mounted) return;

    if (result.type == LyricsResultType.found && result.data?.synced != null) {
      final synced = result.data!.synced!;
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
        _apiUnavailable = false;
        _noConnection = false;
      });
    } else {
      if (!mounted) return;
      setState(() {
        _lyricLines = [];
        _loadingLyrics = false;
        // Marcar como no disponible solo si realmente falló la API
        _apiUnavailable = result.type == LyricsResultType.apiUnavailable;
        _noConnection = result.type == LyricsResultType.noConnection;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _prefsFuture = SharedPreferences.getInstance();
    _loadGesturePreferences();
    _setupGesturePreferencesListener();
    _checkNavSetting();

    // Escuchar cambios en favoritos/dislikes desde otras fuentes (ej: notificación)
    favoritesShouldReload.addListener(_onFavoritesChanged);
    dislikesShouldReload.addListener(_onDislikesChanged);

    // Inicializar animación de fade
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeInOut),
    );

    // Eliminado: _loadQueueSource();
    // Eliminado: (audioHandler as MyAudioHandler).queueSourceNotifier.addListener(_onQueueSourceChanged);
  }

  Future<void> _checkNavSetting() async {
    try {
      final navSetting = AndroidNavSetting();
      bool isGesture = await navSetting.isGestureNavigationEnabled();
      if (mounted) {
        setState(() {
          _isGestureNavigation = isGesture;
        });
      }
    } catch (e) {
      // Ignorar fallback
    }
  }

  /// Configura el listener para cambios en las preferencias de gestos
  void _setupGesturePreferencesListener() {
    _gestureListener = () {
      if (mounted) {
        _loadGesturePreferences();
      }
    };
    gesturePreferencesChanged.addListener(_gestureListener!);
  }

  /// Maneja cambios en favoritos desde otras fuentes (notificación, otras pantallas)
  void _onFavoritesChanged() {
    // Recalcular el estado de favorito de la canción actual
    final currentMediaItem = audioHandler?.mediaItem.valueOrNull;
    if (currentMediaItem != null) {
      final path = _favoritePathForMediaItem(currentMediaItem).trim();
      if (path.isEmpty) return;
      FavoritesDB().isFavorite(path).then((isFav) {
        if (!mounted) return;
        final currentPath = _favoritePathForMediaItem(
          audioHandler?.mediaItem.valueOrNull ?? currentMediaItem,
        ).trim();
        if (currentPath != path) return;
        setState(() {
          _currentSongDataPath = path;
          _isCurrentFavorite = isFav;
        });
      });
    }
  }

  /// Maneja cambios en dislikes desde otras fuentes
  void _onDislikesChanged() {
    final currentMediaItem = audioHandler?.mediaItem.valueOrNull;
    if (currentMediaItem != null) {
      final path = _favoritePathForMediaItem(currentMediaItem).trim();
      if (path.isEmpty) return;
      DislikesDB().isDisliked(path).then((isDislinked) {
        if (!mounted) return;
        final currentPath = _favoritePathForMediaItem(
          audioHandler?.mediaItem.valueOrNull ?? currentMediaItem,
        ).trim();
        if (currentPath != path) return;
        setState(() {
          _currentSongDataPath = path;
          _isCurrentDisliked = isDislinked;
        });
      });
    }
  }

  Future<void> _toggleDislike() async {
    final currentMediaItem = audioHandler?.mediaItem.valueOrNull;
    if (currentMediaItem == null) return;
    final path = _favoritePathForMediaItem(currentMediaItem).trim();
    if (path.isEmpty) return;
    final isStreaming = currentMediaItem.extras?['isStreaming'] == true;

    if (_isCurrentDisliked) {
      await DislikesDB().removeDislike(path);
      dislikesShouldReload.value = !dislikesShouldReload.value;
      if (mounted) {
        setState(() {
          _isCurrentDisliked = false;
        });
      }
    } else {
      // Si se marca como no me gusta, opcionalmente quitar de favoritos
      if (_isCurrentFavorite) {
        await FavoritesDB().removeFavorite(path);
        favoritesShouldReload.value = !favoritesShouldReload.value;
        if (mounted) {
          setState(() {
            _isCurrentFavorite = false;
          });
        }
      }

      if (isStreaming) {
        final videoId = currentMediaItem.extras?['videoId']?.toString().trim();
        final displayArtUri = currentMediaItem.extras?['displayArtUri']
            ?.toString()
            .trim();
        final artUri = (displayArtUri != null && displayArtUri.isNotEmpty)
            ? displayArtUri
            : currentMediaItem.artUri?.toString();
        await DislikesDB().addDislikePath(
          path,
          title: currentMediaItem.title,
          artist: currentMediaItem.artist,
          videoId: videoId,
          artUri: artUri,
        );
        dislikesShouldReload.value = !dislikesShouldReload.value;
        if (mounted) {
          setState(() {
            _isCurrentDisliked = true;
          });
        }
        return;
      }

      final allSongs = await _audioQuery.querySongs();
      final song = allSongs.where((s) => s.data == path).firstOrNull;
      if (song != null) {
        await DislikesDB().addDislike(song);
        dislikesShouldReload.value = !dislikesShouldReload.value;
        if (mounted) {
          setState(() {
            _isCurrentDisliked = true;
          });
        }
      }
    }
  }

  /// Carga las preferencias de gestos
  Future<void> _loadGesturePreferences() async {
    final preferences = await GesturePreferences.getAllGesturePreferences();
    if (mounted) {
      setState(() {
        _disableOpenPlaylistGesture = preferences['openPlaylist'] ?? false;
        _disableChangeSongGesture = preferences['changeSong'] ?? false;
      });
    }
  }

  /// Verifica si la carátula está en el caché del audio handler
  Uri? _getCachedArtwork(String songPath) {
    final cache = artworkCache;
    final cached = cache[songPath];
    if (cached != null) {
      // print('⚡ CACHÉ HIT: Carátula encontrada en caché para: ${songPath.split('/').last}');
    } else {
      // print('❌ CACHÉ MISS: Carátula NO encontrada en caché para: ${songPath.split('/').last}');
    }
    return cached;
  }

  /// Carga carátula de forma asíncrona si no está en cache
  void _loadArtworkAsync(int songId, String songPath) {
    // Verificar si ya se está cargando para evitar duplicados
    if (_lastArtworkSongId == songId.toString()) return;

    _lastArtworkSongId = songId.toString();

    // Cargar de forma asíncrona usando el sistema unificado
    getOrCacheArtwork(songId, songPath)
        .then((artUri) {
          if (artUri != null && mounted) {
            // Forzar rebuild para mostrar la carátula cargada
            setState(() {});
          }
        })
        .catchError((error) {
          // print('❌ Error cargando carátula en player screen: $error');
        });
  }

  /// Maneja el cambio de carátula cuando cambia la canción
  void _handleArtworkChange(MediaItem? newMediaItem) {
    final newSongKey =
        newMediaItem?.extras?['songId']?.toString() ?? newMediaItem?.id;

    if (_lastArtworkSongId != newSongKey) {
      _lastArtworkSongId = newSongKey;

      // Verificar si la carátula está disponible inmediatamente
      if (newMediaItem != null) {
        final songId = newMediaItem.extras?['songId'] as int?;
        final songPath = newMediaItem.extras?['data'] as String?;
        final isStreaming = newMediaItem.extras?['isStreaming'] == true;
        final artUri = newMediaItem.artUri;
        final hasArtUri = artUri != null;
        final artScheme = artUri?.scheme.toLowerCase();
        final hasLocalArtUri =
            artScheme == 'file' || artScheme == 'content' || artScheme == '';
        final hasCachedArtwork = songPath != null
            ? _getCachedArtwork(songPath) != null
            : false;

        // En streaming, mostrar loading hasta tener carátula local (file/content).
        // En local, mantener el comportamiento previo.
        if (isStreaming) {
          _setStreamingArtworkLoadingDebounced(
            hasLocalArtUri: hasLocalArtUri,
            songKey: newSongKey,
          );
        } else {
          _streamingArtworkDebounceTimer?.cancel();
          _streamingArtworkDebounceTimer = null;
          _pendingStreamingArtworkSongKey = null;
          _artworkLoadingNotifier.value = !hasArtUri && !hasCachedArtwork;
        }

        // Precargar carátula en background si no está disponible
        if (!hasArtUri &&
            !hasCachedArtwork &&
            songId != null &&
            songPath != null) {
          _preloadArtworkInBackground(songId, songPath);
        }
      } else {
        _streamingArtworkDebounceTimer?.cancel();
        _streamingArtworkDebounceTimer = null;
        _pendingStreamingArtworkSongKey = null;
        _artworkLoadingNotifier.value = false;
      }

      // Precargar la siguiente carátula en el caché de Flutter (Nivel 3)
      _precacheNextInQueue();
    } else if (newMediaItem?.artUri != null && _artworkLoadingNotifier.value) {
      // La carátula acaba de llegar para la canción actual.
      final isStreaming = newMediaItem?.extras?['isStreaming'] == true;
      final artScheme = newMediaItem?.artUri?.scheme.toLowerCase();
      final hasLocalArtUri =
          artScheme == 'file' || artScheme == 'content' || artScheme == '';
      if (isStreaming && hasLocalArtUri) {
        _streamingArtworkDebounceTimer?.cancel();
        _streamingArtworkDebounceTimer = null;
        _pendingStreamingArtworkSongKey = null;
        _artworkLoadingNotifier.value = false;
      } else if (!isStreaming) {
        _artworkLoadingNotifier.value = false;
      }
    }
  }

  /// Precarga la carátula en background para mejorar la experiencia
  void _preloadArtworkInBackground(int songId, String songPath) {
    // Usar el sistema optimizado de carga de carátulas
    Future.microtask(() async {
      try {
        await getOrCacheArtwork(songId, songPath);
        // Actualizar el estado si la carátula se cargó exitosamente
        if (mounted && _lastArtworkSongId == songId.toString()) {
          _artworkLoadingNotifier.value = false;
          // Si es la actual y acaba de cargarse, precargar la siguiente
          _precacheNextInQueue();
        }
      } catch (e) {
        // Error silencioso - no afectar la UI
      }
    });
  }

  /// Precarga la siguiente carátula en la cola directamente en el caché de Flutter
  /// Esto evita el flicker/parpadeo al cambiar de canción ya que la imagen estará decodificada.
  /// Usa debounce para evitar lanzar descargas concurrentes durante skips rápidos.
  void _precacheNextInQueue() {
    _precacheNextTimer?.cancel();
    _precacheNextTimer = Timer(const Duration(milliseconds: 300), () {
      _precacheNextInQueueImmediate();
    });
  }

  void _precacheNextInQueueImmediate() {
    if (!mounted) return;

    final queue = audioHandler?.queue.value ?? [];
    final currentItem = audioHandler?.mediaItem.value;
    if (queue.isEmpty || currentItem == null) return;

    final currentIndex = queue.indexWhere((item) => item.id == currentItem.id);
    if (currentIndex != -1 && currentIndex < queue.length - 1) {
      final nextItem = queue[currentIndex + 1];
      final artUri = _displayArtUriFor(nextItem);

      if (artUri != null) {
        ImageProvider provider;
        if (artUri.scheme == 'file') {
          provider = FileImage(File(artUri.toFilePath()));
        } else if (artUri.scheme == 'http' || artUri.scheme == 'https') {
          final url = artUri.toString();
          provider = CachedNetworkImageProvider(url);
          if (_artworkDiskPreloadGuard.add(url)) {
            // Fuerza guardar en cache de disco para que la siguiente canción
            // abra su carátula instantáneamente incluso tras rebuilds.
            unawaited(() async {
              try {
                await DefaultCacheManager().downloadFile(url);
              } catch (_) {
                // Error silencioso durante precarga.
              } finally {
                if (_artworkDiskPreloadGuard.length > 60) {
                  _artworkDiskPreloadGuard.clear();
                }
              }
            }());
          }
        } else {
          return;
        }

        // Precargar en el caché de Flutter
        precacheImage(provider, context).catchError((e) {
          // Error silencioso
        });
      }
    }
  }

  @override
  void dispose() {
    _precacheNextTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _hideIndicatorsTimer?.cancel();
    _streamingArtworkDebounceTimer?.cancel();
    _sourceSwitchTransitionTimer?.cancel();
    _sourceBounceGuardTimer?.cancel();
    _fadeController.dispose();
    _lyricsScrollController.dispose();
    _dragValueSecondsNotifier.dispose();
    _artworkLoadingNotifier.dispose();
    _lyricsUpdateNotifier.dispose();

    favoritesShouldReload.removeListener(_onFavoritesChanged);
    dislikesShouldReload.removeListener(_onDislikesChanged);
    if (_gestureListener != null) {
      gesturePreferencesChanged.removeListener(_gestureListener!);
    }
    super.dispose();
  }

  Color normalizePaletteColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    // Si la saturación original es muy baja (gris/blanco/negro), mantenerla baja
    // para evitar colorear artificialmente imágenes en escala de grises.
    final isGrayscale = hsl.saturation < 0.15;

    // Si es muy oscuro (negro), forzar un poco de luminosidad para que se vea
    double effectiveLightness = hsl.lightness;
    if (effectiveLightness < 0.15) {
      effectiveLightness = 0.15;
    }

    // Ajustar el brillo: bajamos el rango para que el color sea más "rico"
    // y no se vea pálido (pastel), permitiendo que la saturación resalte.
    // Brillo dinámico: Si el color original es muy oscuro, le damos un pequeño boost
    // para que se note. Si es muy claro, lo oscurecemos para que no se vea pálido.
    double targetLightness;
    if (hsl.lightness < 0.2) {
      // Colores muy oscuros: subirlos un poco menos (0.18 - 0.28)
      targetLightness = 0.18 + (hsl.lightness * 0.5);
    } else if (hsl.lightness > 0.5) {
      // Colores muy claros: bajarlos más (0.3 - 0.4)
      targetLightness = 0.3 + (hsl.lightness * 0.1);
    } else {
      // Colores medios: rango más bajo
      targetLightness = hsl.lightness.clamp(0.2, 0.4);
    }

    final fixedLightness = targetLightness.clamp(0.15, 0.36);

    // Saturación extrema mantenida para que el color explote
    final fixedSaturation = isGrayscale
        ? hsl.saturation
        : (hsl.saturation * 1.7).clamp(0.8, 1.0);

    return hsl
        .withLightness(fixedLightness)
        .withSaturation(fixedSaturation)
        .toColor();
  }

  Future<void> _showSongOptions(
    BuildContext context,
    MediaItem initialMediaItem,
  ) async {
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StreamBuilder<MediaItem?>(
          stream: audioHandler?.mediaItem,
          initialData: initialMediaItem,
          builder: (context, snapshot) {
            final mediaItem = snapshot.data ?? initialMediaItem;

            return AnimatedBuilder(
              animation: Listenable.merge([
                useDynamicColorBackgroundNotifier,
                useDynamicColorInDialogsNotifier,
                colorSchemeNotifier,
              ]),
              builder: (context, _) {
                return Builder(
                  builder: (context) {
                    final useDynamicBg =
                        useDynamicColorBackgroundNotifier.value;
                    final useDynamicDialogs =
                        useDynamicColorInDialogsNotifier.value;
                    final colorScheme = colorSchemeNotifier.value;
                    final isAmoled = colorScheme == AppColorScheme.amoled;
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;
                    final useWhiteSearchButton =
                        colorScheme == AppColorScheme.system ||
                        colorScheme == AppColorScheme.dynamic ||
                        useDynamicBg ||
                        useDynamicDialogs;
                    final showDynamicBg =
                        (useDynamicBg || useDynamicDialogs) &&
                        isAmoled &&
                        isDark;

                    return Material(
                      color: showDynamicBg
                          ? Colors.black
                          : Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          if (showDynamicBg)
                            ValueListenableBuilder<Color?>(
                              valueListenable:
                                  ThemeController.instance.dominantColor,
                              builder: (context, domColor, _) {
                                return Positioned.fill(
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeInOut,
                                    color: normalizePaletteColor(
                                      domColor ?? Colors.black,
                                    ).withValues(alpha: 0.35),
                                  ),
                                );
                              },
                            ),
                          SafeArea(
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
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: SizedBox(
                                            width: 60,
                                            height: 60,
                                            child: _buildModalArtwork(
                                              mediaItem,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        // Título y artista
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                mediaItem.title,
                                                maxLines: 1,
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                mediaItem.artist ??
                                                    LocaleProvider.tr(
                                                      'unknown_artist',
                                                    ),
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: isAmoled
                                                      ? Colors.white.withValues(
                                                          alpha: 0.85,
                                                        )
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
                                        Builder(
                                          builder: (context) {
                                            final searchButtonBackgroundColor =
                                                useWhiteSearchButton && isAmoled
                                                ? Colors.white
                                                : Theme.of(
                                                        context,
                                                      ).brightness ==
                                                      Brightness.dark
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.primary
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onPrimaryContainer
                                                      .withValues(alpha: 0.7);
                                            final searchButtonForegroundColor =
                                                useWhiteSearchButton && isAmoled
                                                ? Colors.black
                                                : Theme.of(
                                                        context,
                                                      ).brightness ==
                                                      Brightness.dark
                                                ? Theme.of(
                                                    context,
                                                  ).colorScheme.onPrimary
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainer;

                                            return Material(
                                              color:
                                                  searchButtonBackgroundColor,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              clipBehavior: Clip.antiAlias,
                                              child: InkWell(
                                                onTap: () async {
                                                  Navigator.of(context).pop();
                                                  await _showSearchOptions(
                                                    mediaItem,
                                                  );
                                                },
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 8,
                                                      ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons.search,
                                                        size: 20,
                                                        color:
                                                            searchButtonForegroundColor,
                                                      ),
                                                      const SizedBox(width: 8),
                                                      TranslatedText(
                                                        'search',
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          fontSize: 14,
                                                          color:
                                                              searchButtonForegroundColor,
                                                        ),
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
                                  if (mediaItem.extras?['isStreaming'] == true)
                                    ListTile(
                                      leading: const Icon(Icons.sensors),
                                      title: Text(
                                        LocaleProvider.tr('start_radio'),
                                      ),
                                      onTap: () async {
                                        Navigator.of(context).pop();
                                        await _startRadioFromCurrent(mediaItem);
                                      },
                                    ),
                                  FutureBuilder<bool>(
                                    future: FavoritesDB().isFavorite(
                                      _favoritePathForMediaItem(mediaItem),
                                    ),
                                    builder: (context, snapshot) {
                                      final isFav = snapshot.data ?? false;
                                      return ListTile(
                                        leading: Icon(
                                          isFav
                                              ? Icons.delete_outline
                                              : Icons.favorite_outline_rounded,
                                          weight: isFav ? null : 600,
                                        ),
                                        title: Text(
                                          isFav
                                              ? LocaleProvider.tr(
                                                  'remove_from_favorites',
                                                )
                                              : LocaleProvider.tr(
                                                  'add_to_favorites',
                                                ),
                                        ),
                                        onTap: () async {
                                          Navigator.of(context).pop();

                                          final path =
                                              _favoritePathForMediaItem(
                                                mediaItem,
                                              );
                                          final isStreaming =
                                              mediaItem
                                                  .extras?['isStreaming'] ==
                                              true;

                                          if (isFav) {
                                            await FavoritesDB().removeFavorite(
                                              path,
                                            );
                                            favoritesShouldReload.value =
                                                !favoritesShouldReload.value;
                                          } else {
                                            if (path.isEmpty) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'No se puede añadir: ruta no disponible',
                                                    ),
                                                  ),
                                                );
                                              }
                                              return;
                                            }

                                            if (isStreaming) {
                                              final videoId = mediaItem
                                                  .extras?['videoId']
                                                  ?.toString()
                                                  .trim();
                                              final displayArtUri = mediaItem
                                                  .extras?['displayArtUri']
                                                  ?.toString()
                                                  .trim();
                                              final artUri =
                                                  (displayArtUri != null &&
                                                      displayArtUri.isNotEmpty)
                                                  ? displayArtUri
                                                  : mediaItem.artUri
                                                        ?.toString();
                                              final durationMs =
                                                  _durationMsFromMediaItem(
                                                    mediaItem,
                                                  );
                                              final durationText =
                                                  _durationTextFromMediaItem(
                                                    mediaItem,
                                                  );

                                              await FavoritesDB()
                                                  .addFavoritePath(
                                                    path,
                                                    title: mediaItem.title,
                                                    artist: mediaItem.artist,
                                                    videoId: videoId,
                                                    artUri: artUri,
                                                    durationText: durationText,
                                                    durationMs: durationMs,
                                                  );
                                              favoritesShouldReload.value =
                                                  !favoritesShouldReload.value;
                                              return;
                                            }

                                            final allSongs = await _audioQuery
                                                .querySongs();
                                            final songList = allSongs
                                                .where((s) => s.data == path)
                                                .toList();

                                            if (songList.isEmpty) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'No se encontró la canción original',
                                                    ),
                                                  ),
                                                );
                                              }
                                              return;
                                            }

                                            final song = songList.first;
                                            await _addToFavorites(song);
                                          }
                                        },
                                      );
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.queue_music),
                                    title: Text(
                                      LocaleProvider.tr('add_to_playlist'),
                                    ),
                                    onTap: () async {
                                      if (!mounted) {
                                        return;
                                      }
                                      final safeContext = context;
                                      Navigator.of(safeContext).pop();
                                      await _showAddToPlaylistDialog(
                                        safeContext,
                                        mediaItem,
                                      );
                                    },
                                  ),
                                  if ((mediaItem.artist ?? '')
                                          .trim()
                                          .isNotEmpty ||
                                      (mediaItem.extras?['videoId']
                                              ?.toString()
                                              .trim()
                                              .isNotEmpty ??
                                          false))
                                    ListTile(
                                      leading: const Icon(Icons.person_outline),
                                      title: const TranslatedText(
                                        'go_to_artist',
                                      ),
                                      onTap: () async {
                                        final navigator = Navigator.of(context);

                                        final videoId =
                                            (mediaItem.extras?['videoId']
                                                        ?.toString() ??
                                                    '')
                                                .trim();

                                        var name = (mediaItem.artist ?? '')
                                            .trim();

                                        if (videoId.isNotEmpty) {
                                          final historyItem =
                                              await DownloadHistoryHive.getDownloadByVideoId(
                                                videoId,
                                              );
                                          final hiveArtist = historyItem?.artist
                                              .trim();
                                          if (hiveArtist != null &&
                                              hiveArtist.isNotEmpty) {
                                            name = hiveArtist;
                                          }
                                        }

                                        if (name.isEmpty) return;

                                        final route = PageRouteBuilder(
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
                                                const begin = Offset(1.0, 0.0);
                                                const end = Offset.zero;
                                                const curve = Curves.ease;
                                                final tween =
                                                    Tween(
                                                      begin: begin,
                                                      end: end,
                                                    ).chain(
                                                      CurveTween(curve: curve),
                                                    );
                                                return SlideTransition(
                                                  position: animation.drive(
                                                    tween,
                                                  ),
                                                  child: child,
                                                );
                                              },
                                        );
                                        // Cerrar primero el modal de opciones.
                                        navigator.pop();
                                        await _closePlayerBeforeArtistNavigation();
                                        if (ArtistScreen.hasActiveInstance) {
                                          navigator.pushReplacement(route);
                                        } else {
                                          navigator.push(route);
                                        }
                                      },
                                    ),
                                  if (!(mediaItem.extras?['isStreaming'] ==
                                      true))
                                    FutureBuilder<bool>(
                                      future: ShortcutsDB().isShortcut(
                                        mediaItem.extras?['data'] ?? '',
                                      ),
                                      builder: (context, snapshot) {
                                        final isCurrentlyPinned =
                                            snapshot.data ?? false;
                                        final path =
                                            mediaItem.extras?['data'] ?? '';

                                        return ListTile(
                                          leading: Icon(
                                            isCurrentlyPinned
                                                ? Icons.push_pin
                                                : Icons.push_pin_outlined,
                                          ),
                                          title: Text(
                                            isCurrentlyPinned
                                                ? LocaleProvider.tr(
                                                    'unpin_shortcut',
                                                  )
                                                : LocaleProvider.tr(
                                                    'pin_shortcut',
                                                  ),
                                          ),
                                          onTap: () async {
                                            Navigator.of(context).pop();

                                            if (path.isEmpty) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'No se puede fijar: ruta no disponible',
                                                    ),
                                                  ),
                                                );
                                              }
                                              return;
                                            }

                                            final shortcutsDB = ShortcutsDB();

                                            if (isCurrentlyPinned) {
                                              // Desfijar de accesos directos
                                              await shortcutsDB.removeShortcut(
                                                path,
                                              );
                                              // Notificar que los accesos directos han cambiado
                                              shortcutsShouldReload.value =
                                                  !shortcutsShouldReload.value;
                                            } else {
                                              // Fijar en accesos directos
                                              await shortcutsDB.addShortcut(
                                                path,
                                              );
                                              // Notificar que los accesos directos han cambiado
                                              shortcutsShouldReload.value =
                                                  !shortcutsShouldReload.value;
                                            }
                                          },
                                        );
                                      },
                                    ),
                                  ListTile(
                                    leading: const Icon(Icons.lyrics_outlined),
                                    title: Text(
                                      LocaleProvider.tr('show_lyrics'),
                                    ),
                                    onTap: () async {
                                      Navigator.of(context).pop();

                                      // Check if lyrics on cover is enabled
                                      final prefs =
                                          await SharedPreferences.getInstance();
                                      final showLyricsOnCover =
                                          prefs.getBool(
                                            'show_lyrics_on_cover',
                                          ) ??
                                          false;

                                      if (showLyricsOnCover) {
                                        // Original behavior: toggle lyrics display on cover
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
                                      } else {
                                        // New behavior: show lyrics in modal
                                        if (!context.mounted) return;
                                        _showLyricsModal(context, mediaItem);
                                      }
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(
                                      Icons.equalizer_rounded,
                                    ),
                                    title: Text(LocaleProvider.tr('equalizer')),
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      Navigator.of(context).push(
                                        PageRouteBuilder(
                                          pageBuilder:
                                              (
                                                context,
                                                animation,
                                                secondaryAnimation,
                                              ) => const EqualizerScreen(),
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
                                                final tween =
                                                    Tween(
                                                      begin: begin,
                                                      end: end,
                                                    ).chain(
                                                      CurveTween(curve: curve),
                                                    );
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
                                  /*
              ValueListenableBuilder<double>(
                valueListenable:
                    (audioHandler as MyAudioHandler).volumeBoostNotifier,
                builder: (context, volumeBoost, child) {
                  return ListTile(
                    leading: const Icon(Icons.volume_up),
                    title: Text(LocaleProvider.tr('volume_boost')),
                    onTap: () {
                      Navigator.of(context).pop();
                      _showVolumeBoostDialog(context);
                    },
                  );
                },
              ),
              */
                                  if (!(mediaItem.extras?['isStreaming'] ==
                                      true))
                                    ListTile(
                                      leading: const Icon(Icons.share),
                                      title: Text(
                                        LocaleProvider.tr('share_audio_file'),
                                      ),
                                      onTap: () async {
                                        final dataPath =
                                            mediaItem.extras?['data']
                                                as String?;
                                        final hasLocalFilePath =
                                            dataPath != null &&
                                            dataPath.isNotEmpty &&
                                            !dataPath.startsWith('http://') &&
                                            !dataPath.startsWith('https://') &&
                                            File(dataPath).existsSync();
                                        if (!hasLocalFilePath) return;

                                        Navigator.of(context).pop();
                                        await Future<void>.delayed(
                                          const Duration(milliseconds: 220),
                                        );
                                        await SharePlus.instance.share(
                                          ShareParams(
                                            text: mediaItem.title,
                                            files: [XFile(dataPath)],
                                          ),
                                        );
                                      },
                                    ),
                                  FutureBuilder<String?>(
                                    future: _resolveShareUrl(mediaItem),
                                    builder: (context, snapshot) {
                                      final shareUrl = snapshot.data;
                                      if (shareUrl == null ||
                                          shareUrl.isEmpty) {
                                        return const SizedBox.shrink();
                                      }

                                      final isStreaming =
                                          mediaItem.extras?['isStreaming'] ==
                                          true;

                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          ListTile(
                                            leading: const Icon(Icons.link),
                                            title: Text(
                                              LocaleProvider.tr('share_link'),
                                            ),
                                            onTap: () async {
                                              Navigator.of(context).pop();
                                              await Future<void>.delayed(
                                                const Duration(
                                                  milliseconds: 220,
                                                ),
                                              );
                                              await SharePlus.instance.share(
                                                ShareParams(text: shareUrl),
                                              );
                                            },
                                          ),
                                          if (isStreaming)
                                            ListTile(
                                              leading: const Icon(
                                                Icons.download_rounded,
                                              ),
                                              title: Text(
                                                LocaleProvider.tr('download'),
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await Future<void>.delayed(
                                                  const Duration(
                                                    milliseconds: 220,
                                                  ),
                                                );
                                                if (!mounted) return;
                                                await _queueStreamingDownload(
                                                  this.context,
                                                  mediaItem,
                                                );
                                              },
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                  ListTile(
                                    leading: () {
                                      final isActive =
                                          audioHandler
                                              .myHandler
                                              ?.sleepTimeRemaining !=
                                          null;
                                      return Icon(
                                        isActive
                                            ? Icons.timer
                                            : Icons.timer_outlined,
                                      );
                                    }(),
                                    title: Text(() {
                                      final remaining = audioHandler
                                          .myHandler
                                          ?.sleepTimeRemaining;
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
                                        backgroundColor: Colors.transparent,
                                        builder: (context) =>
                                            const SleepTimerOptionsSheet(),
                                      );
                                    },
                                  ),

                                  ListTile(
                                    leading: const Icon(Icons.info_outline),
                                    title: Text(LocaleProvider.tr('song_info')),
                                    onTap: () async {
                                      Navigator.of(context).pop();
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
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<String?> _resolveShareUrl(MediaItem mediaItem) async {
    var videoId = mediaItem.extras?['videoId']?.toString();

    if (videoId == null || videoId.trim().isEmpty) {
      final historyItem = await DownloadHistoryHive.getDownloadByPath(
        mediaItem.id,
      );
      videoId = historyItem?.videoId;
    }

    final normalized = videoId?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return 'https://music.youtube.com/watch?v=$normalized';
    }

    final streamUrl = mediaItem.extras?['streamUrl']?.toString().trim();
    if (streamUrl != null && streamUrl.isNotEmpty) {
      return streamUrl;
    }

    return null;
  }

  Future<void> _startRadioFromCurrent(MediaItem mediaItem) async {
    if (mediaItem.extras?['isStreaming'] != true) return;

    final fastResult = await audioHandler?.customAction(
      'startStreamingRadioFromCurrent',
      {'action': 'startStreamingRadioFromCurrent', 'replaceQueue': true},
    );
    if (fastResult is Map && fastResult['ok'] == true) {
      return;
    }
    if (fastResult is Map) {
      // El handler respondió y no pudo iniciar radio sin reiniciar.
      // Evitar fallback que reinicia la reproducción actual.
      return;
    }

    final rawVideoId = mediaItem.extras?['videoId']?.toString().trim();
    String? videoId = (rawVideoId != null && rawVideoId.isNotEmpty)
        ? rawVideoId
        : null;

    if (videoId == null) {
      final historyItem = await DownloadHistoryHive.getDownloadByPath(
        mediaItem.id,
      );
      final historyVideoId = historyItem?.videoId.trim();
      if (historyVideoId != null && historyVideoId.isNotEmpty) {
        videoId = historyVideoId;
      }
    }

    String? streamUrl = mediaItem.extras?['streamUrl']?.toString().trim();
    if ((streamUrl == null || streamUrl.isEmpty) &&
        videoId != null &&
        videoId.isNotEmpty) {
      streamUrl = await StreamService.getBestAudioUrl(
        videoId,
        reportError: true,
      );
    }

    if (streamUrl == null || streamUrl.isEmpty) {
      return;
    }

    final displayArtUri = mediaItem.extras?['displayArtUri']?.toString().trim();
    final artUri = (displayArtUri != null && displayArtUri.isNotEmpty)
        ? displayArtUri
        : mediaItem.artUri?.toString();
    final playback = audioHandler?.playbackState.valueOrNull;
    final initialPositionMs =
        playback?.updatePosition.inMilliseconds.clamp(0, 1 << 31) ?? 0;
    final wasPlaying = playback?.playing ?? true;

    final result = await audioHandler?.customAction('playYtStream', {
      'action': 'playYtStream',
      'streamUrl': streamUrl,
      'title': mediaItem.title,
      'artist': mediaItem.artist,
      'videoId': videoId,
      'mediaId': (videoId != null && videoId.isNotEmpty)
          ? 'yt:$videoId'
          : mediaItem.id,
      'artUri': artUri,
      'displayArtUri': displayArtUri,
      'playlistId': mediaItem.extras?['playlistId']?.toString().trim(),
      'autoPlay': wasPlaying,
      'radioMode': true,
      'initialPositionMs': initialPositionMs,
    });

    if (result is Map && result['ok'] == false) return;
  }

  Future<void> _queueStreamingDownload(
    BuildContext context,
    MediaItem mediaItem,
  ) async {
    final videoId = mediaItem.extras?['videoId']?.toString().trim();
    if (videoId == null || videoId.isEmpty) {
      return;
    }

    final artist = (mediaItem.artist ?? '').trim().isNotEmpty
        ? mediaItem.artist!.trim()
        : LocaleProvider.tr('artist_unknown');
    final preferredThumbUrl =
        mediaItem.extras?['displayArtUri']?.toString().trim().isNotEmpty == true
        ? mediaItem.extras!['displayArtUri'].toString().trim()
        : mediaItem.artUri?.toString();

    final downloadQueue = DownloadQueue();
    await downloadQueue.addToQueue(
      context: context,
      videoId: videoId,
      title: mediaItem.title,
      artist: artist,
      thumbUrl: preferredThumbUrl,
    );
    if (!context.mounted) return;
    await _showDownloadStartedDialog(context);
  }

  Future<void> _showDownloadStartedDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder<AppColorScheme>(
        valueListenable: colorSchemeNotifier,
        builder: (context, colorScheme, child) {
          final isAmoled = colorScheme == AppColorScheme.amoled;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final primaryColor = Theme.of(context).colorScheme.primary;

          return AlertDialog(
            backgroundColor: isAmoled && isDark
                ? Colors.black
                : Theme.of(context).colorScheme.surface,
            surfaceTintColor: Colors.transparent,
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
                  Icon(
                    Icons.download_done_rounded,
                    size: 32,
                    color: primaryColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('success'),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      LocaleProvider.tr('download_started'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(180),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.only(right: 24, bottom: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text(
                          LocaleProvider.tr('ok'),
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
      ),
    );
  }

  String _favoritePathForMediaItem(MediaItem mediaItem) {
    final dataPath = mediaItem.extras?['data']?.toString().trim();
    if (dataPath != null && dataPath.isNotEmpty) {
      return dataPath;
    }
    final videoId = mediaItem.extras?['videoId']?.toString().trim();
    if (videoId != null && videoId.isNotEmpty) {
      return 'yt:$videoId';
    }
    return mediaItem.id;
  }

  bool _isStreamingPath(String path) {
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
    if (forStreaming) return playlist.songPaths.any(_isStreamingPath);
    return playlist.songPaths.any((path) => !_isStreamingPath(path));
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
  }

  Future<void> _showAddToPlaylistDialog(
    BuildContext safeContext,
    MediaItem mediaItem,
  ) async {
    final mediaPath = _favoritePathForMediaItem(mediaItem);
    final isStreamingTarget =
        mediaItem.extras?['isStreaming'] == true || _isStreamingPath(mediaPath);
    final allPlaylists = await PlaylistsDB().getAllPlaylists();
    final playlists = allPlaylists
        .where(
          (p) =>
              _playlistMatchesTargetSource(p, forStreaming: isStreamingTarget),
        )
        .toList();
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final playlistArtworkSourcesCache = await _buildPlaylistArtworkSourcesCache(
      playlists,
    );
    final TextEditingController controller = TextEditingController();

    if (!safeContext.mounted) return;

    showModalBottomSheet(
      context: safeContext,
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

        return AnimatedBuilder(
          animation: Listenable.merge([
            useDynamicColorBackgroundNotifier,
            useDynamicColorInDialogsNotifier,
            colorSchemeNotifier,
          ]),
          builder: (context, _) {
            return Builder(
              builder: (context) {
                final useDynamicBg = useDynamicColorBackgroundNotifier.value;
                final useDynamicDialogs =
                    useDynamicColorInDialogsNotifier.value;
                final colorScheme = colorSchemeNotifier.value;
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final showDynamicBg =
                    (useDynamicBg || useDynamicDialogs) && isAmoled && isDark;

                return Material(
                  color: showDynamicBg
                      ? Colors.black
                      : Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      if (showDynamicBg)
                        ValueListenableBuilder<Color?>(
                          valueListenable:
                              ThemeController.instance.dominantColor,
                          builder: (context, domColor, _) {
                            return Positioned.fill(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                color: normalizePaletteColor(
                                  domColor ?? Colors.black,
                                ).withValues(alpha: 0.35),
                              ),
                            );
                          },
                        ),
                      SafeArea(
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom:
                                MediaQuery.of(context).viewInsets.bottom + 16,
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
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 20),
                              if (playlists.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 24,
                                  ),
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.playlist_add_rounded,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        size: 48,
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
                                      maxHeight:
                                          MediaQuery.of(context).size.height *
                                          0.4,
                                    ),
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      padding: EdgeInsets.zero,
                                      itemCount: playlists.length,
                                      itemBuilder: (context, i) {
                                        final pl = playlists[i];
                                        final bool isFirst = i == 0;
                                        final bool isLast =
                                            i == playlists.length - 1;
                                        final bool isOnly =
                                            playlists.length == 1;

                                        BorderRadius borderRadius;
                                        if (isOnly) {
                                          borderRadius = BorderRadius.circular(
                                            20,
                                          );
                                        } else if (isFirst) {
                                          borderRadius =
                                              const BorderRadius.only(
                                                topLeft: Radius.circular(20),
                                                topRight: Radius.circular(20),
                                                bottomLeft: Radius.circular(4),
                                                bottomRight: Radius.circular(4),
                                              );
                                        } else if (isLast) {
                                          borderRadius =
                                              const BorderRadius.only(
                                                topLeft: Radius.circular(4),
                                                topRight: Radius.circular(4),
                                                bottomLeft: Radius.circular(20),
                                                bottomRight: Radius.circular(
                                                  20,
                                                ),
                                              );
                                        } else {
                                          borderRadius = BorderRadius.circular(
                                            4,
                                          );
                                        }

                                        return Padding(
                                          padding: EdgeInsets.only(
                                            bottom: isLast ? 0 : 4,
                                          ),
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
                                                final isStreaming =
                                                    mediaItem
                                                        .extras?['isStreaming'] ==
                                                    true;
                                                if (isStreaming) {
                                                  final path =
                                                      _favoritePathForMediaItem(
                                                        mediaItem,
                                                      );
                                                  final videoId = mediaItem
                                                      .extras?['videoId']
                                                      ?.toString()
                                                      .trim();
                                                  final displayArtUri = mediaItem
                                                      .extras?['displayArtUri']
                                                      ?.toString()
                                                      .trim();
                                                  final artUri =
                                                      (displayArtUri != null &&
                                                          displayArtUri
                                                              .isNotEmpty)
                                                      ? displayArtUri
                                                      : mediaItem.artUri
                                                            ?.toString();
                                                  await PlaylistsDB()
                                                      .addSongPathToPlaylist(
                                                        pl.id,
                                                        path,
                                                        title: mediaItem.title,
                                                        artist:
                                                            mediaItem.artist,
                                                        videoId: videoId,
                                                        artUri: artUri,
                                                        durationText:
                                                            _durationTextFromMediaItem(
                                                              mediaItem,
                                                            ),
                                                        durationMs:
                                                            _durationMsFromMediaItem(
                                                              mediaItem,
                                                            ),
                                                      );
                                                  playlistsShouldReload.value =
                                                      !playlistsShouldReload
                                                          .value;
                                                  if (context.mounted) {
                                                    Navigator.of(context).pop();
                                                  }
                                                  return;
                                                }

                                                final songList = allSongs
                                                    .where(
                                                      (s) =>
                                                          s.data ==
                                                          (mediaItem
                                                                  .extras?['data'] ??
                                                              ''),
                                                    )
                                                    .toList();

                                                if (songList.isNotEmpty) {
                                                  await PlaylistsDB()
                                                      .addSongToPlaylist(
                                                        pl.id,
                                                        songList.first,
                                                      );
                                                  playlistsShouldReload.value =
                                                      !playlistsShouldReload
                                                          .value;
                                                  if (context.mounted) {
                                                    Navigator.of(context).pop();
                                                  }
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
                                      if (controller.text.trim().isNotEmpty) {
                                        await _createPlaylistAndAddSong(
                                          context,
                                          controller,
                                          mediaItem,
                                        );
                                        playlistsShouldReload.value =
                                            !playlistsShouldReload.value;
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
                                  if (value.trim().isNotEmpty) {
                                    await _createPlaylistAndAddSong(
                                      context,
                                      controller,
                                      mediaItem,
                                    );
                                  }
                                },
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
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
      if (_isStreamingPath(normalizedPath)) {
        return _PlaylistStreamingArtwork(
          sources: _streamingPlaylistArtworkSources(
            playlist.id,
            normalizedPath,
            streamingArtworkCache,
          ),
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
    if (idLike.hasMatch(path)) return path;
    return null;
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
    return [
      'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
      'https://img.youtube.com/vi/$videoId/sddefault.jpg',
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    ];
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
        if (!_isStreamingPath(path)) continue;
        final meta = await PlaylistsDB().getPlaylistSongMeta(playlist.id, path);
        final metaArtUri = meta?['artUri']?.toString().trim();
        final metaVideoId = meta?['videoId']?.toString().trim();
        final videoId = (metaVideoId != null && metaVideoId.isNotEmpty)
            ? metaVideoId
            : _extractVideoIdFromPath(path);

        final sources = <String>[];
        if (metaArtUri != null &&
            metaArtUri.isNotEmpty &&
            metaArtUri != 'null') {
          sources.add(metaArtUri);
        }
        if (videoId != null && videoId.isNotEmpty) {
          sources.addAll([
            'https://img.youtube.com/vi/$videoId/maxresdefault.jpg',
            'https://img.youtube.com/vi/$videoId/sddefault.jpg',
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          ]);
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

  Future<void> _createPlaylistAndAddSong(
    BuildContext context,
    TextEditingController controller,
    MediaItem mediaItem,
  ) async {
    final name = controller.text.trim();
    if (name.isEmpty) return;

    final playlistId = await PlaylistsDB().createPlaylist(name);
    final path = _favoritePathForMediaItem(mediaItem);
    final isStreaming =
        mediaItem.extras?['isStreaming'] == true || _isStreamingPath(path);
    if (isStreaming) {
      final videoId = mediaItem.extras?['videoId']?.toString().trim();
      final displayArtUri = mediaItem.extras?['displayArtUri']
          ?.toString()
          .trim();
      final artUri = (displayArtUri != null && displayArtUri.isNotEmpty)
          ? displayArtUri
          : mediaItem.artUri?.toString();
      await PlaylistsDB().addSongPathToPlaylist(
        playlistId,
        path,
        title: mediaItem.title,
        artist: mediaItem.artist,
        videoId: videoId,
        artUri: artUri,
        durationText: _durationTextFromMediaItem(mediaItem),
        durationMs: _durationMsFromMediaItem(mediaItem),
      );
      playlistsShouldReload.value = !playlistsShouldReload.value;
      if (context.mounted) Navigator.of(context).pop();
      return;
    }

    final allSongs = await _audioQuery.querySongs();
    final songList = allSongs
        .where((s) => s.data == (mediaItem.extras?['data'] ?? ''))
        .toList();

    if (songList.isNotEmpty) {
      await PlaylistsDB().addSongToPlaylist(playlistId, songList.first);
      playlistsShouldReload.value = !playlistsShouldReload.value;
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  /*
  void _showVolumeBoostDialog(BuildContext context) {
    final currentBoost = (audioHandler as MyAudioHandler).volumeBoost;
    double tempBoost = currentBoost;

    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: isAmoled && isDark
                ? const BorderSide(color: Colors.white, width: 1)
                : BorderSide.none,
          ),
          title: Row(
            children: [
              const Icon(Icons.volume_up),
              const SizedBox(width: 8),
              Text(LocaleProvider.tr('volume_boost')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                LocaleProvider.tr('volume_boost_desc'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          LocaleProvider.tr('important_information'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      LocaleProvider.tr('volume_boost_info'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  const Icon(Icons.volume_down, size: 20),
                  Expanded(
                    child: Slider(
                      value: tempBoost,
                      min: 1.0,
                      max: 3.0,
                      divisions: 20, // 20 divisiones = incrementos de 0.1
                      label: '${(tempBoost * 100).toInt()}%',
                      onChanged: (value) {
                        setState(() {
                          tempBoost = value;
                        });
                      },
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 20),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          LocaleProvider.tr('multiplier'),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          '${tempBoost}x',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: tempBoost > 1.0
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          LocaleProvider.tr('effective_volume'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          '${(tempBoost * 100).toInt()}%',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: tempBoost > 1.0
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(LocaleProvider.tr('cancel')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  // print('🎵 Intentando aplicar volume boost: ${tempBoost}x');

                  if (audioHandler == null) {
                    // print('❌ AudioHandler es null');
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            LocaleProvider.tr(
                              'error_audiohandler_not_available',
                            ),
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                    return;
                  }

                  await audioHandler.myHandler?.setVolumeBoost(
                    tempBoost,
                  );

                  // print('🎵 Volume boost aplicado exitosamente');

                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                } catch (e) {
                  // print('❌ Error en el botón de volume boost: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${LocaleProvider.tr('error_applying_volume_boost')}: $e',
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: Text(LocaleProvider.tr('ok')),
            ),
          ],
        ),
      ),
    );
  }
  */

  void _showPlaylistDialog(BuildContext context) {
    // Abrir el panel de playlist
    setState(() {
      _panelContent = PanelContent.playlist;
      _playlistResetCounter++;
    });
    if (_playlistPanelController.isAttached) {
      _playlistPanelController.open();
    }
  }

  // Construye el fondo con la carátula para el tema AMOLED
  Widget? _buildAmoledBackground(MediaItem? mediaItem) {
    if (mediaItem == null) return null;

    // Verificar si podemos usar el cache
    final songId = (mediaItem.extras?['songId'] ?? mediaItem.id).toString();
    if (_cachedBackgroundSongId == songId && _cachedAmoledBackground != null) {
      return _cachedAmoledBackground;
    }

    final artUri = _displayArtUriFor(mediaItem);
    ImageProvider? imageProvider;

    // Prioridad 1: Si hay artUri, usarlo directamente
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local, usar FileImage
      if (scheme == 'file' || scheme == 'content') {
        try {
          imageProvider = FileImage(File(artUri.toFilePath()));
        } catch (e) {
          imageProvider = null;
        }
      }
      // Si es una URL de red, usar CachedNetworkImageProvider
      else if (scheme == 'http' || scheme == 'https') {
        imageProvider = CachedNetworkImageProvider(artUri.toString());
      }
    }

    // Prioridad 2: Verificar caché si no hay artUri
    if (imageProvider == null) {
      final songPath = mediaItem.extras?['data'];
      if (songPath != null) {
        final cachedArtwork = _getCachedArtwork(songPath);
        if (cachedArtwork != null) {
          try {
            imageProvider = FileImage(File(cachedArtwork.toFilePath()));
          } catch (e) {
            imageProvider = null;
          }
        }
      }
    }

    // Si no hay imagen disponible, no mostrar fondo
    if (imageProvider == null) {
      if (_suppressSourceSwitchTransitions && _cachedAmoledBackground != null) {
        return _cachedAmoledBackground;
      }
      _cachedAmoledBackground = null;
      _cachedBackgroundSongId = null;
      _cachedBlurredImage = null;
      _cachedBlurredImageSongId = null;
      return null;
    }

    imageProvider = ResizeImage(imageProvider, width: 150);

    // Construir y cachear el widget con blur estático
    // Usar RepaintBoundary para aislar el blur y evitar repintados del resto del árbol
    final backgroundWidget = RepaintBoundary(
      key: ValueKey('amoled_bg_$songId'),
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // OPTIMIZACIÓN CRÍTICA:
                // Renderizar el blur a baja resolución y escalar el resultado.
                // BackdropFilter e ImageFiltered a pantalla completa son muy costosos (lag).
                // Al reducir 6x, procesamos 36 veces menos píxeles.
                const double scale = 6.0;
                final w = constraints.maxWidth / scale;
                final h = constraints.maxHeight / scale;

                if (w <= 0 || h <= 0) return const SizedBox.shrink();

                // Usar un widget que cachea el blur como imagen estática
                return _StaticBlurImage(
                  imageProvider: imageProvider!,
                  width: w,
                  height: h,
                  scale: scale + 0.1,
                  cachedImage: _cachedBlurredImageSongId == songId
                      ? _cachedBlurredImage
                      : null,
                  onImageCached: (image) {
                    if (_cachedBlurredImageSongId != songId) {
                      _cachedBlurredImage = image;
                      _cachedBlurredImageSongId = songId;
                    }
                  },
                );
              },
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.75),
                    Colors.black.withValues(alpha: 0.5),
                    Colors.black.withValues(alpha: 0.3),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Guardar en cache
    _cachedAmoledBackground = backgroundWidget;
    _cachedBackgroundSongId = songId;

    return backgroundWidget;
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

    final isSmallScreen = height < 650;
    final artworkSize = isSmallScreen ? width * 0.6 : width * 0.84;
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
    final buttonFontSize = (width * 0.04 + 10).clamp(10.0, 100.0);

    // En modo panel (onClose != null), usamos Listener en vez de GestureDetector
    // para no competir con el SlidingUpPanel del overlay que maneja el deslizar para cerrar.
    // El Listener solo detecta swipe-up para abrir el playlist.
    final streamContent = StreamBuilder<MediaItem?>(
      stream: audioHandler?.mediaItem,
      initialData: widget.initialMediaItem,
      builder: (context, snapshot) {
        final mediaItem = _resolveStableMediaItem(snapshot.data);

        // Solo manejar cambio de carátula cuando realmente cambia la canción
        if (mediaItem != null && mediaItem.id != _lastMediaItemId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _handleArtworkChange(mediaItem);
          });
        }

        // Solo procesar si es una canción nueva
        if (mediaItem != null && mediaItem.id != _lastMediaItemId) {
          _handleMediaSourceTransition(mediaItem);

          // Resetear progreso visual para evitar arrastrar la posición de la cola anterior.
          _lastKnownPosition = Duration.zero;
          _lastMediaItemId = mediaItem.id;

          // Ocultar letras si estaban mostradas
          if (_showLyrics) {
            _showLyrics = false;
          }

          // Reiniciar estado de letras para evitar que persistan entre canciones
          _lyricLines = [];
          _currentLyricIndex = 0;
          _apiUnavailable = false;
          _noConnection = false;
          _loadingLyrics = false;

          // Calcular favorito y dislike una sola vez por canción para evitar consultas repetidas
          final path = _favoritePathForMediaItem(mediaItem);
          unawaited(() async {
            bool fav = false;
            bool dislike = false;
            if (path.isNotEmpty) {
              try {
                fav = await FavoritesDB().isFavorite(path);
                dislike = await DislikesDB().isDisliked(path);
              } catch (_) {}
            }
            if (!mounted) return;
            if (_currentSongDataPath != path ||
                _isCurrentFavorite != fav ||
                _isCurrentDisliked != dislike) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() {
                  _currentSongDataPath = path;
                  _isCurrentFavorite = fav;
                  _isCurrentDisliked = dislike;
                  _likeButtonKey = GlobalKey<LikeButtonState>();
                });
              });
            }
          }());
        }

        // Usar el MediaItem inicial si no hay uno actual
        final currentMediaItem = mediaItem ?? widget.initialMediaItem;

        if (currentMediaItem == null) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: SizedBox.shrink(),
          );
        }

        return ValueListenableBuilder<bool>(
          valueListenable: useArtworkAsBackgroundPlayerNotifier,
          builder: (context, useArtworkBg, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: useDynamicColorBackgroundNotifier,
              builder: (context, useDynamicBg, _) {
                return ValueListenableBuilder<AppColorScheme>(
                  valueListenable: colorSchemeNotifier,
                  builder: (context, colorScheme, _) {
                    final isAmoled = colorScheme == AppColorScheme.amoled;
                    final isDark =
                        Theme.of(context).brightness == Brightness.dark;
                    final showBackground = isAmoled && isDark && useArtworkBg;
                    final showDynamicBg = useDynamicBg && isAmoled && isDark;
                    final isDynamicTheme =
                        colorScheme == AppColorScheme.dynamic;

                    return RepaintBoundary(
                      // Aislar el body del player para que no repinte durante el scroll
                      // del panel de playlist. El fondo (blur/color) es costoso y causa lag.
                      child: Stack(
                        children: [
                          // Capa base negra opaca (siempre visible para AMOLED o fondo dinámico)
                          if (showBackground || showDynamicBg)
                            const Positioned.fill(
                              child: ColoredBox(color: Colors.black),
                            ),
                          // Fondo (carátula o color dinámico) con animación de opacidad
                          if (showBackground || showDynamicBg) ...[
                            (() {
                              // Construir el contenido estático del fondo una sola vez y cachearlo
                              // Envolver en RepaintBoundary para evitar repintados innecesarios
                              final backgroundStack = RepaintBoundary(
                                child: Stack(
                                  children: [
                                    if (showBackground)
                                      Positioned.fill(
                                        child: AnimatedSwitcher(
                                          duration:
                                              _suppressSourceSwitchTransitions
                                              ? Duration.zero
                                              : const Duration(
                                                  milliseconds: 200,
                                                ),
                                          child:
                                              _buildAmoledBackground(
                                                currentMediaItem,
                                              ) ??
                                              const SizedBox.shrink(
                                                key: ValueKey('empty_bg'),
                                              ),
                                        ),
                                      ),
                                    if (showDynamicBg)
                                      ValueListenableBuilder<Color?>(
                                        valueListenable: ThemeController
                                            .instance
                                            .dominantColor,
                                        builder: (context, domColor, _) {
                                          return Positioned.fill(
                                            child: AnimatedContainer(
                                              duration: const Duration(
                                                milliseconds: 200,
                                              ),
                                              curve: Curves.easeInOut,
                                              color: normalizePaletteColor(
                                                domColor ?? Colors.black,
                                              ).withValues(alpha: 0.45),
                                            ),
                                          );
                                        },
                                      ),
                                    // Gradiente inferior para mejorar legibilidad (común para ambos fondos)
                                    Positioned.fill(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Colors.black.withValues(
                                                alpha: 0.65,
                                              ),
                                              Colors.transparent,
                                            ],
                                            stops: const [0.0, 0.7],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );

                              // Threshold para evitar renderizar el blur cuando la opacidad es muy baja
                              // Esto mejora significativamente el rendimiento durante las animaciones
                              const double minOpacityThreshold = 0.15;

                              // No usar _playlistPanelPosition para ocultar el fondo
                              // El fondo permanece visible siempre para evitar re-renderizados
                              if (widget.panelPositionNotifier != null) {
                                return ValueListenableBuilder<double>(
                                  valueListenable:
                                      widget.panelPositionNotifier!,
                                  builder: (context, panelPos, child) {
                                    // Solo usar la opacidad del panel overlay, sin afectar por el playlist
                                    final panelOpacity =
                                        ((panelPos - 0.7) / 0.3).clamp(
                                          0.0,
                                          1.0,
                                        );

                                    // Si el modal de letras está abierto, forzamos opacidad 0
                                    final targetOpacity = _playerModalOpen
                                        ? 0.0
                                        : panelOpacity;

                                    // OPTIMIZACIÓN CRÍTICA: No renderizar el blur cuando la opacidad es muy baja
                                    // El blur es muy costoso y no es visible cuando la opacidad < threshold
                                    if (targetOpacity <= 0.0) {
                                      return const Offstage();
                                    }

                                    // Si la opacidad es muy baja, usar Offstage para evitar renderizado pero mantener el widget en el árbol
                                    if (targetOpacity < minOpacityThreshold) {
                                      return const Offstage();
                                    }

                                    // Normalizar la opacidad para que vaya de 0 a 1 cuando está por encima del threshold
                                    final normalizedOpacity =
                                        ((targetOpacity - minOpacityThreshold) /
                                                (1.0 - minOpacityThreshold))
                                            .clamp(0.0, 1.0);

                                    // Usar Opacity con IgnorePointer cuando la opacidad es baja
                                    // para evitar procesamiento de eventos innecesarios
                                    return IgnorePointer(
                                      ignoring: normalizedOpacity < 0.5,
                                      child: Opacity(
                                        opacity: normalizedOpacity,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: backgroundStack,
                                );
                              } else {
                                // Si no hay panelPositionNotifier, mostrar siempre el fondo
                                final targetOpacity = _playerModalOpen
                                    ? 0.0
                                    : 1.0;

                                if (targetOpacity <= 0.0) {
                                  return const Offstage();
                                }

                                return Opacity(
                                  opacity: targetOpacity,
                                  child: backgroundStack,
                                );
                              }
                            })(),
                          ],
                          // Scaffold principal
                          Scaffold(
                            backgroundColor: (showBackground || showDynamicBg)
                                ? Colors.transparent
                                : null,
                            appBar: AppBar(
                              backgroundColor: (showBackground || showDynamicBg)
                                  ? Colors.transparent
                                  : Theme.of(context).scaffoldBackgroundColor,
                              surfaceTintColor: Colors.transparent,
                              elevation: 0,
                              scrolledUnderElevation: 0,
                              leading: widget.panelPositionNotifier != null
                                  ? ValueListenableBuilder<double>(
                                      valueListenable:
                                          widget.panelPositionNotifier!,
                                      builder: (context, position, child) {
                                        return Opacity(
                                          opacity: ((position - 0.7) / 0.3)
                                              .clamp(0.0, 1.0),
                                          child: child,
                                        );
                                      },
                                      child: ValueListenableBuilder<bool>(
                                        valueListenable: playLoadingNotifier,
                                        builder: (context, isLoading, _) {
                                          return IconButton(
                                            iconSize: 38,
                                            icon: const Icon(
                                              Icons.keyboard_arrow_down,
                                            ),
                                            onPressed: () {
                                              if (widget.onClose != null) {
                                                widget.onClose!();
                                              } else {
                                                Navigator.of(context).pop();
                                              }
                                            },
                                          );
                                        },
                                      ),
                                    )
                                  : ValueListenableBuilder<bool>(
                                      valueListenable: playLoadingNotifier,
                                      builder: (context, isLoading, _) {
                                        return IconButton(
                                          iconSize: 38,
                                          icon: const Icon(
                                            Icons.keyboard_arrow_down,
                                          ),
                                          onPressed: () {
                                            if (widget.onClose != null) {
                                              widget.onClose!();
                                            } else {
                                              Navigator.of(context).pop();
                                            }
                                          },
                                        );
                                      },
                                    ),
                              title: widget.panelPositionNotifier != null
                                  ? ValueListenableBuilder<double>(
                                      valueListenable:
                                          widget.panelPositionNotifier!,
                                      builder: (context, position, child) {
                                        return Opacity(
                                          opacity: ((position - 0.7) / 0.3)
                                              .clamp(0.0, 1.0),
                                          child: child,
                                        );
                                      },
                                      child: FutureBuilder<SharedPreferences>(
                                        future: _prefsFuture,
                                        builder: (context, snapshot) {
                                          final prefs = snapshot.data;
                                          final queueSource = prefs?.getString(
                                            'last_queue_source',
                                          );
                                          if (queueSource != null &&
                                              queueSource.isNotEmpty) {
                                            return Center(
                                              child: RichText(
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                text: TextSpan(
                                                  children: [
                                                    TextSpan(
                                                      text: LocaleProvider.tr(
                                                        'playing_from',
                                                      ),
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium
                                                                    ?.color
                                                                    ?.withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    ),
                                                            fontWeight:
                                                                FontWeight
                                                                    .normal,
                                                          ),
                                                    ),
                                                    TextSpan(
                                                      text: queueSource,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium
                                                                    ?.color
                                                                    ?.withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
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
                                    )
                                  : FutureBuilder<SharedPreferences>(
                                      future: _prefsFuture,
                                      builder: (context, snapshot) {
                                        final prefs = snapshot.data;
                                        final queueSource = prefs?.getString(
                                          'last_queue_source',
                                        );
                                        if (queueSource != null &&
                                            queueSource.isNotEmpty) {
                                          return Center(
                                            child: RichText(
                                              textAlign: TextAlign.center,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              text: TextSpan(
                                                children: [
                                                  TextSpan(
                                                    text: LocaleProvider.tr(
                                                      'playing_from',
                                                    ),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium
                                                                  ?.color
                                                                  ?.withValues(
                                                                    alpha: 0.5,
                                                                  ),
                                                          fontWeight:
                                                              FontWeight.normal,
                                                        ),
                                                  ),
                                                  TextSpan(
                                                    text: queueSource,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleMedium
                                                                  ?.color
                                                                  ?.withValues(
                                                                    alpha: 0.7,
                                                                  ),
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
                              actions: [
                                widget.panelPositionNotifier != null
                                    ? ValueListenableBuilder<double>(
                                        valueListenable:
                                            widget.panelPositionNotifier!,
                                        builder: (context, position, child) {
                                          return Opacity(
                                            opacity: ((position - 0.7) / 0.3)
                                                .clamp(0.0, 1.0),
                                            child: child,
                                          );
                                        },
                                        child: IconButton(
                                          iconSize: 38,
                                          icon: const Icon(Icons.more_vert),
                                          onPressed: () {
                                            _showSongOptions(
                                              context,
                                              currentMediaItem,
                                            );
                                          },
                                        ),
                                      )
                                    : IconButton(
                                        iconSize: 38,
                                        icon: const Icon(Icons.more_vert),
                                        onPressed: () {
                                          _showSongOptions(
                                            context,
                                            currentMediaItem,
                                          );
                                        },
                                      ),
                              ],
                            ),
                            resizeToAvoidBottomInset: true,
                            body: Container(
                              decoration: null,
                              child: SafeArea(
                                minimum: const EdgeInsets.only(bottom: 22),
                                child: Center(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(
                                          top: isSmallScreen
                                              ? height * 0.015
                                              : height * 0.03,
                                          left: isSmallScreen
                                              ? width * 0.005
                                              : width * 0.013,
                                          right: isSmallScreen
                                              ? width * 0.005
                                              : width * 0.013,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
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
                                                    return GestureDetector(
                                                      behavior: HitTestBehavior
                                                          .opaque,
                                                      onHorizontalDragEnd: (details) {
                                                        // Detectar la dirección del deslizamiento horizontal solo en la carátula
                                                        // Solo si el gesto de cambiar canción no está desactivado
                                                        if (!_disableChangeSongGesture &&
                                                            details.primaryVelocity !=
                                                                null) {
                                                          if (details
                                                                  .primaryVelocity! >
                                                              0) {
                                                            // Deslizar hacia la derecha: canción anterior
                                                            audioHandler
                                                                ?.skipToPrevious();
                                                          } else if (details
                                                                  .primaryVelocity! <
                                                              0) {
                                                            // Deslizar hacia la izquierda: siguiente canción
                                                            audioHandler
                                                                ?.skipToNext();
                                                          }
                                                        }
                                                      },
                                                      onTap: () async {
                                                        // Check if lyrics on cover is enabled
                                                        final prefs =
                                                            await SharedPreferences.getInstance();
                                                        final showLyricsOnCover =
                                                            prefs.getBool(
                                                              'show_lyrics_on_cover',
                                                            ) ??
                                                            false;

                                                        if (showLyricsOnCover) {
                                                          // Original behavior: toggle lyrics display on cover
                                                          setState(() {
                                                            _showLyrics =
                                                                !_showLyrics;
                                                          });

                                                          // Always load lyrics when enabling, to ensure they match current song
                                                          if (_showLyrics &&
                                                              !_loadingLyrics) {
                                                            _loadLyrics(
                                                              currentMediaItem,
                                                            );
                                                          }
                                                        }
                                                        // Cuando las letras se muestran en modal, no hacer nada con el tap simple
                                                        // Solo el doble toque funciona para controlar la reproducción
                                                      },
                                                      onDoubleTapDown: (details) async {
                                                        // Solo activar cuando las letras se muestran en modal
                                                        final prefs =
                                                            await SharedPreferences.getInstance();
                                                        final showLyricsOnCover =
                                                            prefs.getBool(
                                                              'show_lyrics_on_cover',
                                                            ) ??
                                                            false;

                                                        if (!showLyricsOnCover) {
                                                          // Obtener la posición del tap relativa al centro de la carátula
                                                          if (!context
                                                              .mounted) {
                                                            return;
                                                          }
                                                          final RenderBox
                                                          renderBox =
                                                              context.findRenderObject()
                                                                  as RenderBox;
                                                          final localPosition =
                                                              renderBox
                                                                  .globalToLocal(
                                                                    details
                                                                        .globalPosition,
                                                                  );
                                                          final centerX =
                                                              renderBox
                                                                  .size
                                                                  .width /
                                                              2;

                                                          // Obtener la posición actual de reproducción
                                                          final currentPosition =
                                                              audioHandler
                                                                  .myHandler
                                                                  ?.player
                                                                  .position ??
                                                              Duration.zero;

                                                          // Cancelar timer anterior si existe
                                                          _hideIndicatorsTimer
                                                              ?.cancel();

                                                          if (localPosition.dx <
                                                              centerX) {
                                                            // Doble toque en el lado izquierdo: retroceder 10 segundos
                                                            setState(() {
                                                              _showDoubleTapIndicators =
                                                                  true;
                                                              _showLeftIndicator =
                                                                  true;
                                                              _showRightIndicator =
                                                                  false;
                                                            });

                                                            // Aparecer inmediatamente (sin animación)
                                                            _fadeController
                                                                    .value =
                                                                1.0;

                                                            final newPosition =
                                                                currentPosition -
                                                                const Duration(
                                                                  seconds: 10,
                                                                );
                                                            if (newPosition
                                                                    .inMilliseconds >=
                                                                0) {
                                                              audioHandler
                                                                  ?.seek(
                                                                    newPosition,
                                                                  );
                                                            } else {
                                                              audioHandler
                                                                  ?.seek(
                                                                    Duration
                                                                        .zero,
                                                                  );
                                                            }
                                                          } else {
                                                            // Doble toque en el lado derecho: avanzar 10 segundos
                                                            setState(() {
                                                              _showDoubleTapIndicators =
                                                                  true;
                                                              _showLeftIndicator =
                                                                  false;
                                                              _showRightIndicator =
                                                                  true;
                                                            });

                                                            // Aparecer inmediatamente (sin animación)
                                                            _fadeController
                                                                    .value =
                                                                1.0;

                                                            final newPosition =
                                                                currentPosition +
                                                                const Duration(
                                                                  seconds: 10,
                                                                );
                                                            // No hay límite superior, se puede avanzar más allá de la duración
                                                            audioHandler?.seek(
                                                              newPosition,
                                                            );
                                                          }

                                                          // Iniciar animación de desvanecimiento después de 1.5 segundos
                                                          _hideIndicatorsTimer = Timer(
                                                            const Duration(
                                                              milliseconds:
                                                                  1500,
                                                            ),
                                                            () {
                                                              if (mounted) {
                                                                _fadeController.reverse().then((
                                                                  _,
                                                                ) {
                                                                  if (mounted) {
                                                                    setState(() {
                                                                      _showDoubleTapIndicators =
                                                                          false;
                                                                      _showLeftIndicator =
                                                                          false;
                                                                      _showRightIndicator =
                                                                          false;
                                                                    });
                                                                  }
                                                                });
                                                              }
                                                            },
                                                          );
                                                        }
                                                      },
                                                      child: RepaintBoundary(
                                                        child: ValueListenableBuilder<bool>(
                                                          valueListenable:
                                                              _artworkLoadingNotifier,
                                                          builder:
                                                              (
                                                                context,
                                                                _,
                                                                child,
                                                              ) =>
                                                                  child ??
                                                                  const SizedBox.shrink(),
                                                          child: FutureBuilder<bool>(
                                                            future: SharedPreferences.getInstance().then(
                                                              (prefs) =>
                                                                  prefs.getBool(
                                                                    'show_lyrics_on_cover',
                                                                  ) ??
                                                                  false,
                                                            ),
                                                            builder: (context, snapshot) {
                                                              final showLyricsOnCover =
                                                                  snapshot
                                                                      .data ??
                                                                  false;

                                                              return ValueListenableBuilder<
                                                                double
                                                              >(
                                                                valueListenable:
                                                                    widget
                                                                        .panelPositionNotifier ??
                                                                    const AlwaysStoppedAnimation(
                                                                      1.0,
                                                                    ),
                                                                builder:
                                                                    (
                                                                      context,
                                                                      position,
                                                                      child,
                                                                    ) {
                                                                      // La carátula aparece un poco antes que los botones (0.4 vs 0.7)
                                                                      return Opacity(
                                                                        opacity:
                                                                            ((position -
                                                                                        0.35) /
                                                                                    0.55)
                                                                                .clamp(
                                                                                  0.0,
                                                                                  1.0,
                                                                                ),
                                                                        child:
                                                                            child,
                                                                      );
                                                                    },
                                                                child: Stack(
                                                                  children: [
                                                                    AnimatedSwitcher(
                                                                      duration:
                                                                          _suppressSourceSwitchTransitions
                                                                          ? Duration.zero
                                                                          : const Duration(
                                                                              milliseconds: 75,
                                                                            ),
                                                                      child: KeyedSubtree(
                                                                        key: ValueKey(
                                                                          'player_art_${(currentMediaItem.extras?['songId'] ?? currentMediaItem.id).toString()}',
                                                                        ),
                                                                        child: buildArtwork(
                                                                          currentMediaItem,
                                                                          artworkSize,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    // Indicadores de doble toque solo cuando las letras se muestran en modal y se ha hecho doble toque
                                                                    if (!showLyricsOnCover &&
                                                                        _showDoubleTapIndicators)
                                                                      Positioned.fill(
                                                                        child: Container(
                                                                          decoration: BoxDecoration(
                                                                            borderRadius: BorderRadius.circular(
                                                                              artworkSize *
                                                                                  0.06,
                                                                            ),
                                                                          ),
                                                                          child: Stack(
                                                                            children: [
                                                                              // Indicador izquierdo (retroceder) - solo si se tocó el lado izquierdo
                                                                              if (_showLeftIndicator)
                                                                                Positioned(
                                                                                  left: 20,
                                                                                  top: 0,
                                                                                  bottom: 0,
                                                                                  child: AnimatedBuilder(
                                                                                    animation: _fadeAnimation,
                                                                                    builder:
                                                                                        (
                                                                                          context,
                                                                                          child,
                                                                                        ) {
                                                                                          return Opacity(
                                                                                            opacity: _fadeAnimation.value,
                                                                                            child: Center(
                                                                                              child: Container(
                                                                                                width: 50,
                                                                                                height: 50,
                                                                                                decoration: BoxDecoration(
                                                                                                  color: Colors.black.withValues(
                                                                                                    alpha: 0.5,
                                                                                                  ),
                                                                                                  shape: BoxShape.circle,
                                                                                                ),
                                                                                                child: Center(
                                                                                                  child: Icon(
                                                                                                    Icons.replay_10,
                                                                                                    color: Colors.white,
                                                                                                    size: 28,
                                                                                                  ),
                                                                                                ),
                                                                                              ),
                                                                                            ),
                                                                                          );
                                                                                        },
                                                                                  ),
                                                                                ),
                                                                              // Indicador derecho (avanzar) - solo si se tocó el lado derecho
                                                                              if (_showRightIndicator)
                                                                                Positioned(
                                                                                  right: 20,
                                                                                  top: 0,
                                                                                  bottom: 0,
                                                                                  child: AnimatedBuilder(
                                                                                    animation: _fadeAnimation,
                                                                                    builder:
                                                                                        (
                                                                                          context,
                                                                                          child,
                                                                                        ) {
                                                                                          return Opacity(
                                                                                            opacity: _fadeAnimation.value,
                                                                                            child: Center(
                                                                                              child: Container(
                                                                                                width: 50,
                                                                                                height: 50,
                                                                                                decoration: BoxDecoration(
                                                                                                  color: Colors.black.withValues(
                                                                                                    alpha: 0.5,
                                                                                                  ),
                                                                                                  shape: BoxShape.circle,
                                                                                                ),
                                                                                                child: Center(
                                                                                                  child: Icon(
                                                                                                    Icons.forward_10,
                                                                                                    color: Colors.white,
                                                                                                    size: 28,
                                                                                                  ),
                                                                                                ),
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
                                                                  ],
                                                                ),
                                                              );
                                                            },
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                                if (_showLyrics)
                                                  GestureDetector(
                                                    onTap: () {
                                                      // Toggle lyrics display when tapping on the lyrics overlay
                                                      setState(() {
                                                        _showLyrics =
                                                            !_showLyrics;
                                                      });
                                                    },
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            artworkSize * 0.04,
                                                          ),
                                                      child: RepaintBoundary(
                                                        child: Container(
                                                          width: artworkSize,
                                                          height: artworkSize,
                                                          decoration: BoxDecoration(
                                                            color: Colors.black
                                                                .withAlpha(
                                                                  (0.75 * 255)
                                                                      .toInt(),
                                                                ),
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  artworkSize *
                                                                      0.04,
                                                                ),
                                                          ),
                                                          alignment:
                                                              Alignment.center,
                                                          padding:
                                                              const EdgeInsets.all(
                                                                18,
                                                              ),
                                                          child: _loadingLyrics
                                                              ? Center(
                                                                  child: LoadingIndicator(
                                                                    activeIndicatorColor:
                                                                        Colors
                                                                            .white,
                                                                  ),
                                                                )
                                                              : _lyricLines
                                                                    .isEmpty
                                                              ? _noConnection
                                                                    ? Column(
                                                                        mainAxisAlignment:
                                                                            MainAxisAlignment.center,
                                                                        children: [
                                                                          Text(
                                                                            LocaleProvider.tr(
                                                                              'lyrics_no_connection',
                                                                            ),
                                                                            style: const TextStyle(
                                                                              color: Colors.white70,
                                                                              fontSize: 16,
                                                                            ),
                                                                            textAlign:
                                                                                TextAlign.center,
                                                                          ),
                                                                        ],
                                                                      )
                                                                    : Text(
                                                                        _apiUnavailable
                                                                            ? LocaleProvider.tr(
                                                                                'lyrics_api_unavailable',
                                                                              )
                                                                            : (_syncedLyrics ??
                                                                                  LocaleProvider.tr(
                                                                                    'lyrics_not_found',
                                                                                  )),
                                                                        style: const TextStyle(
                                                                          color:
                                                                              Colors.white,
                                                                          fontSize:
                                                                              16,
                                                                        ),
                                                                        textAlign:
                                                                            TextAlign.center,
                                                                      )
                                                              : StreamBuilder<
                                                                  Duration
                                                                >(
                                                                  stream: audioHandler
                                                                      .myHandler
                                                                      ?.positionStream,
                                                                  builder:
                                                                      (
                                                                        context,
                                                                        posSnapshot,
                                                                      ) {
                                                                        final position =
                                                                            posSnapshot.data ??
                                                                            Duration.zero;
                                                                        int
                                                                        idx = 0;
                                                                        for (
                                                                          int
                                                                          i = 0;
                                                                          i <
                                                                              _lyricLines.length;
                                                                          i++
                                                                        ) {
                                                                          if (position >=
                                                                              _lyricLines[i].time) {
                                                                            idx =
                                                                                i;
                                                                          } else {
                                                                            break;
                                                                          }
                                                                        }
                                                                        // Actualizar índice directamente sin setState
                                                                        if (_currentLyricIndex !=
                                                                            idx) {
                                                                          _currentLyricIndex =
                                                                              idx;
                                                                        }
                                                                        return VerticalMarqueeLyrics(
                                                                          lyricLines:
                                                                              _lyricLines,
                                                                          currentLyricIndex:
                                                                              _currentLyricIndex,
                                                                          context:
                                                                              context,
                                                                          artworkSize:
                                                                              artworkSize,
                                                                        );
                                                                      },
                                                                ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            const SizedBox(height: 30),
                                            SizedBox(
                                              width: width * 0.85,
                                              child: TitleMarquee(
                                                text: currentMediaItem.title,
                                                maxWidth: artworkSize,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .headlineSmall
                                                    ?.copyWith(
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.onSurface,
                                                      fontSize:
                                                          buttonFontSize + 0.75,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                              ),
                                            ),
                                            SizedBox(height: height * 0.0001),
                                            SizedBox(
                                              width: width * 0.85,
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: GestureDetector(
                                                      onTap: () async {
                                                        final videoId =
                                                            (currentMediaItem
                                                                        .extras?['videoId']
                                                                        ?.toString() ??
                                                                    '')
                                                                .trim();

                                                        var name =
                                                            (currentMediaItem
                                                                        .artist ??
                                                                    '')
                                                                .trim();

                                                        if (videoId
                                                            .isNotEmpty) {
                                                          final historyItem =
                                                              await DownloadHistoryHive.getDownloadByVideoId(
                                                                videoId,
                                                              );
                                                          final hiveArtist =
                                                              historyItem
                                                                  ?.artist
                                                                  .trim();
                                                          if (hiveArtist !=
                                                                  null &&
                                                              hiveArtist
                                                                  .isNotEmpty) {
                                                            name = hiveArtist;
                                                          }
                                                        }

                                                        if (name.isEmpty) {
                                                          return;
                                                        }

                                                        if (!context.mounted) {
                                                          return;
                                                        }

                                                        final navigator =
                                                            Navigator.of(
                                                              context,
                                                            );
                                                        final route = PageRouteBuilder(
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
                                                        );
                                                        await _closePlayerBeforeArtistNavigation();
                                                        if (ArtistScreen
                                                            .hasActiveInstance) {
                                                          navigator
                                                              .pushReplacement(
                                                                route,
                                                              );
                                                        } else {
                                                          navigator.push(route);
                                                        }
                                                      },
                                                      child: Text(
                                                        (currentMediaItem
                                                                        .artist ==
                                                                    null ||
                                                                currentMediaItem
                                                                    .artist!
                                                                    .trim()
                                                                    .isEmpty)
                                                            ? LocaleProvider.tr(
                                                                'unknown_artist',
                                                              )
                                                            : currentMediaItem
                                                                  .artist!,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleMedium
                                                            ?.copyWith(
                                                              color:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSurface
                                                                      .withValues(
                                                                        alpha:
                                                                            0.8,
                                                                      ),
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w400,
                                                              fontSize: 14,
                                                            ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        textAlign:
                                                            TextAlign.left,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (!is16by9 && !isSmallScreen) ...[
                                        const SizedBox(height: 16),
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final isSmall =
                                                constraints.maxWidth < 380;
                                            return SizedBox(
                                              width: width,
                                              child: Center(
                                                child: SingleChildScrollView(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 15,
                                                        ),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .start,
                                                      children: [
                                                        // Botón Favoritos
                                                        ValueListenableBuilder<
                                                          bool
                                                        >(
                                                          valueListenable:
                                                              playLoadingNotifier,
                                                          builder: (context, isLoading, _) {
                                                            return Container(
                                                              decoration: BoxDecoration(
                                                                color:
                                                                    Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .primary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.08,
                                                                        ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      26,
                                                                    ),
                                                              ),
                                                              margin:
                                                                  EdgeInsets.only(
                                                                    right:
                                                                        isSmall
                                                                        ? 8
                                                                        : 12,
                                                                  ),
                                                              child: Row(
                                                                mainAxisSize:
                                                                    MainAxisSize
                                                                        .min,
                                                                children: [
                                                                  AnimatedTapButton(
                                                                    onTap: () {
                                                                      if (_likeButtonKey
                                                                              .currentState !=
                                                                          null) {
                                                                        _likeButtonKey
                                                                            .currentState!
                                                                            .onTap();
                                                                      }
                                                                    },
                                                                    child: Padding(
                                                                      padding: EdgeInsets.only(
                                                                        left:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                        top: 6,
                                                                        bottom:
                                                                            6,
                                                                        right:
                                                                            4,
                                                                      ),
                                                                      child: Row(
                                                                        mainAxisSize:
                                                                            MainAxisSize.min,
                                                                        children: [
                                                                          IgnorePointer(
                                                                            child: LikeButton(
                                                                              key: _likeButtonKey,
                                                                              isLiked: _isCurrentFavorite,
                                                                              size: isSmall
                                                                                  ? 20
                                                                                  : 24,
                                                                              padding: EdgeInsets.zero,
                                                                              animationDuration: const Duration(
                                                                                milliseconds: 800,
                                                                              ),
                                                                              circleColor: CircleColor(
                                                                                start:
                                                                                    Theme.of(
                                                                                          context,
                                                                                        ).brightness ==
                                                                                        Brightness.dark
                                                                                    ? Colors.white
                                                                                    : Colors.black,
                                                                                end:
                                                                                    Theme.of(
                                                                                          context,
                                                                                        ).brightness ==
                                                                                        Brightness.dark
                                                                                    ? Colors.white
                                                                                    : Colors.black,
                                                                              ),
                                                                              bubblesColor: BubblesColor(
                                                                                dotPrimaryColor: Theme.of(
                                                                                  context,
                                                                                ).colorScheme.primary,
                                                                                dotSecondaryColor:
                                                                                    Theme.of(
                                                                                          context,
                                                                                        ).brightness ==
                                                                                        Brightness.dark
                                                                                    ? Colors.white
                                                                                    : Colors.black,
                                                                              ),
                                                                              likeBuilder:
                                                                                  (
                                                                                    bool isLiked,
                                                                                  ) {
                                                                                    return Icon(
                                                                                      isLiked
                                                                                          ? Icons.favorite_rounded
                                                                                          : Icons.favorite_border_rounded,
                                                                                      color: Theme.of(
                                                                                        context,
                                                                                      ).colorScheme.onSurface,
                                                                                      size: isSmall
                                                                                          ? 20
                                                                                          : 24,
                                                                                    );
                                                                                  },
                                                                              onTap:
                                                                                  (
                                                                                    isLiked,
                                                                                  ) async {
                                                                                    if (isLoading) return false;

                                                                                    final path = _favoritePathForMediaItem(
                                                                                      currentMediaItem,
                                                                                    );
                                                                                    if (path.isEmpty) return false;
                                                                                    final isStreaming =
                                                                                        currentMediaItem.extras?['isStreaming'] ==
                                                                                        true;

                                                                                    if (isLiked) {
                                                                                      await FavoritesDB().removeFavorite(
                                                                                        path,
                                                                                      );
                                                                                      favoritesShouldReload.value = !favoritesShouldReload.value;
                                                                                      if (!mounted) return false;
                                                                                      setState(
                                                                                        () {
                                                                                          _isCurrentFavorite = false;
                                                                                        },
                                                                                      );
                                                                                      return false;
                                                                                    } else {
                                                                                      if (isStreaming) {
                                                                                        final videoId = currentMediaItem.extras?['videoId']?.toString().trim();
                                                                                        final displayArtUri = currentMediaItem.extras?['displayArtUri']?.toString().trim();
                                                                                        final artUri =
                                                                                            (displayArtUri !=
                                                                                                    null &&
                                                                                                displayArtUri.isNotEmpty)
                                                                                            ? displayArtUri
                                                                                            : currentMediaItem.artUri?.toString();
                                                                                        final durationMs = _durationMsFromMediaItem(
                                                                                          currentMediaItem,
                                                                                        );
                                                                                        final durationText = _durationTextFromMediaItem(
                                                                                          currentMediaItem,
                                                                                        );
                                                                                        await FavoritesDB().addFavoritePath(
                                                                                          path,
                                                                                          title: currentMediaItem.title,
                                                                                          artist: currentMediaItem.artist,
                                                                                          videoId: videoId,
                                                                                          artUri: artUri,
                                                                                          durationText: durationText,
                                                                                          durationMs: durationMs,
                                                                                        );
                                                                                        favoritesShouldReload.value = !favoritesShouldReload.value;
                                                                                        if (!mounted) return false;
                                                                                        setState(
                                                                                          () {
                                                                                            _isCurrentFavorite = true;
                                                                                          },
                                                                                        );
                                                                                        return true;
                                                                                      }

                                                                                      final allSongs = await _audioQuery.querySongs();
                                                                                      final songList = allSongs
                                                                                          .where(
                                                                                            (
                                                                                              s,
                                                                                            ) =>
                                                                                                s.data ==
                                                                                                path,
                                                                                          )
                                                                                          .toList();
                                                                                      if (songList.isEmpty) {
                                                                                        if (!context.mounted) return false;
                                                                                        ScaffoldMessenger.of(
                                                                                          context,
                                                                                        ).showSnackBar(
                                                                                          SnackBar(
                                                                                            content: Text(
                                                                                              LocaleProvider.tr(
                                                                                                'song_not_found',
                                                                                              ),
                                                                                            ),
                                                                                          ),
                                                                                        );
                                                                                        return false;
                                                                                      }

                                                                                      // Si se marca como favorito, quitar de dislikes automáticamente
                                                                                      if (_isCurrentDisliked) {
                                                                                        await DislikesDB().removeDislike(
                                                                                          path,
                                                                                        );
                                                                                        dislikesShouldReload.value = !dislikesShouldReload.value;
                                                                                        if (mounted) {
                                                                                          setState(
                                                                                            () {
                                                                                              _isCurrentDisliked = false;
                                                                                            },
                                                                                          );
                                                                                        }
                                                                                      }

                                                                                      await _addToFavorites(
                                                                                        songList.first,
                                                                                      );
                                                                                      favoritesShouldReload.value = !favoritesShouldReload.value;
                                                                                      if (!mounted) return false;
                                                                                      setState(
                                                                                        () {
                                                                                          _isCurrentFavorite = true;
                                                                                        },
                                                                                      );
                                                                                      return true;
                                                                                    }
                                                                                  },
                                                                            ),
                                                                          ),
                                                                          SizedBox(
                                                                            width:
                                                                                isSmall
                                                                                ? 6
                                                                                : 8,
                                                                          ),
                                                                          Text(
                                                                            LocaleProvider.tr(
                                                                              'favorites',
                                                                            ),
                                                                            style: TextStyle(
                                                                              color: Theme.of(
                                                                                context,
                                                                              ).colorScheme.onSurface,
                                                                              fontWeight: FontWeight.w600,
                                                                              fontSize: isSmall
                                                                                  ? 12
                                                                                  : 14,
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  Padding(
                                                                    padding:
                                                                        const EdgeInsets.symmetric(
                                                                          horizontal:
                                                                              4,
                                                                        ),
                                                                    child: Text(
                                                                      ' | ',
                                                                      style: TextStyle(
                                                                        color:
                                                                            Theme.of(
                                                                              context,
                                                                            ).colorScheme.onSurface.withValues(
                                                                              alpha: 0.3,
                                                                            ),
                                                                        fontSize:
                                                                            isSmall
                                                                            ? 14
                                                                            : 16,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                  AnimatedTapButton(
                                                                    onTap:
                                                                        isLoading
                                                                        ? () {}
                                                                        : _toggleDislike,
                                                                    child: Padding(
                                                                      padding: EdgeInsets.only(
                                                                        left: 4,
                                                                        top: 6,
                                                                        bottom:
                                                                            6,
                                                                        right:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                      ),
                                                                      child: Icon(
                                                                        Symbols
                                                                            .heart_broken,
                                                                        fill:
                                                                            _isCurrentDisliked
                                                                            ? 1.0
                                                                            : 0.0,
                                                                        size:
                                                                            isSmall
                                                                            ? 20
                                                                            : 24,
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                          },
                                                        ),

                                                        // Botón Letra
                                                        ValueListenableBuilder<
                                                          bool
                                                        >(
                                                          valueListenable:
                                                              playLoadingNotifier,
                                                          builder: (context, isLoading, _) {
                                                            return AnimatedTapButton(
                                                              onTap: isLoading
                                                                  ? () {}
                                                                  : () async {
                                                                      // Check if lyrics on cover is enabled
                                                                      final prefs =
                                                                          await SharedPreferences.getInstance();
                                                                      final showLyricsOnCover =
                                                                          prefs.getBool(
                                                                            'show_lyrics_on_cover',
                                                                          ) ??
                                                                          false;

                                                                      if (showLyricsOnCover) {
                                                                        // Original behavior: toggle lyrics display on cover
                                                                        if (!_showLyrics) {
                                                                          setState(
                                                                            () {
                                                                              _showLyrics = true;
                                                                            },
                                                                          );
                                                                          await _loadLyrics(
                                                                            currentMediaItem,
                                                                          );
                                                                        } else {
                                                                          setState(
                                                                            () {
                                                                              _showLyrics = false;
                                                                            },
                                                                          );
                                                                        }
                                                                      } else {
                                                                        // New behavior: show lyrics in modal
                                                                        if (!context
                                                                            .mounted) {
                                                                          return;
                                                                        }
                                                                        _showLyricsModal(
                                                                          context,
                                                                          currentMediaItem,
                                                                        );
                                                                      }
                                                                    },
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary.withValues(
                                                                        alpha:
                                                                            0.08,
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        26,
                                                                      ),
                                                                ),
                                                                padding:
                                                                    EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          isSmall
                                                                          ? 14
                                                                          : 20,
                                                                      vertical:
                                                                          6,
                                                                    ),
                                                                margin:
                                                                    EdgeInsets.only(
                                                                      right:
                                                                          isSmall
                                                                          ? 8
                                                                          : 12,
                                                                    ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .lyrics_outlined,
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                      size:
                                                                          isSmall
                                                                          ? 20
                                                                          : 24,
                                                                    ),
                                                                    SizedBox(
                                                                      width:
                                                                          isSmall
                                                                          ? 6
                                                                          : 8,
                                                                    ),
                                                                    Text(
                                                                      LocaleProvider.tr(
                                                                        'lyrics',
                                                                      ),
                                                                      style: TextStyle(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                        fontSize:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),

                                                        // Botón descargar
                                                        if (currentMediaItem
                                                                .extras?['isStreaming'] ==
                                                            true)
                                                          ValueListenableBuilder<
                                                            bool
                                                          >(
                                                            valueListenable:
                                                                playLoadingNotifier,
                                                            builder: (context, isLoading, _) {
                                                              return AnimatedTapButton(
                                                                onTap: isLoading
                                                                    ? () {}
                                                                    : () async {
                                                                        if (!context
                                                                            .mounted) {
                                                                          return;
                                                                        }
                                                                        await _queueStreamingDownload(
                                                                          context,
                                                                          currentMediaItem,
                                                                        );
                                                                      },
                                                                child: Container(
                                                                  decoration: BoxDecoration(
                                                                    color: Theme.of(context)
                                                                        .colorScheme
                                                                        .primary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.08,
                                                                        ),
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          26,
                                                                        ),
                                                                  ),
                                                                  padding: EdgeInsets.symmetric(
                                                                    horizontal:
                                                                        isSmall
                                                                        ? 12
                                                                        : 14,
                                                                    vertical: 6,
                                                                  ),
                                                                  margin: EdgeInsets.only(
                                                                    right:
                                                                        isSmall
                                                                        ? 8
                                                                        : 12,
                                                                  ),
                                                                  child: Row(
                                                                    children: [
                                                                      Icon(
                                                                        Icons
                                                                            .download_rounded,
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                        size:
                                                                            isSmall
                                                                            ? 20
                                                                            : 24,
                                                                      ),
                                                                      SizedBox(
                                                                        width:
                                                                            isSmall
                                                                            ? 6
                                                                            : 8,
                                                                      ),
                                                                      Text(
                                                                        LocaleProvider.tr(
                                                                          'download',
                                                                        ),
                                                                        style: TextStyle(
                                                                          color: Theme.of(
                                                                            context,
                                                                          ).colorScheme.onSurface,
                                                                          fontWeight:
                                                                              FontWeight.w600,
                                                                          fontSize:
                                                                              isSmall
                                                                              ? 12
                                                                              : 14,
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              );
                                                            },
                                                          ),

                                                        // Botón Guardar
                                                        ValueListenableBuilder<
                                                          bool
                                                        >(
                                                          valueListenable:
                                                              playLoadingNotifier,
                                                          builder: (context, isLoading, _) {
                                                            return AnimatedTapButton(
                                                              onTap: isLoading
                                                                  ? () {}
                                                                  : () async {
                                                                      if (!mounted) {
                                                                        return;
                                                                      }

                                                                      final safeContext =
                                                                          context;
                                                                      await _showAddToPlaylistDialog(
                                                                        safeContext,
                                                                        currentMediaItem,
                                                                      );
                                                                    },
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary.withValues(
                                                                        alpha:
                                                                            0.08,
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        26,
                                                                      ),
                                                                ),
                                                                padding:
                                                                    EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          isSmall
                                                                          ? 12
                                                                          : 14,
                                                                      vertical:
                                                                          6,
                                                                    ),
                                                                margin:
                                                                    EdgeInsets.only(
                                                                      right:
                                                                          isSmall
                                                                          ? 8
                                                                          : 12,
                                                                    ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .playlist_add,
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                      size:
                                                                          isSmall
                                                                          ? 20
                                                                          : 24,
                                                                    ),
                                                                    SizedBox(
                                                                      width:
                                                                          isSmall
                                                                          ? 6
                                                                          : 8,
                                                                    ),
                                                                    Text(
                                                                      LocaleProvider.tr(
                                                                        'save',
                                                                      ),
                                                                      style: TextStyle(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                        fontSize:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),

                                                        // Botón Siguientes
                                                        ValueListenableBuilder<
                                                          bool
                                                        >(
                                                          valueListenable:
                                                              playLoadingNotifier,
                                                          builder: (context, isLoading, _) {
                                                            return AnimatedTapButton(
                                                              onTap: isLoading
                                                                  ? () {}
                                                                  : () async {
                                                                      if (!mounted) {
                                                                        return;
                                                                      }

                                                                      final safeContext =
                                                                          context;
                                                                      _showPlaylistDialog(
                                                                        safeContext,
                                                                      );
                                                                    },
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary.withValues(
                                                                        alpha:
                                                                            0.08,
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        26,
                                                                      ),
                                                                ),
                                                                padding:
                                                                    EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          isSmall
                                                                          ? 12
                                                                          : 14,
                                                                      vertical:
                                                                          6,
                                                                    ),
                                                                margin:
                                                                    EdgeInsets.only(
                                                                      right:
                                                                          isSmall
                                                                          ? 8
                                                                          : 12,
                                                                    ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .queue_music,
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                      size:
                                                                          isSmall
                                                                          ? 20
                                                                          : 24,
                                                                    ),
                                                                    SizedBox(
                                                                      width:
                                                                          isSmall
                                                                          ? 6
                                                                          : 8,
                                                                    ),
                                                                    Text(
                                                                      LocaleProvider.tr(
                                                                        'next',
                                                                      ),
                                                                      style: TextStyle(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                        fontSize:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),

                                                        // Botón Compartir
                                                        ValueListenableBuilder<
                                                          bool
                                                        >(
                                                          valueListenable:
                                                              playLoadingNotifier,
                                                          builder: (context, isLoading, _) {
                                                            return AnimatedTapButton(
                                                              onTap: isLoading
                                                                  ? () {}
                                                                  : () async {
                                                                      final isStreaming =
                                                                          currentMediaItem
                                                                              .extras?['isStreaming'] ==
                                                                          true;
                                                                      if (isStreaming) {
                                                                        final shareUrl =
                                                                            await _resolveShareUrl(
                                                                              currentMediaItem,
                                                                            );
                                                                        if (shareUrl !=
                                                                                null &&
                                                                            shareUrl.isNotEmpty) {
                                                                          await SharePlus.instance.share(
                                                                            ShareParams(
                                                                              text: shareUrl,
                                                                            ),
                                                                          );
                                                                        }
                                                                        return;
                                                                      }

                                                                      final dataPath =
                                                                          currentMediaItem.extras?['data']
                                                                              as String?;
                                                                      if (dataPath !=
                                                                              null &&
                                                                          dataPath
                                                                              .isNotEmpty) {
                                                                        await SharePlus.instance.share(
                                                                          ShareParams(
                                                                            text:
                                                                                currentMediaItem.title,
                                                                            files: [
                                                                              XFile(
                                                                                dataPath,
                                                                              ),
                                                                            ],
                                                                          ),
                                                                        );
                                                                      }
                                                                    },
                                                              child: Container(
                                                                decoration: BoxDecoration(
                                                                  color:
                                                                      Theme.of(
                                                                        context,
                                                                      ).colorScheme.primary.withValues(
                                                                        alpha:
                                                                            0.08,
                                                                      ),
                                                                  borderRadius:
                                                                      BorderRadius.circular(
                                                                        26,
                                                                      ),
                                                                ),
                                                                padding:
                                                                    EdgeInsets.symmetric(
                                                                      horizontal:
                                                                          isSmall
                                                                          ? 14
                                                                          : 20,
                                                                      vertical:
                                                                          6,
                                                                    ),
                                                                child: Row(
                                                                  children: [
                                                                    Icon(
                                                                      Icons
                                                                          .share,
                                                                      color: Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface,
                                                                      size:
                                                                          isSmall
                                                                          ? 18
                                                                          : 22,
                                                                    ),
                                                                    SizedBox(
                                                                      width:
                                                                          isSmall
                                                                          ? 6
                                                                          : 8,
                                                                    ),
                                                                    Text(
                                                                      LocaleProvider.tr(
                                                                        'share',
                                                                      ),
                                                                      style: TextStyle(
                                                                        color: Theme.of(
                                                                          context,
                                                                        ).colorScheme.onSurface,
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                        fontSize:
                                                                            isSmall
                                                                            ? 12
                                                                            : 14,
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
                                                        ),
                                                        const SizedBox(
                                                          width: 20,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                      Expanded(
                                        child: Padding(
                                          padding: EdgeInsets.only(
                                            bottom: isSmallScreen
                                                ? height * 0.015
                                                : height * 0.03,
                                            left: isSmallScreen
                                                ? width * 0.005
                                                : width * 0.013,
                                            right: isSmallScreen
                                                ? width * 0.005
                                                : width * 0.013,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            mainAxisSize: MainAxisSize.max,
                                            children: [
                                              const Spacer(),
                                              StreamBuilder<PlaybackState>(
                                                stream:
                                                    audioHandler?.playbackState,
                                                builder: (context, playbackSnapshot) {
                                                  final playbackState =
                                                      playbackSnapshot.data;
                                                  final isPlaying =
                                                      playbackState?.playing ??
                                                      false;

                                                  return ValueListenableBuilder<
                                                    bool
                                                  >(
                                                    valueListenable:
                                                        audioHandler
                                                            .myHandler
                                                            ?.isQueueTransitioning ??
                                                        ValueNotifier(false),
                                                    builder: (context, isTransitioning, _) {
                                                      return StreamBuilder<
                                                        Duration
                                                      >(
                                                        stream: audioHandler
                                                            .myHandler
                                                            ?.positionStream,
                                                        initialData:
                                                            Duration.zero,
                                                        builder: (context, posSnapshot) {
                                                          Duration position =
                                                              posSnapshot
                                                                  .data ??
                                                              Duration.zero;
                                                          if (!isTransitioning) {
                                                            _lastKnownPosition =
                                                                position;
                                                          } else if (_lastKnownPosition !=
                                                              null) {
                                                            position =
                                                                _lastKnownPosition!;
                                                          }
                                                          return StreamBuilder<
                                                            Duration?
                                                          >(
                                                            stream: audioHandler
                                                                .myHandler
                                                                ?.durationStream,
                                                            builder:
                                                                (
                                                                  context,
                                                                  durationSnapshot,
                                                                ) {
                                                                  final fallbackDuration =
                                                                      durationSnapshot
                                                                          .data;
                                                                  final mediaDuration =
                                                                      currentMediaItem
                                                                          .duration;
                                                                  // Si no hay duración, usa 1 segundo como mínimo para el slider
                                                                  final duration =
                                                                      (mediaDuration !=
                                                                              null &&
                                                                          mediaDuration.inMilliseconds >
                                                                              0)
                                                                      ? mediaDuration
                                                                      : (fallbackDuration !=
                                                                                null &&
                                                                            fallbackDuration.inMilliseconds >
                                                                                0)
                                                                      ? fallbackDuration
                                                                      : const Duration(
                                                                          seconds:
                                                                              1,
                                                                        );
                                                                  final durationMs =
                                                                      duration.inMilliseconds >
                                                                          0
                                                                      ? duration
                                                                            .inMilliseconds
                                                                      : 1;
                                                                  final isStreamingItem =
                                                                      currentMediaItem
                                                                          .extras?['isStreaming'] ==
                                                                      true;
                                                                  final bufferedPositionMs =
                                                                      (playbackState?.bufferedPosition.inMilliseconds ??
                                                                              0)
                                                                          .clamp(
                                                                            0,
                                                                            durationMs,
                                                                          )
                                                                          .toDouble();
                                                                  return RepaintBoundary(
                                                                    child: ValueListenableBuilder<double?>(
                                                                      valueListenable:
                                                                          _dragValueSecondsNotifier,
                                                                      builder:
                                                                          (
                                                                            context,
                                                                            dragValueSeconds,
                                                                            _,
                                                                          ) {
                                                                            final sliderValueMs =
                                                                                (dragValueSeconds !=
                                                                                    null)
                                                                                ? (dragValueSeconds *
                                                                                          1000)
                                                                                      .clamp(
                                                                                        0,
                                                                                        durationMs.toDouble(),
                                                                                      )
                                                                                : position.inMilliseconds
                                                                                      .clamp(
                                                                                        0,
                                                                                        durationMs,
                                                                                      )
                                                                                      .toDouble();
                                                                            return Column(
                                                                              children: [
                                                                                SizedBox(
                                                                                  width: progressBarWidth,
                                                                                  child: ClipRect(
                                                                                    child:
                                                                                        TweenAnimationBuilder<
                                                                                          double
                                                                                        >(
                                                                                          duration: const Duration(
                                                                                            milliseconds: 400,
                                                                                          ),
                                                                                          curve: Curves.easeInOut,
                                                                                          tween:
                                                                                              Tween<
                                                                                                double
                                                                                              >(
                                                                                                begin: isPlaying
                                                                                                    ? 0.0
                                                                                                    : 0.0,
                                                                                                end: isPlaying
                                                                                                    ? 3.0
                                                                                                    : 0.0,
                                                                                              ),
                                                                                          builder:
                                                                                              (
                                                                                                context,
                                                                                                amplitude,
                                                                                                child,
                                                                                              ) {
                                                                                                return SquigglySlider(
                                                                                                  trackHeight: 3.0,
                                                                                                  useLineThumb: true,
                                                                                                  min: 0.0,
                                                                                                  max: durationMs.toDouble(),
                                                                                                  value: sliderValueMs.toDouble(),
                                                                                                  secondaryTrackValue: isStreamingItem
                                                                                                      ? bufferedPositionMs
                                                                                                      : null,
                                                                                                  secondaryActiveColor:
                                                                                                      Theme.of(
                                                                                                        context,
                                                                                                      ).colorScheme.primary.withValues(
                                                                                                        alpha: 0.55,
                                                                                                      ),
                                                                                                  inactiveColor:
                                                                                                      Theme.of(
                                                                                                        context,
                                                                                                      ).colorScheme.primary.withValues(
                                                                                                        alpha: 0.3,
                                                                                                      ),
                                                                                                  onChanged:
                                                                                                      (
                                                                                                        value,
                                                                                                      ) {
                                                                                                        _dragValueSecondsNotifier.value =
                                                                                                            value /
                                                                                                            1000.0;
                                                                                                      },
                                                                                                  onChangeEnd:
                                                                                                      (
                                                                                                        value,
                                                                                                      ) {
                                                                                                        final now = DateTime.now();
                                                                                                        final ms = value.toInt();
                                                                                                        if (now
                                                                                                                .difference(
                                                                                                                  _lastSeekTime,
                                                                                                                )
                                                                                                                .inMilliseconds >
                                                                                                            _seekThrottleMs) {
                                                                                                          audioHandler?.seek(
                                                                                                            Duration(
                                                                                                              milliseconds: ms,
                                                                                                            ),
                                                                                                          );
                                                                                                          _lastSeekTime = now;
                                                                                                        } else {
                                                                                                          _lastSeekMs = ms;
                                                                                                          Future.delayed(
                                                                                                            Duration(
                                                                                                              milliseconds: _seekThrottleMs,
                                                                                                            ),
                                                                                                            () {
                                                                                                              if (_lastSeekMs !=
                                                                                                                      null &&
                                                                                                                  DateTime.now()
                                                                                                                          .difference(
                                                                                                                            _lastSeekTime,
                                                                                                                          )
                                                                                                                          .inMilliseconds >=
                                                                                                                      _seekThrottleMs) {
                                                                                                                audioHandler?.seek(
                                                                                                                  Duration(
                                                                                                                    milliseconds: _lastSeekMs!,
                                                                                                                  ),
                                                                                                                );
                                                                                                                _lastSeekTime = DateTime.now();
                                                                                                                _lastSeekMs = null;
                                                                                                              }
                                                                                                            },
                                                                                                          );
                                                                                                        }
                                                                                                        _dragValueSecondsNotifier.value = null;
                                                                                                      },
                                                                                                  squiggleAmplitude: amplitude,
                                                                                                  squiggleWavelength: 6.0,
                                                                                                  squiggleSpeed: 0.05,
                                                                                                );
                                                                                              },
                                                                                        ),
                                                                                  ),
                                                                                ),
                                                                                Padding(
                                                                                  padding: const EdgeInsets.symmetric(
                                                                                    horizontal: 24,
                                                                                  ),
                                                                                  child: Row(
                                                                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                                                    children: [
                                                                                      Text(
                                                                                        _formatDuration(
                                                                                          Duration(
                                                                                            milliseconds: sliderValueMs.toInt(),
                                                                                          ),
                                                                                        ),
                                                                                        style: TextStyle(
                                                                                          fontSize: is16by9
                                                                                              ? 15
                                                                                              : 13,
                                                                                          color:
                                                                                              Theme.of(
                                                                                                context,
                                                                                              ).colorScheme.onSurface.withValues(
                                                                                                alpha: 0.8,
                                                                                              ),
                                                                                        ),
                                                                                      ),
                                                                                      Text(
                                                                                        // Si la duración es desconocida, muestra '--:--'
                                                                                        (mediaDuration ==
                                                                                                    null ||
                                                                                                mediaDuration.inMilliseconds <=
                                                                                                    0)
                                                                                            ? '--:--'
                                                                                            : _formatDuration(
                                                                                                duration,
                                                                                              ),
                                                                                        style: TextStyle(
                                                                                          fontSize: is16by9
                                                                                              ? 15
                                                                                              : 13,
                                                                                          color:
                                                                                              Theme.of(
                                                                                                context,
                                                                                              ).colorScheme.onSurface.withValues(
                                                                                                alpha: 0.8,
                                                                                              ),
                                                                                        ),
                                                                                      ),
                                                                                    ],
                                                                                  ),
                                                                                ),
                                                                              ],
                                                                            );
                                                                          },
                                                                    ),
                                                                  );
                                                                },
                                                          );
                                                        },
                                                      );
                                                    },
                                                  );
                                                },
                                              ),

                                              const Spacer(),
                                              // Controles de reproducción
                                              StreamBuilder<PlaybackState>(
                                                stream:
                                                    audioHandler?.playbackState,
                                                builder: (context, snapshot) {
                                                  final state = snapshot.data;
                                                  final isPlaying =
                                                      state?.playing ?? false;
                                                  final repeatMode =
                                                      state?.repeatMode ??
                                                      AudioServiceRepeatMode
                                                          .none;
                                                  // Detect AMOLED theme to adapt control visibility
                                                  final bool isAmoledTheme =
                                                      colorSchemeNotifier
                                                          .value ==
                                                      AppColorScheme.amoled;

                                                  IconData repeatIcon;
                                                  Color repeatColor;
                                                  switch (repeatMode) {
                                                    case AudioServiceRepeatMode
                                                        .one:
                                                      repeatIcon = Icons
                                                          .repeat_one_rounded;
                                                      repeatColor = Theme.of(
                                                        context,
                                                      ).colorScheme.primary;
                                                      break;
                                                    case AudioServiceRepeatMode
                                                        .all:
                                                      repeatIcon =
                                                          Icons.repeat_rounded;
                                                      repeatColor = Theme.of(
                                                        context,
                                                      ).colorScheme.primary;
                                                      break;
                                                    default:
                                                      repeatIcon =
                                                          Icons.repeat_rounded;
                                                      repeatColor =
                                                          Theme.of(
                                                                context,
                                                              ).brightness ==
                                                              Brightness.light
                                                          ? Theme.of(context)
                                                                .colorScheme
                                                                .onSurface
                                                                .withValues(
                                                                  alpha: 0.9,
                                                                )
                                                          : (isAmoledTheme
                                                                ? Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSurface
                                                                : Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSurface);
                                                  }

                                                  return LayoutBuilder(
                                                    builder: (context, constraints) {
                                                      // Cálculo responsivo de tamaños
                                                      final double
                                                      maxControlsWidth = is16by9
                                                          ? constraints.maxWidth
                                                                .clamp(280, 350)
                                                          : constraints.maxWidth
                                                                .clamp(
                                                                  340,
                                                                  480,
                                                                );

                                                      final double iconSize =
                                                          (maxControlsWidth /
                                                                  400 *
                                                                  38)
                                                              .clamp(30, 54);
                                                      final double
                                                      sideIconSize =
                                                          (maxControlsWidth /
                                                                  400 *
                                                                  56)
                                                              .clamp(42, 76);
                                                      final double
                                                      mainIconSize =
                                                          (maxControlsWidth /
                                                                  400 *
                                                                  76)
                                                              .clamp(60, 100);
                                                      final double
                                                      playIconSize =
                                                          (maxControlsWidth /
                                                                  400 *
                                                                  52)
                                                              .clamp(40, 80);

                                                      return Center(
                                                        child: RepaintBoundary(
                                                          child: Container(
                                                            alignment: Alignment
                                                                .center,
                                                            constraints:
                                                                BoxConstraints(
                                                                  maxWidth:
                                                                      progressBarWidth,
                                                                ),
                                                            child: Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .max,
                                                              children: [
                                                                // Combinar todos los ValueListenableBuilder en uno solo
                                                                ValueListenableBuilder<
                                                                  bool
                                                                >(
                                                                  valueListenable:
                                                                      playLoadingNotifier,
                                                                  builder:
                                                                      (
                                                                        context,
                                                                        isLoading,
                                                                        _,
                                                                      ) {
                                                                        // Mostrar loading siempre que el flujo de reproducción
                                                                        // lo marque, incluso si la canción anterior sigue en play.
                                                                        final isBusy =
                                                                            isLoading;
                                                                        return ValueListenableBuilder<
                                                                          bool
                                                                        >(
                                                                          valueListenable:
                                                                              audioHandler.myHandler?.isShuffleNotifier ??
                                                                              ValueNotifier(
                                                                                false,
                                                                              ),
                                                                          builder:
                                                                              (
                                                                                context,
                                                                                isShuffle,
                                                                                _,
                                                                              ) {
                                                                                return Row(
                                                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                                                  mainAxisSize: MainAxisSize.max,
                                                                                  children: [
                                                                                    (isAmoledTheme &&
                                                                                            isShuffle)
                                                                                        ? Container(
                                                                                            decoration: BoxDecoration(
                                                                                              color: Colors.white.withValues(
                                                                                                alpha: 0.12,
                                                                                              ),
                                                                                              borderRadius: BorderRadius.circular(
                                                                                                12,
                                                                                              ),
                                                                                            ),
                                                                                            child: IconButton(
                                                                                              icon: const Icon(
                                                                                                Icons.shuffle_rounded,
                                                                                                weight: 600,
                                                                                              ),
                                                                                              color: Colors.white,
                                                                                              iconSize: iconSize,
                                                                                              onPressed: () async {
                                                                                                if (isBusy) {
                                                                                                  return;
                                                                                                }
                                                                                                await audioHandler.myHandler?.toggleShuffle(
                                                                                                  !isShuffle,
                                                                                                );
                                                                                              },
                                                                                              tooltip: LocaleProvider.tr(
                                                                                                'shuffle',
                                                                                              ),
                                                                                            ),
                                                                                          )
                                                                                        : IconButton(
                                                                                            icon: const Icon(
                                                                                              Icons.shuffle_rounded,
                                                                                              grade: 200,
                                                                                            ),
                                                                                            color: isShuffle
                                                                                                ? Theme.of(
                                                                                                    context,
                                                                                                  ).colorScheme.primary
                                                                                                : isAmoledTheme
                                                                                                ? Theme.of(
                                                                                                    context,
                                                                                                  ).colorScheme.onSurface
                                                                                                : Theme.of(
                                                                                                        context,
                                                                                                      ).brightness ==
                                                                                                      Brightness.light
                                                                                                ? Theme.of(
                                                                                                    context,
                                                                                                  ).colorScheme.onSurface.withValues(
                                                                                                    alpha: 0.9,
                                                                                                  )
                                                                                                : Theme.of(
                                                                                                    context,
                                                                                                  ).colorScheme.onSurface,
                                                                                            iconSize: iconSize,
                                                                                            onPressed: () async {
                                                                                              if (isBusy) {
                                                                                                return;
                                                                                              }
                                                                                              await audioHandler.myHandler?.toggleShuffle(
                                                                                                !isShuffle,
                                                                                              );
                                                                                            },
                                                                                            tooltip: LocaleProvider.tr(
                                                                                              'shuffle',
                                                                                            ),
                                                                                          ),
                                                                                    SizedBox(
                                                                                      width:
                                                                                          iconSize /
                                                                                          6,
                                                                                    ),
                                                                                    IconButton(
                                                                                      icon: const Icon(
                                                                                        Icons.skip_previous_rounded,
                                                                                        grade: 200,
                                                                                        fill: 1,
                                                                                      ),
                                                                                      color:
                                                                                          Theme.of(
                                                                                                context,
                                                                                              ).brightness ==
                                                                                              Brightness.light
                                                                                          ? Theme.of(
                                                                                              context,
                                                                                            ).colorScheme.onSurface.withValues(
                                                                                              alpha: 0.9,
                                                                                            )
                                                                                          : Theme.of(
                                                                                              context,
                                                                                            ).colorScheme.onSurface,
                                                                                      iconSize: sideIconSize,
                                                                                      onPressed: () {
                                                                                        if (isBusy) {
                                                                                          return;
                                                                                        }
                                                                                        audioHandler?.skipToPrevious();
                                                                                      },
                                                                                    ),
                                                                                    Padding(
                                                                                      padding: EdgeInsets.symmetric(
                                                                                        horizontal:
                                                                                            iconSize /
                                                                                            3,
                                                                                      ),
                                                                                      child: Material(
                                                                                        color: Colors.transparent,
                                                                                        child: InkWell(
                                                                                          customBorder: RoundedRectangleBorder(
                                                                                            borderRadius: BorderRadius.circular(
                                                                                              isPlaying
                                                                                                  ? (mainIconSize /
                                                                                                        3)
                                                                                                  : (mainIconSize /
                                                                                                        2),
                                                                                            ),
                                                                                          ),
                                                                                          splashColor: Colors.transparent,
                                                                                          highlightColor: Colors.transparent,
                                                                                          onTap: () {
                                                                                            if (isBusy) {
                                                                                              return;
                                                                                            }
                                                                                            isPlaying
                                                                                                ? audioHandler?.pause()
                                                                                                : audioHandler?.play();
                                                                                          },
                                                                                          child:
                                                                                              (showBackground ||
                                                                                                      showDynamicBg ||
                                                                                                      isDynamicTheme) &&
                                                                                                  !isBusy
                                                                                              ? SizedBox(
                                                                                                  width: mainIconSize,
                                                                                                  height: mainIconSize,
                                                                                                  child:
                                                                                                      TweenAnimationBuilder<
                                                                                                        double
                                                                                                      >(
                                                                                                        tween:
                                                                                                            Tween<
                                                                                                              double
                                                                                                            >(
                                                                                                              end: isPlaying
                                                                                                                  ? (mainIconSize /
                                                                                                                        3)
                                                                                                                  : (mainIconSize /
                                                                                                                        2),
                                                                                                            ),
                                                                                                        duration: const Duration(
                                                                                                          milliseconds: 250,
                                                                                                        ),
                                                                                                        curve: Curves.easeInOut,
                                                                                                        builder:
                                                                                                            (
                                                                                                              context,
                                                                                                              radius,
                                                                                                              _,
                                                                                                            ) {
                                                                                                              return CustomPaint(
                                                                                                                painter: _HolePunchPainter(
                                                                                                                  color: Theme.of(
                                                                                                                    context,
                                                                                                                  ).colorScheme.onSurface,
                                                                                                                  radius: radius,
                                                                                                                  icon: isPlaying
                                                                                                                      ? Icons.pause_rounded
                                                                                                                      : Icons.play_arrow_rounded,
                                                                                                                  iconSize: playIconSize,
                                                                                                                ),
                                                                                                              );
                                                                                                            },
                                                                                                      ),
                                                                                                )
                                                                                              : AnimatedContainer(
                                                                                                  duration: const Duration(
                                                                                                    milliseconds: 250,
                                                                                                  ),
                                                                                                  curve: Curves.easeInOut,
                                                                                                  width: mainIconSize,
                                                                                                  height: mainIconSize,
                                                                                                  decoration: BoxDecoration(
                                                                                                    color:
                                                                                                        Theme.of(
                                                                                                              context,
                                                                                                            ).brightness ==
                                                                                                            Brightness.light
                                                                                                        ? Theme.of(
                                                                                                            context,
                                                                                                          ).colorScheme.onSurface.withValues(
                                                                                                            alpha: 0.9,
                                                                                                          )
                                                                                                        : Theme.of(
                                                                                                            context,
                                                                                                          ).colorScheme.onSurface,
                                                                                                    borderRadius: BorderRadius.circular(
                                                                                                      isPlaying
                                                                                                          ? (mainIconSize /
                                                                                                                3)
                                                                                                          : (mainIconSize /
                                                                                                                2),
                                                                                                    ),
                                                                                                  ),
                                                                                                  child: Center(
                                                                                                    child: isBusy
                                                                                                        ? SizedBox(
                                                                                                            width:
                                                                                                                playIconSize -
                                                                                                                10,
                                                                                                            height:
                                                                                                                playIconSize -
                                                                                                                10,
                                                                                                            child: CircularProgressIndicator(
                                                                                                              strokeWidth: 5,
                                                                                                              strokeCap: StrokeCap.round,
                                                                                                              color:
                                                                                                                  Theme.of(
                                                                                                                        context,
                                                                                                                      ).brightness ==
                                                                                                                      Brightness.light
                                                                                                                  ? Theme.of(
                                                                                                                      context,
                                                                                                                    ).colorScheme.surface.withValues(
                                                                                                                      alpha: 0.9,
                                                                                                                    )
                                                                                                                  : Theme.of(
                                                                                                                      context,
                                                                                                                    ).colorScheme.surface,
                                                                                                            ),
                                                                                                          )
                                                                                                        : Icon(
                                                                                                            isPlaying
                                                                                                                ? Icons.pause_rounded
                                                                                                                : Icons.play_arrow_rounded,
                                                                                                            size: playIconSize,
                                                                                                            grade: 200,
                                                                                                            fill: 1,
                                                                                                            color:
                                                                                                                (showBackground ||
                                                                                                                    showDynamicBg ||
                                                                                                                    isDynamicTheme)
                                                                                                                ? Colors.black
                                                                                                                : Theme.of(
                                                                                                                        context,
                                                                                                                      ).brightness ==
                                                                                                                      Brightness.light
                                                                                                                ? Theme.of(
                                                                                                                    context,
                                                                                                                  ).colorScheme.surface.withValues(
                                                                                                                    alpha: 0.9,
                                                                                                                  )
                                                                                                                : Theme.of(
                                                                                                                    context,
                                                                                                                  ).colorScheme.surface,
                                                                                                          ),
                                                                                                  ),
                                                                                                ),
                                                                                        ),
                                                                                      ),
                                                                                    ),
                                                                                    IconButton(
                                                                                      icon: const Icon(
                                                                                        Icons.skip_next_rounded,
                                                                                        grade: 200,
                                                                                        fill: 1,
                                                                                      ),
                                                                                      color:
                                                                                          Theme.of(
                                                                                                context,
                                                                                              ).brightness ==
                                                                                              Brightness.light
                                                                                          ? Theme.of(
                                                                                              context,
                                                                                            ).colorScheme.onSurface.withValues(
                                                                                              alpha: 0.9,
                                                                                            )
                                                                                          : Theme.of(
                                                                                              context,
                                                                                            ).colorScheme.onSurface,
                                                                                      iconSize: sideIconSize,
                                                                                      onPressed: () {
                                                                                        if (isBusy) {
                                                                                          return;
                                                                                        }
                                                                                        audioHandler?.skipToNext();
                                                                                      },
                                                                                    ),
                                                                                    SizedBox(
                                                                                      width:
                                                                                          iconSize /
                                                                                          6,
                                                                                    ),
                                                                                    (isAmoledTheme &&
                                                                                            repeatMode !=
                                                                                                AudioServiceRepeatMode.none)
                                                                                        ? Container(
                                                                                            decoration: BoxDecoration(
                                                                                              color: Colors.white.withValues(
                                                                                                alpha: 0.12,
                                                                                              ),
                                                                                              borderRadius: BorderRadius.circular(
                                                                                                12,
                                                                                              ),
                                                                                            ),
                                                                                            child: IconButton(
                                                                                              icon: Icon(
                                                                                                repeatIcon,
                                                                                              ),
                                                                                              color: Colors.white,
                                                                                              iconSize: iconSize,
                                                                                              onPressed: () {
                                                                                                if (isBusy) {
                                                                                                  return;
                                                                                                }
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
                                                                                                audioHandler?.setRepeatMode(
                                                                                                  newMode,
                                                                                                );
                                                                                              },
                                                                                              tooltip: LocaleProvider.tr(
                                                                                                'repeat',
                                                                                              ),
                                                                                            ),
                                                                                          )
                                                                                        : IconButton(
                                                                                            icon: Icon(
                                                                                              repeatIcon,
                                                                                              grade: 200,
                                                                                            ),
                                                                                            color: repeatColor,
                                                                                            iconSize: iconSize,
                                                                                            onPressed: () {
                                                                                              if (isBusy) {
                                                                                                return;
                                                                                              }
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
                                                                                              audioHandler?.setRepeatMode(
                                                                                                newMode,
                                                                                              );
                                                                                            },
                                                                                            tooltip: LocaleProvider.tr(
                                                                                              'repeat',
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
                                                        ),
                                                      );
                                                    },
                                                  );
                                                },
                                              ),
                                              const Spacer(flex: 3),
                                              if (!is16by9 &&
                                                  !isSmallScreen) ...[
                                                Transform.translate(
                                                  offset: Offset(
                                                    0,
                                                    _isGestureNavigation
                                                        ? 18
                                                        : -4,
                                                  ),
                                                  child: SizedBox(
                                                    height: 46,
                                                    child: Stack(
                                                      children: [
                                                        // ── Dispositivo de salida (izquierda) ──
                                                        Align(
                                                          alignment: Alignment
                                                              .centerLeft,
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets.only(
                                                                  left: 20.0,
                                                                ),
                                                            child: FutureBuilder<AudioSession>(
                                                              future:
                                                                  AudioSession
                                                                      .instance,
                                                              builder:
                                                                  (
                                                                    context,
                                                                    sessionSnap,
                                                                  ) {
                                                                    if (!sessionSnap
                                                                        .hasData) {
                                                                      return const SizedBox.shrink();
                                                                    }
                                                                    return StreamBuilder<
                                                                      Set<
                                                                        AudioDevice
                                                                      >
                                                                    >(
                                                                      stream: sessionSnap
                                                                          .data!
                                                                          .devicesStream,
                                                                      builder:
                                                                          (
                                                                            context,
                                                                            snapshot,
                                                                          ) {
                                                                            final devices =
                                                                                (snapshot.data ??
                                                                                        {})
                                                                                    .where(
                                                                                      (
                                                                                        d,
                                                                                      ) => d.isOutput,
                                                                                    )
                                                                                    .toList();

                                                                            AudioDevice?
                                                                            best;
                                                                            best = devices
                                                                                .where(
                                                                                  (
                                                                                    d,
                                                                                  ) =>
                                                                                      d.type ==
                                                                                      AudioDeviceType.bluetoothA2dp,
                                                                                )
                                                                                .firstOrNull;
                                                                            best ??= devices
                                                                                .where(
                                                                                  (
                                                                                    d,
                                                                                  ) =>
                                                                                      d.type ==
                                                                                      AudioDeviceType.bluetoothSco,
                                                                                )
                                                                                .firstOrNull;
                                                                            best ??= devices
                                                                                .where(
                                                                                  (
                                                                                    d,
                                                                                  ) =>
                                                                                      d.type ==
                                                                                          AudioDeviceType.wiredHeadset ||
                                                                                      d.type ==
                                                                                          AudioDeviceType.wiredHeadphones,
                                                                                )
                                                                                .firstOrNull;
                                                                            best ??= devices
                                                                                .where(
                                                                                  (
                                                                                    d,
                                                                                  ) =>
                                                                                      d.type ==
                                                                                      AudioDeviceType.builtInSpeaker,
                                                                                )
                                                                                .firstOrNull;
                                                                            best ??= devices
                                                                                .where(
                                                                                  (
                                                                                    d,
                                                                                  ) =>
                                                                                      d.type ==
                                                                                      AudioDeviceType.builtInEarpiece,
                                                                                )
                                                                                .firstOrNull;

                                                                            final color =
                                                                                Theme.of(
                                                                                  context,
                                                                                ).colorScheme.onSurface.withValues(
                                                                                  alpha: 0.65,
                                                                                );

                                                                            final IconData
                                                                            icon;
                                                                            switch (best?.type) {
                                                                              case AudioDeviceType.bluetoothA2dp:
                                                                              case AudioDeviceType.bluetoothSco:
                                                                              case AudioDeviceType.bluetoothLe:
                                                                                icon = Icons.bluetooth_audio_rounded;
                                                                              case AudioDeviceType.wiredHeadset:
                                                                              case AudioDeviceType.wiredHeadphones:
                                                                                icon = Icons.headphones_rounded;
                                                                              case AudioDeviceType.builtInEarpiece:
                                                                                icon = Icons.phone_in_talk_rounded;
                                                                              default:
                                                                                icon = Icons.volume_up_rounded;
                                                                            }

                                                                            final name =
                                                                                best?.name.trim() ??
                                                                                '';

                                                                            return Row(
                                                                              mainAxisSize: MainAxisSize.min,
                                                                              children: [
                                                                                Icon(
                                                                                  icon,
                                                                                  size: 18,
                                                                                  color: color,
                                                                                ),
                                                                                if (name.isNotEmpty) ...[
                                                                                  const SizedBox(
                                                                                    width: 4,
                                                                                  ),
                                                                                  Text(
                                                                                    name,
                                                                                    style: TextStyle(
                                                                                      fontSize: 11,
                                                                                      color: color,
                                                                                      fontWeight: FontWeight.w500,
                                                                                    ),
                                                                                    maxLines: 1,
                                                                                    overflow: TextOverflow.ellipsis,
                                                                                  ),
                                                                                ],
                                                                              ],
                                                                            );
                                                                          },
                                                                    );
                                                                  },
                                                            ),
                                                          ),
                                                        ),
                                                        // ── Timer y Playlist (derecha) ──
                                                        Align(
                                                          alignment: Alignment
                                                              .centerRight,
                                                          child: Padding(
                                                            padding:
                                                                const EdgeInsets.only(
                                                                  right: 20.0,
                                                                ),
                                                            child: StreamBuilder<int>(
                                                              stream:
                                                                  Stream.periodic(
                                                                    const Duration(
                                                                      seconds:
                                                                          1,
                                                                    ),
                                                                    (i) => i,
                                                                  ),
                                                              builder: (context, _) {
                                                                final sleepTimer =
                                                                    audioHandler
                                                                        ?.myHandler
                                                                        ?.sleepTimeRemaining;
                                                                final hasTimer =
                                                                    sleepTimer !=
                                                                    null;
                                                                return Row(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    // Timer
                                                                    Material(
                                                                      color: Theme.of(context)
                                                                          .colorScheme
                                                                          .primary
                                                                          .withValues(
                                                                            alpha:
                                                                                0.08,
                                                                          ),
                                                                      borderRadius: const BorderRadius.only(
                                                                        topLeft:
                                                                            Radius.circular(
                                                                              24,
                                                                            ),
                                                                        bottomLeft:
                                                                            Radius.circular(
                                                                              24,
                                                                            ),
                                                                        topRight:
                                                                            Radius.circular(
                                                                              6,
                                                                            ),
                                                                        bottomRight:
                                                                            Radius.circular(
                                                                              6,
                                                                            ),
                                                                      ),
                                                                      child: InkWell(
                                                                        onTap: () {
                                                                          showModalBottomSheet(
                                                                            context:
                                                                                context,
                                                                            backgroundColor:
                                                                                Colors.transparent,
                                                                            builder:
                                                                                (
                                                                                  context,
                                                                                ) => const SleepTimerOptionsSheet(),
                                                                          );
                                                                        },
                                                                        borderRadius: const BorderRadius.only(
                                                                          topLeft: Radius.circular(
                                                                            24,
                                                                          ),
                                                                          bottomLeft: Radius.circular(
                                                                            24,
                                                                          ),
                                                                          topRight:
                                                                              Radius.circular(
                                                                                6,
                                                                              ),
                                                                          bottomRight:
                                                                              Radius.circular(
                                                                                6,
                                                                              ),
                                                                        ),
                                                                        child: Padding(
                                                                          padding: EdgeInsets.only(
                                                                            left:
                                                                                14,
                                                                            right:
                                                                                hasTimer
                                                                                ? 10
                                                                                : 12,
                                                                            top:
                                                                                8,
                                                                            bottom:
                                                                                8,
                                                                          ),
                                                                          child: Row(
                                                                            mainAxisSize:
                                                                                MainAxisSize.min,
                                                                            children: [
                                                                              Icon(
                                                                                hasTimer
                                                                                    ? Icons.timer
                                                                                    : Icons.timer_outlined,
                                                                                color: Theme.of(
                                                                                  context,
                                                                                ).colorScheme.onSurface,
                                                                                size: 18,
                                                                              ),
                                                                              if (hasTimer) ...[
                                                                                const SizedBox(
                                                                                  width: 4,
                                                                                ),
                                                                                Text(
                                                                                  _formatSleepTimerDuration(
                                                                                    sleepTimer,
                                                                                  ),
                                                                                  style: TextStyle(
                                                                                    color: Theme.of(
                                                                                      context,
                                                                                    ).colorScheme.onSurface,
                                                                                    fontSize: 11,
                                                                                    fontWeight: FontWeight.w600,
                                                                                  ),
                                                                                ),
                                                                              ],
                                                                            ],
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 4,
                                                                    ),
                                                                    // Playlist
                                                                    Material(
                                                                      color: Theme.of(context)
                                                                          .colorScheme
                                                                          .primary
                                                                          .withValues(
                                                                            alpha:
                                                                                0.08,
                                                                          ),
                                                                      borderRadius: const BorderRadius.only(
                                                                        topLeft:
                                                                            Radius.circular(
                                                                              6,
                                                                            ),
                                                                        bottomLeft:
                                                                            Radius.circular(
                                                                              6,
                                                                            ),
                                                                        topRight:
                                                                            Radius.circular(
                                                                              24,
                                                                            ),
                                                                        bottomRight:
                                                                            Radius.circular(
                                                                              24,
                                                                            ),
                                                                      ),
                                                                      child: InkWell(
                                                                        onTap: () {
                                                                          if (_playlistPanelController
                                                                              .isAttached) {
                                                                            setState(() {
                                                                              _panelContent = PanelContent.playlist;
                                                                              _playlistResetCounter++;
                                                                            });
                                                                            _playlistPanelController.open();
                                                                          }
                                                                        },
                                                                        borderRadius: const BorderRadius.only(
                                                                          topLeft:
                                                                              Radius.circular(
                                                                                6,
                                                                              ),
                                                                          bottomLeft:
                                                                              Radius.circular(
                                                                                6,
                                                                              ),
                                                                          topRight: Radius.circular(
                                                                            24,
                                                                          ),
                                                                          bottomRight: Radius.circular(
                                                                            24,
                                                                          ),
                                                                        ),
                                                                        child: Padding(
                                                                          padding: const EdgeInsets.only(
                                                                            left:
                                                                                12,
                                                                            right:
                                                                                14,
                                                                            top:
                                                                                8,
                                                                            bottom:
                                                                                8,
                                                                          ),
                                                                          child: Icon(
                                                                            Icons.queue_music_rounded,
                                                                            color: Theme.of(
                                                                              context,
                                                                            ).colorScheme.onSurface,
                                                                            size:
                                                                                18,
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );

    Widget gestureWidget;
    if (widget.onClose != null) {
      gestureWidget = Listener(
        onPointerDown: (event) {
          _dragStartY = event.position.dy;
        },
        onPointerUp: (event) {
          if (_dragStartY != null) {
            // Ignorar si empezó cerca del borde inferior (gesto del sistema)
            if (_dragStartY! > MediaQuery.of(context).size.height - 50) {
              _dragStartY = null;
              return;
            }
            final dy = event.position.dy - _dragStartY!;
            // Swipe up: abrir playlist
            if (dy < -50 &&
                !_disableOpenPlaylistGesture &&
                (widget.panelPositionNotifier == null ||
                    widget.panelPositionNotifier!.value >= 0.95)) {
              if (_playlistPanelController.isAttached) {
                setState(() {
                  _panelContent = PanelContent.playlist;
                  _playlistResetCounter++;
                });
                _playlistPanelController.open();
              }
            }
            _dragStartY = null;
          }
        },
        child: streamContent,
      );
    } else {
      gestureWidget = GestureDetector(
        onVerticalDragStart: (details) {
          _dragStartY = details.globalPosition.dy;
        },
        onVerticalDragUpdate: (details) {
          if (_dragStartY != null &&
              _dragStartY! > MediaQuery.of(context).size.height - 50) {
            return;
          }
          if (details.primaryDelta != null && details.primaryDelta! < -6) {
            if (!_disableOpenPlaylistGesture &&
                (widget.panelPositionNotifier == null ||
                    widget.panelPositionNotifier!.value >= 0.95)) {
              if (_playlistPanelController.isAttached) {
                setState(() {
                  _panelContent = PanelContent.playlist;
                  _playlistResetCounter++;
                });
                _playlistPanelController.open();
              }
            }
          }
        },
        child: streamContent,
      );
    }

    return PopScope(
      canPop: !_isPlaylistPanelOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_playlistPanelController.isAttached) {
          _playlistPanelController.close();
        }
      },
      child: standard_panel.SlidingUpPanel(
        controller: _playlistPanelController,
        minHeight: 0,
        maxHeight: MediaQuery.of(context).size.height,
        backdropEnabled: false,
        renderPanelSheet: false,
        onPanelSlide: (position) {
          // Actualizar estado del playlist y notificar al padre
          final isOpen = position > 0.001;
          if (_isPlaylistPanelOpen != isOpen) {
            setState(() {
              _isPlaylistPanelOpen = isOpen;
            });
            widget.onPlaylistStateChanged?.call(isOpen);
          }

          final shouldHidePlayer = position >= 0.98;
          if (_hidePlayerContentNotifier.value != shouldHidePlayer) {
            _hidePlayerContentNotifier.value = shouldHidePlayer;
          }

          final shouldHidePanel = position <= 0.005;
          if (shouldHidePanel) {
            if (_hidePanelTimer == null && !_hidePanelContentNotifier.value) {
              _hidePanelTimer = Timer(const Duration(seconds: 1), () {
                if (mounted) {
                  _hidePanelContentNotifier.value = true;
                }
                _hidePanelTimer = null;
              });
            }
          } else {
            _hidePanelTimer?.cancel();
            _hidePanelTimer = null;
            if (_hidePanelContentNotifier.value) {
              _hidePanelContentNotifier.value = false;
            }
          }
        },
        panelBuilder: (sc) {
          return ValueListenableBuilder<bool>(
            valueListenable: _hidePanelContentNotifier,
            builder: (context, hide, _) {
              if (hide) {
                return const SizedBox.shrink();
              }

              return _panelContent == PanelContent.lyrics
                  ? CurrentLyricsScreen(
                      key: ValueKey('lyrics_$_lyricsResetCounter'),
                      currentMediaItem: audioHandler?.mediaItem.valueOrNull,
                      panelController: _playlistPanelController,
                    )
                  : StreamBuilder<List<MediaItem>>(
                      stream: audioHandler?.queue,
                      initialData: const [],
                      builder: (context, snapshot) {
                        final queue = audioHandler is MyAudioHandler
                            ? audioHandler.myHandler!.effectiveQueue
                            : snapshot.data ?? [];

                        final currentMediaItem =
                            audioHandler?.mediaItem.valueOrNull;
                        final playbackQueueIndex =
                            audioHandler?.playbackState.valueOrNull?.queueIndex;
                        final hasValidPlaybackQueueIndex =
                            playbackQueueIndex != null &&
                            playbackQueueIndex >= 0 &&
                            playbackQueueIndex < queue.length;
                        final currentIndex = hasValidPlaybackQueueIndex
                            ? playbackQueueIndex
                            : queue.indexWhere(
                                (item) => item.id == currentMediaItem?.id,
                              );

                        return CurrentPlaylistScreen(
                          key: ValueKey('playlist_$_playlistResetCounter'),
                          queue: queue,
                          currentMediaItem: currentMediaItem,
                          currentIndex: currentIndex,
                          scrollController: sc,
                          panelController: _playlistPanelController,
                        );
                      },
                    );
            },
          );
        },
        body: ValueListenableBuilder<bool>(
          valueListenable: _hidePlayerContentNotifier,
          builder: (context, hide, child) {
            return Visibility(
              visible: !hide,
              maintainState: true,
              maintainAnimation: false,
              maintainSize: false,
              child: child!,
            );
          },
          child: gestureWidget,
        ),
      ),
    );
  }

  Future<void> _showLyricsModal(
    BuildContext context,
    MediaItem mediaItem,
  ) async {
    setState(() {
      _panelContent = PanelContent.lyrics;
      _lyricsResetCounter++;
    });
    if (_playlistPanelController.isAttached) {
      _playlistPanelController.open();
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
  bool _isLongPress = false;

  void _handleTapDown(TapDownDetails details) {
    setState(() {
      _pressed = true;
      _isLongPress = true;
    });
  }

  void _handleTapUp(TapUpDetails details) {
    if (_isLongPress) {
      setState(() => _pressed = false);
    }
    _isLongPress = false;
  }

  void _handleTapCancel() {
    setState(() {
      _pressed = false;
      _isLongPress = false;
    });
  }

  void _handleTap() {
    // Si no fue un long press, hacer la animación automática
    if (!_isLongPress) {
      setState(() => _pressed = true);
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          setState(() => _pressed = false);
        }
      });
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: _handleTap,
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

  void _setTimer(BuildContext context, [Duration? duration]) {
    audioHandler.myHandler?.startSleepTimer(duration);
    Navigator.of(context).pop();
  }

  Color normalizePaletteColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    // Si la saturación original es muy baja (gris/blanco/negro), mantenerla baja
    // para evitar colorear artificialmente imágenes en escala de grises.
    final isGrayscale = hsl.saturation < 0.15;

    // Si es muy oscuro (negro), forzar un poco de luminosidad para que se vea
    double effectiveLightness = hsl.lightness;
    if (effectiveLightness < 0.15) {
      effectiveLightness = 0.15;
    }

    // Ajustar el brillo: bajamos el rango para que el color sea más "rico"
    // y no se vea pálido (pastel), permitiendo que la saturación resalte.
    // Brillo dinámico: Si el color original es muy oscuro, le damos un pequeño boost
    // para que se note. Si es muy claro, lo oscurecemos para que no se vea pálido.
    double targetLightness;
    if (hsl.lightness < 0.2) {
      // Colores muy oscuros: subirlos un poco menos (0.18 - 0.28)
      targetLightness = 0.18 + (hsl.lightness * 0.5);
    } else if (hsl.lightness > 0.5) {
      // Colores muy claros: bajarlos más (0.3 - 0.4)
      targetLightness = 0.3 + (hsl.lightness * 0.1);
    } else {
      // Colores medios: rango más bajo
      targetLightness = hsl.lightness.clamp(0.2, 0.4);
    }

    final fixedLightness = targetLightness.clamp(0.15, 0.36);

    // Saturación extrema mantenida para que el color explote
    final fixedSaturation = isGrayscale
        ? hsl.saturation
        : (hsl.saturation * 1.7).clamp(0.8, 1.0);

    return hsl
        .withLightness(fixedLightness)
        .withSaturation(fixedSaturation)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        useDynamicColorBackgroundNotifier,
        useDynamicColorInDialogsNotifier,
        colorSchemeNotifier,
      ]),
      builder: (context, _) {
        return Builder(
          builder: (context) {
            final useDynamicBg = useDynamicColorBackgroundNotifier.value;
            final useDynamicDialogs = useDynamicColorInDialogsNotifier.value;
            final colorScheme = colorSchemeNotifier.value;
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final showDynamicBg =
                (useDynamicBg || useDynamicDialogs) && isAmoled && isDark;

            return Material(
              color: showDynamicBg
                  ? Colors.black
                  : Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  if (showDynamicBg)
                    ValueListenableBuilder<Color?>(
                      valueListenable: ThemeController.instance.dominantColor,
                      builder: (context, domColor, _) {
                        return Positioned.fill(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeInOut,
                            color: normalizePaletteColor(
                              domColor ?? Colors.black,
                            ).withValues(alpha: 0.35),
                          ),
                        );
                      },
                    ),
                  SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 12),
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
                        ListTile(
                          title: Text(LocaleProvider.tr('one_minute')),
                          onTap: () =>
                              _setTimer(context, const Duration(minutes: 1)),
                        ),
                        ListTile(
                          title: Text(LocaleProvider.tr('five_minutes')),
                          onTap: () =>
                              _setTimer(context, const Duration(minutes: 5)),
                        ),
                        ListTile(
                          title: Text(LocaleProvider.tr('fifteen_minutes')),
                          onTap: () =>
                              _setTimer(context, const Duration(minutes: 15)),
                        ),
                        ListTile(
                          title: Text(LocaleProvider.tr('thirty_minutes')),
                          onTap: () =>
                              _setTimer(context, const Duration(minutes: 30)),
                        ),
                        ListTile(
                          title: Text(LocaleProvider.tr('one_hour')),
                          onTap: () =>
                              _setTimer(context, const Duration(minutes: 60)),
                        ),
                        ListTile(
                          title: Text(LocaleProvider.tr('until_song_ends')),
                          onTap: () => _setTimer(context),
                        ),
                        const Divider(),
                        ListTile(
                          title: Text(LocaleProvider.tr('cancel_timer')),
                          onTap: () {
                            audioHandler.myHandler?.cancelSleepTimer();
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
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
        child: Stack(
          children: [
            ShaderMask(
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
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  top: 60,
                  bottom: 0,
                  left: 10,
                  right: 10,
                ),
                itemCount: lines.length,
                itemBuilder: (context, index) {
                  final isCurrent = index == idx;
                  final isDarkMode =
                      Theme.of(context).brightness == Brightness.dark;
                  final textStyle = TextStyle(
                    color: isCurrent
                        ? (isDarkMode
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.primaryContainer)
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
          ],
        ),
      ),
    );
  }
}

// Only keep the closing brace for _PlaylistListView if necessary but deleting it all

class _HolePunchPainter extends CustomPainter {
  final Color color;
  final double radius;
  final IconData icon;
  final double iconSize;

  _HolePunchPainter({
    required this.color,
    required this.radius,
    required this.icon,
    required this.iconSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      paint,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: iconSize,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          foreground: Paint()..blendMode = BlendMode.dstOut,
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();
    final center = Offset(
      (size.width - textPainter.width) / 2,
      (size.height - textPainter.height) / 2,
    );
    textPainter.paint(canvas, center);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HolePunchPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.icon != icon;
  }
}

// Widget para renderizar blur estático (pre-cacheado como imagen)
class _StaticBlurImage extends StatefulWidget {
  final ImageProvider imageProvider;
  final double width;
  final double height;
  final double scale;
  final ui.Image? cachedImage;
  final ValueChanged<ui.Image> onImageCached;

  const _StaticBlurImage({
    required this.imageProvider,
    required this.width,
    required this.height,
    required this.scale,
    this.cachedImage,
    required this.onImageCached,
  });

  @override
  State<_StaticBlurImage> createState() => _StaticBlurImageState();
}

class _StaticBlurImageState extends State<_StaticBlurImage> {
  ui.Image? _blurredImage;
  bool _isLoading = false;

  Rect _centerSquareRect(ui.Image image) {
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    final side = imageW < imageH ? imageW : imageH;
    final left = (imageW - side) / 2;
    final top = (imageH - side) / 2;
    return Rect.fromLTWH(left, top, side, side);
  }

  @override
  void initState() {
    super.initState();
    _blurredImage = widget.cachedImage;
    if (_blurredImage == null) {
      _loadAndBlurImage();
    }
  }

  @override
  void didUpdateWidget(_StaticBlurImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si cambió la imagen o no tenemos cache, cargar de nuevo
    if (oldWidget.imageProvider != widget.imageProvider ||
        _blurredImage == null) {
      _loadAndBlurImage();
    }
  }

  Future<void> _loadAndBlurImage() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Cargar la imagen
      final ImageStream stream = widget.imageProvider.resolve(
        const ImageConfiguration(),
      );

      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;

      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (exception, stackTrace) {
          completer.completeError(exception);
          stream.removeListener(listener);
        },
      );

      stream.addListener(listener);

      final image = await completer.future;

      // Renderizar el blur en una imagen estática
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint();

      // Aplicar blur usando ImageFilter
      final blurFilter = ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9);
      canvas.saveLayer(
        Offset.zero & Size(widget.width, widget.height),
        paint..imageFilter = blurFilter,
      );

      // Recorte 1:1 centrado (4:4) y luego ajuste cover al fondo.
      final baseSrcRect = _centerSquareRect(image);
      final outputRect = Rect.fromLTWH(0, 0, widget.width, widget.height);
      final fittedSizes = applyBoxFit(
        BoxFit.cover,
        baseSrcRect.size,
        outputRect.size,
      );
      final srcRect = Alignment.center.inscribe(
        fittedSizes.source,
        baseSrcRect,
      );
      final dstRect = Alignment.center.inscribe(
        fittedSizes.destination,
        outputRect,
      );
      canvas.drawImageRect(
        image,
        srcRect,
        dstRect,
        Paint()..filterQuality = FilterQuality.low,
      );

      canvas.restore();

      // Convertir a imagen
      final picture = recorder.endRecording();
      final blurredImage = await picture.toImage(
        widget.width.toInt(),
        widget.height.toInt(),
      );

      if (mounted) {
        setState(() {
          _blurredImage = blurredImage;
          _isLoading = false;
        });

        // Notificar al padre para cachear la imagen
        widget.onImageCached(blurredImage);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blurredImage == null) {
      // Mientras carga, mostrar el blur dinámico (solo la primera vez)
      return RepaintBoundary(
        child: Transform.scale(
          scale: widget.scale,
          child: Center(
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
                child: Image(
                  image: widget.imageProvider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Mostrar la imagen con blur pre-renderizada (estática)
    return RepaintBoundary(
      child: Transform.scale(
        scale: widget.scale,
        child: Center(
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: CustomPaint(
              painter: _BlurredImagePainter(_blurredImage!),
              size: Size(widget.width, widget.height),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // No disposear la imagen cacheada, se reutiliza
    super.dispose();
  }
}

// CustomPainter para dibujar la imagen con blur pre-renderizada
class _BlurredImagePainter extends CustomPainter {
  final ui.Image blurredImage;

  _BlurredImagePainter(this.blurredImage);

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(
      0,
      0,
      blurredImage.width.toDouble(),
      blurredImage.height.toDouble(),
    );
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      blurredImage,
      srcRect,
      dstRect,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _BlurredImagePainter oldDelegate) {
    return oldDelegate.blurredImage != blurredImage;
  }
}
