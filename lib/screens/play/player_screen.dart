import 'package:flutter/material.dart';
import 'package:music/widgets/marquee.dart';
import 'package:music/main.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:share_plus/share_plus.dart';
import 'package:music/widgets/slider.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';
import 'dart:math';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/widgets/song_info_dialog.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/gesture_preferences.dart';
import 'package:music/screens/artist/artist_screen.dart';
import 'package:music/screens/play/lyrics_search_screen.dart';
import 'package:like_button/like_button.dart';

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

  const FullPlayerScreen({
    super.key,
    this.initialMediaItem,
    this.initialArtworkUri,
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
  bool _disableClosePlayerGesture = false;
  bool _disableOpenPlaylistGesture = false;
  bool _disableChangeSongGesture = false;
  String? _lastArtworkSongId;
  
  // Control de indicadores de doble toque
  bool _showDoubleTapIndicators = false;
  bool _showLeftIndicator = false;
  bool _showRightIndicator = false;
  Timer? _hideIndicatorsTimer;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;


  // Flag para usar initialArtworkUri solo en el primer build
  // bool _usedInitialArtwork = false;
  // Optimizaciones de rendimiento
  late final Future<SharedPreferences> _prefsFuture;
  final ValueNotifier<double?> _dragValueSecondsNotifier =
      ValueNotifier<double?>(null);
  String? _currentSongDataPath;
  bool _isCurrentFavorite = false;
  final int _lyricsUpdateCounter = 0;
  final ValueNotifier<int> _lyricsUpdateNotifier = ValueNotifier<int>(0);

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
    final artUri = mediaItem.artUri;
    
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
            errorBuilder: (context, error, stackTrace) => _defaultArtwork(size),
          ),
        );
      }
      
      // Si es una URL de red, usar Image.network con optimizaciones
      if (scheme == 'http' || scheme == 'https') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            artUri.toString(),
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
                    child: const CircularProgressIndicator(
                      // ignore: deprecated_member_use
                      year2023: false,
                    ),
                  ),
            // Optimización: Cache de imagen
            cacheWidth: (size * MediaQuery.of(context).devicePixelRatio).round(),
            cacheHeight: (size * MediaQuery.of(context).devicePixelRatio).round(),
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
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
      ),
    );
  }

  Widget _buildModalArtwork(MediaItem mediaItem) {
    final artUri = mediaItem.artUri;
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
        return Image.network(
          artUri.toString(),
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildModalPlaceholder(),
          loadingBuilder: (context, child, loadingProgress) =>
              loadingProgress == null
              ? child
              : Container(
                  width: 60,
                  height: 60,
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(),
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
        color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.music_note, size: 30),
    );
  }

  Future<void> _searchSongOnYouTube(MediaItem mediaItem) async {
    try {
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
  Future<void> _searchSongOnYouTubeMusic(MediaItem mediaItem) async {
    try {
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
      final ytMusicSearchUrl = 'https://music.youtube.com/search?q=$encodedQuery';

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
            
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: TranslatedText(
                  'search_song',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          SizedBox(width: 4),
                          TranslatedText(
                            'search_options',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de YouTube
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTube(mediaItem);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Image.asset(
                                'assets/icon/Youtube_logo.png',
                                width: 30,
                                height: 30,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'YouTube',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de YouTube Music
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _searchSongOnYouTubeMusic(mediaItem);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2) // Borde personalizado para amoled
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Image.asset(
                                'assets/icon/Youtube_Music_icon.png',
                                width: 30,
                                height: 30,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'YT Music',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white // Texto blanco para amoled
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
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

    final result = await SyncedLyricsService.getSyncedLyricsWithResult(mediaItem);
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
    _setupLyricsUpdateListener();
    
    // Inicializar animación de fade
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));
    
    // Eliminado: _loadQueueSource();
    // Eliminado: (audioHandler as MyAudioHandler).queueSourceNotifier.addListener(_onQueueSourceChanged);
  }

  /// Configura el listener para actualizaciones de letras
  void _setupLyricsUpdateListener() {
    lyricsUpdatedNotifier.addListener(_onLyricsUpdated);
  }

  /// Maneja las actualizaciones de letras
  void _onLyricsUpdated() {
    final songId = lyricsUpdatedNotifier.value;
    if (songId != null) {
      // Limpiar cache de letras para forzar recarga
      _lyricsCache.remove(songId);
      // Limpiar el valor después de un delay para asegurar que el ValueListenableBuilder lo procese
      Future.delayed(Duration(milliseconds: 200), () {
        lyricsUpdatedNotifier.value = null;
      });
    }
  }

  /// Carga las preferencias de gestos
  Future<void> _loadGesturePreferences() async {
    final preferences = await GesturePreferences.getAllGesturePreferences();
    if (mounted) {
      setState(() {
        _disableClosePlayerGesture = preferences['closePlayer'] ?? false;
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
    getOrCacheArtwork(songId, songPath).then((artUri) {
      if (artUri != null && mounted) {
        // Forzar rebuild para mostrar la carátula cargada
        setState(() {});
      }
    }).catchError((error) {
      // print('❌ Error cargando carátula en player screen: $error');
    });
  }

  /// Maneja el cambio de carátula cuando cambia la canción
  void _handleArtworkChange(MediaItem? newMediaItem) {
    final newSongId =
        newMediaItem?.extras?['songId']?.toString() ?? newMediaItem?.id;

    if (_lastArtworkSongId != newSongId) {
      _lastArtworkSongId = newSongId;
      
      // Verificar si la carátula está disponible inmediatamente
      if (newMediaItem != null) {
        final songId = newMediaItem.extras?['songId'] as int?;
        final songPath = newMediaItem.extras?['data'] as String?;
        final hasArtUri = newMediaItem.artUri != null;
        final hasCachedArtwork = songPath != null ? _getCachedArtwork(songPath) != null : false;
        
        // Solo mostrar loading si no hay carátula disponible en ningún lugar
        _artworkLoadingNotifier.value = !hasArtUri && !hasCachedArtwork;
        
        // Precargar carátula en background si no está disponible
        if (!hasArtUri && !hasCachedArtwork && songId != null && songPath != null) {
          _preloadArtworkInBackground(songId, songPath);
        }
      } else {
        _artworkLoadingNotifier.value = false;
      }
    } else if (newMediaItem?.artUri != null && _artworkLoadingNotifier.value) {
      // La carátula acaba de llegar para la canción actual
      _artworkLoadingNotifier.value = false;
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
        }
      } catch (e) {
        // Error silencioso - no afectar la UI
      }
    });
  }

  @override
  void dispose() {
    _seekDebounceTimer?.cancel();
    _hideIndicatorsTimer?.cancel();
    _fadeController.dispose();
    _lyricsScrollController.dispose();
    _dragValueSecondsNotifier.dispose();
    _artworkLoadingNotifier.dispose();
    _lyricsUpdateNotifier.dispose();
    lyricsUpdatedNotifier.removeListener(_onLyricsUpdated);
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
                        child: _buildModalArtwork(mediaItem),
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
                                LocaleProvider.tr('unknown_artist'),
                            style: TextStyle(fontSize: 14),
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
                        await _showSearchOptions(mediaItem);
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                                context,
                            ).brightness == Brightness.dark
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color: Theme.of(
                                context,
                              ).brightness == Brightness.dark
                              ? Theme.of(context).colorScheme.onPrimaryContainer
                              : Theme.of(context).colorScheme.surfaceContainer,
                            ),
                            const SizedBox(width: 8),
                            TranslatedText(
                              'search',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: Theme.of(
                                    context,
                                ).brightness == Brightness.dark
                                ? Theme.of(context).colorScheme.onPrimaryContainer
                                : Theme.of(context).colorScheme.surfaceContainer,
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
                leading: Icon(
                  isFav ? Icons.delete_outline : Symbols.favorite_rounded,
                  weight: isFav ? null : 600,
                ),
                title: Text(
                  isFav
                      ? LocaleProvider.tr('remove_from_favorites')
                      : LocaleProvider.tr('add_to_favorites'),
                ),
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
              if ((mediaItem.artist ?? '').trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const TranslatedText('go_to_artist'),
                  onTap: () {
                    Navigator.of(context).pop();
                    final name = (mediaItem.artist ?? '').trim();
                    if (name.isEmpty) return;
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            ArtistScreen(artistName: name),
                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
              FutureBuilder<bool>(
                future: ShortcutsDB().isShortcut(
                  mediaItem.extras?['data'] ?? '',
                ),
                builder: (context, snapshot) {
                  final isCurrentlyPinned = snapshot.data ?? false;
                  final path = mediaItem.extras?['data'] ?? '';

                  return ListTile(
                    leading: Icon(
                      isCurrentlyPinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                    ),
                    title: Text(
                      isCurrentlyPinned
                          ? LocaleProvider.tr('unpin_shortcut')
                          : LocaleProvider.tr('pin_shortcut'),
                    ),
                    onTap: () async {
                      Navigator.of(context).pop();

                      if (path.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
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
                        await shortcutsDB.removeShortcut(path);
                        // Notificar que los accesos directos han cambiado
                        shortcutsShouldReload.value =
                            !shortcutsShouldReload.value;
                      } else {
                        // Fijar en accesos directos
                        await shortcutsDB.addShortcut(path);
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
                title: Text(LocaleProvider.tr('show_lyrics')),
                onTap: () async {
                  Navigator.of(context).pop();
                  
                  // Check if lyrics on cover is enabled
                  final prefs = await SharedPreferences.getInstance();
                  final showLyricsOnCover = prefs.getBool('show_lyrics_on_cover') ?? false;
                  
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
              ValueListenableBuilder<double>(
                valueListenable: (audioHandler as MyAudioHandler).volumeBoostNotifier,
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
                      (audioHandler as MyAudioHandler).sleepTimeRemaining !=
                      null;
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
                onTap: () async {
                  Navigator.of(context).pop();
                  await SongInfoDialog.show(context, mediaItem, colorSchemeNotifier);
                },
              ),
            ],
          ),
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
      builder: (context) => SafeArea(
        child: Padding(
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
                  color: Theme.of(context).colorScheme.surfaceContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
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
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
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
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
            TextButton(
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
                          content: Text(LocaleProvider.tr('error_audiohandler_not_available')),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                    return;
                  }
                  
                  await (audioHandler as MyAudioHandler).setVolumeBoost(tempBoost);
                  
                  // print('🎵 Volume boost aplicado exitosamente');
                  
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                } catch (e) {
                  // print('❌ Error en el botón de volume boost: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${LocaleProvider.tr('error_applying_volume_boost')}: $e'),
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

  void _showPlaylistDialog(BuildContext context) {
    final queue = audioHandler?.queue.value;
    // Usar el área disponible excluyendo la barra de estado
    final maxHeight = MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      isScrollControlled: true,
      // Asegurar que el modal respete la barra de estado
      useSafeArea: true,
      builder: (context) {
        return Container(
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
        );
      },
    );
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
          // Deslizar hacia abajo: cerrar (solo si no está desactivado)
          if (!_disableClosePlayerGesture) {
            Navigator.of(context).maybePop();
          }
        } else if (details.primaryDelta != null && details.primaryDelta! < -6) {
          // Deslizar hacia arriba: mostrar lista de reproducción (solo si no está desactivado)
          if (!_disableOpenPlaylistGesture) {
            showModalBottomSheet(
              context: context,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              isScrollControlled: true,
              // Asegurar que el modal respete la barra de estado
              useSafeArea: true,
            builder: (context) {
              final queue = audioHandler?.queue.value;
              // Usar el área disponible excluyendo la barra de estado
              final maxHeight = MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top;
              return Container(
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
              );
            },
          );
        }
        }
      },
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler?.mediaItem,
        initialData: widget.initialMediaItem,
        builder: (context, snapshot) {
          final mediaItem = snapshot.data;

          // Solo manejar cambio de carátula cuando realmente cambia la canción
          if (mediaItem != null && mediaItem.id != _lastMediaItemId) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _handleArtworkChange(mediaItem);
            });
          }

          // Solo procesar si es una canción nueva
          if (mediaItem != null && mediaItem.id != _lastMediaItemId) {
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

            // Calcular favorito una sola vez por canción para evitar consultas repetidas
            final path = mediaItem.extras?['data'] as String?;
            unawaited(() async {
              bool fav = false;
              if (path != null &&
                  path.isNotEmpty &&
                  !(mediaItem.extras?['isStreaming'] == true)) {
                try {
                  fav = await FavoritesDB().isFavorite(path);
                } catch (_) {}
              }
              if (!mounted) return;
              if (_currentSongDataPath != path || _isCurrentFavorite != fav) {
                setState(() {
                  _currentSongDataPath = path;
                  _isCurrentFavorite = fav;
                });
              }
            }());
          }

          // Usar el MediaItem inicial si no hay uno actual
          final currentMediaItem = mediaItem ?? widget.initialMediaItem;

          return PopScope(
            canPop: !playLoadingNotifier.value,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop && !playLoadingNotifier.value) {
                Navigator.of(context).pop();
              }
            },
            child: Scaffold(
              appBar: AppBar(
                backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
              scrolledUnderElevation: 0,
                leading: ValueListenableBuilder<bool>(
                  valueListenable: playLoadingNotifier,
                  builder: (context, isLoading, _) {
                    return IconButton(
                      iconSize: 38,
                      icon: const Icon(Icons.keyboard_arrow_down),
                      onPressed: isLoading
                          ? null
                          : () => Navigator.of(context).pop(),
                    );
                  },
                ),
                title: FutureBuilder<SharedPreferences>(
                  future: _prefsFuture,
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
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.color
                                          ?.withValues(alpha: 0.5),
                                      fontWeight: FontWeight.normal,
                                    ),
                              ),
                              TextSpan(
                                text: queueSource,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.color
                                          ?.withValues(alpha: 0.7),
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
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onHorizontalDragEnd: (details) {
                                    // Detectar la dirección del deslizamiento horizontal solo en la carátula
                                    // Solo si el gesto de cambiar canción no está desactivado
                                    if (!_disableChangeSongGesture && details.primaryVelocity != null) {
                                      if (details.primaryVelocity! > 0) {
                                        // Deslizar hacia la derecha: canción anterior
                                        audioHandler?.skipToPrevious();
                                      } else if (details.primaryVelocity! < 0) {
                                        // Deslizar hacia la izquierda: siguiente canción
                                        audioHandler?.skipToNext();
                                      }
                                    }
                                  },
                                  onTap: () async {
                                    // Check if lyrics on cover is enabled
                                    final prefs = await SharedPreferences.getInstance();
                                    final showLyricsOnCover = prefs.getBool('show_lyrics_on_cover') ?? false;
                                    
                                    if (showLyricsOnCover) {
                                      // Original behavior: toggle lyrics display on cover
                                      setState(() {
                                        _showLyrics = !_showLyrics;
                                      });

                                      // Always load lyrics when enabling, to ensure they match current song
                                      if (_showLyrics &&
                                          !_loadingLyrics &&
                                          currentMediaItem != null) {
                                        _loadLyrics(currentMediaItem);
                                      }
                                    }
                                    // Cuando las letras se muestran en modal, no hacer nada con el tap simple
                                    // Solo el doble toque funciona para controlar la reproducción
                                  },
                                  onDoubleTapDown: (details) async {
                                    // Solo activar cuando las letras se muestran en modal
                                    final prefs = await SharedPreferences.getInstance();
                                    final showLyricsOnCover = prefs.getBool('show_lyrics_on_cover') ?? false;
                                    
                                    if (!showLyricsOnCover) {
                                      // Obtener la posición del tap relativa al centro de la carátula
                                      if (!context.mounted) return;
                                      final RenderBox renderBox = context.findRenderObject() as RenderBox;
                                      final localPosition = renderBox.globalToLocal(details.globalPosition);
                                      final centerX = renderBox.size.width / 2;
                                      
                                      // Obtener la posición actual de reproducción
                                      final currentPosition = (audioHandler as MyAudioHandler).player.position;
                                      
                                      // Cancelar timer anterior si existe
                                      _hideIndicatorsTimer?.cancel();
                                      
                                      if (localPosition.dx < centerX) {
                                        // Doble toque en el lado izquierdo: retroceder 10 segundos
                                        setState(() {
                                          _showDoubleTapIndicators = true;
                                          _showLeftIndicator = true;
                                          _showRightIndicator = false;
                                        });
                                        
                                        // Aparecer inmediatamente (sin animación)
                                        _fadeController.value = 1.0;
                                        
                                        final newPosition = currentPosition - const Duration(seconds: 10);
                                        if (newPosition.inMilliseconds >= 0) {
                                          audioHandler?.seek(newPosition);
                                        } else {
                                          audioHandler?.seek(Duration.zero);
                                        }
                                      } else {
                                        // Doble toque en el lado derecho: avanzar 10 segundos
                                        setState(() {
                                          _showDoubleTapIndicators = true;
                                          _showLeftIndicator = false;
                                          _showRightIndicator = true;
                                        });
                                        
                                        // Aparecer inmediatamente (sin animación)
                                        _fadeController.value = 1.0;
                                        
                                        final newPosition = currentPosition + const Duration(seconds: 10);
                                        // No hay límite superior, se puede avanzar más allá de la duración
                                        audioHandler?.seek(newPosition);
                                      }
                                      
                                      // Iniciar animación de desvanecimiento después de 1.5 segundos
                                      _hideIndicatorsTimer = Timer(const Duration(milliseconds: 1500), () {
                                        if (mounted) {
                                          _fadeController.reverse().then((_) {
                                            if (mounted) {
                                              setState(() {
                                                _showDoubleTapIndicators = false;
                                                _showLeftIndicator = false;
                                                _showRightIndicator = false;
                                              });
                                            }
                                          });
                                        }
                                      });
                                    }
                                  },
                                  child: RepaintBoundary(
                                    child: ValueListenableBuilder<bool>(
                                      valueListenable: _artworkLoadingNotifier,
                                      builder: (context, isArtworkLoading, child) {
                                        return FutureBuilder<bool>(
                                          future: SharedPreferences.getInstance().then((prefs) => 
                                            prefs.getBool('show_lyrics_on_cover') ?? false),
                                          builder: (context, snapshot) {
                                            final showLyricsOnCover = snapshot.data ?? false;
                                            
                                            return Stack(
                                              children: [
                                                ArtworkHeroCached(
                                                  artUri: currentMediaItem!.artUri,
                                                  size: artworkSize,
                                                  borderRadius: BorderRadius.circular(
                                                    artworkSize * 0.06,
                                                  ),
                                                  heroTag:
                                                      'now_playing_artwork_${(currentMediaItem.extras?['songId'] ?? currentMediaItem.id).toString()}',
                                                  showPlaceholderIcon: !_showLyrics,
                                                  songPath: currentMediaItem.extras?['data'] as String?,
                                                ),
                                                // Indicadores de doble toque solo cuando las letras se muestran en modal y se ha hecho doble toque
                                                if (!showLyricsOnCover && _showDoubleTapIndicators)
                                                  Positioned.fill(
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        borderRadius: BorderRadius.circular(
                                                          artworkSize * 0.06,
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
                                                                builder: (context, child) {
                                                                  return Opacity(
                                                                    opacity: _fadeAnimation.value,
                                                                    child: Center(
                                                                      child: Container(
                                                                        width: 50,
                                                                        height: 50,
                                                                        decoration: BoxDecoration(
                                                                          color: Colors.black.withValues(alpha: 0.5),
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
                                                                builder: (context, child) {
                                                                  return Opacity(
                                                                    opacity: _fadeAnimation.value,
                                                                    child: Center(
                                                                      child: Container(
                                                                        width: 50,
                                                                        height: 50,
                                                                        decoration: BoxDecoration(
                                                                          color: Colors.black.withValues(alpha: 0.5),
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
                                            );
                                          },
                                        );
                                      },
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
                                    _showLyrics = !_showLyrics;
                                  });
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    artworkSize * 0.06,
                                  ),
                                  child: RepaintBoundary(
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
                                          ? _noConnection
                                              ? Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      LocaleProvider.tr(
                                                        'lyrics_no_connection',
                                                      ),
                                                      style: const TextStyle(
                                                        color: Colors.white70,
                                                        fontSize: 16,
                                                      ),
                                                      textAlign: TextAlign.center,
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
                                                    color: Colors.white,
                                                    fontSize: 16,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                )
                                          : StreamBuilder<Duration>(
                                              stream:
                                                  (audioHandler
                                                          as MyAudioHandler)
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
                                                  currentLyricIndex:
                                                      _currentLyricIndex,
                                                  context: context,
                                                  artworkSize: artworkSize,
                                                );
                                              },
                                            ),
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
                          width: width * 0.85,
                          child: TitleMarquee(
                            text: currentMediaItem!.title,
                            maxWidth: artworkSize,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                  fontSize: buttonFontSize + 0.75,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        SizedBox(height: height * 0.001),
                        SizedBox(
                          width: width * 0.85,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (currentMediaItem.artist == null ||
                                          currentMediaItem.artist!.trim().isEmpty)
                                      ? LocaleProvider.tr('unknown_artist')
                                      : currentMediaItem.artist!,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        fontWeight: FontWeight.w400,
                                        fontSize: 18,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.left,
                                ),
                              ),
                              SizedBox(width: width * 0.04),
                              Builder(
                                builder: (context) {
                                  final isFav = _isCurrentFavorite;
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: playLoadingNotifier,
                                    builder: (context, isLoading, _) {
                                      return LikeButton(
                                        key: ValueKey('like_button_$_currentSongDataPath'),
                                        isLiked: isFav,
                                        size: 32,
                                        animationDuration: const Duration(milliseconds: 800),
                                        circleColor: CircleColor(
                                          start: Theme.of(context).brightness == Brightness.dark 
                                              ? Colors.white 
                                              : Colors.black,
                                          end: Theme.of(context).brightness == Brightness.dark 
                                              ? Colors.white 
                                              : Colors.black,
                                        ),
                                        bubblesColor: BubblesColor(
                                          dotPrimaryColor: Theme.of(context).brightness == Brightness.dark 
                                              ? Colors.white 
                                              : Colors.black,
                                          dotSecondaryColor: Theme.of(context).brightness == Brightness.dark 
                                              ? Colors.white 
                                              : Colors.black,
                                        ),
                                        likeBuilder: (bool isLiked) {
                                          return Icon(
                                            isLiked
                                                ? Symbols.favorite_rounded
                                                : Symbols.favorite_border_rounded,
                                            grade: 200,
                                            fill: isLiked ? 1 : 0,
                                            size: 32,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                          );
                                        },
                                        onTap: (isLiked) async {
                                          if (isLoading) return false;
                                          
                                          final path =
                                              currentMediaItem
                                                  .extras?['data'] ??
                                              '';
                                          if (path.isEmpty) return false;
                                          
                                          if (isLiked) {
                                            await FavoritesDB()
                                                .removeFavorite(path);
                                            favoritesShouldReload.value =
                                                !favoritesShouldReload.value;
                                            if (!context.mounted) return false;
                                            setState(() {
                                              _isCurrentFavorite = false;
                                            });
                                            return false; // Cambiar a no favorito
                                          } else {
                                            final allSongs = await _audioQuery
                                                .querySongs();
                                            final songList = allSongs
                                                .where((s) => s.data == path)
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
                                              return false; // Mantener estado actual
                                            }
                                            final song = songList.first;
                                            await _addToFavorites(song);
                                            if (!context.mounted) return false;
                                            setState(() {
                                              _isCurrentFavorite = true;
                                            });
                                            return true; // Cambiar a favorito
                                          }
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: height * 0.015),
                        // Barra de progreso + tiempos
                        StreamBuilder<PlaybackState>(
                          stream: audioHandler?.playbackState,
                          builder: (context, playbackSnapshot) {
                            final playbackState = playbackSnapshot.data;
                            final isPlaying = playbackState?.playing ?? false;

                            return ValueListenableBuilder<bool>(
                              valueListenable: (audioHandler as MyAudioHandler)
                                  .isQueueTransitioning,
                              builder: (context, isTransitioning, _) {
                                return StreamBuilder<Duration>(
                                  stream: (audioHandler as MyAudioHandler)
                                      .positionStream,
                                  initialData: Duration.zero,
                                  builder: (context, posSnapshot) {
                                    Duration position =
                                        posSnapshot.data ?? Duration.zero;
                                    if (!isTransitioning) {
                                      _lastKnownPosition = position;
                                    } else if (_lastKnownPosition != null) {
                                      position = _lastKnownPosition!;
                                    }
                                    return StreamBuilder<Duration?>(
                                      stream: (audioHandler as MyAudioHandler)
                                          .player
                                          .durationStream,
                                      builder: (context, durationSnapshot) {
                                        final fallbackDuration =
                                            durationSnapshot.data;
                                        final mediaDuration =
                                            currentMediaItem.duration;
                                        // Si no hay duración, usa 1 segundo como mínimo para el slider
                                        final duration =
                                            (mediaDuration != null &&
                                                mediaDuration.inMilliseconds >
                                                    0)
                                            ? mediaDuration
                                            : (fallbackDuration != null &&
                                                  fallbackDuration
                                                          .inMilliseconds >
                                                      0)
                                            ? fallbackDuration
                                            : const Duration(seconds: 1);
                                        final durationMs =
                                            duration.inMilliseconds > 0
                                            ? duration.inMilliseconds
                                            : 1;
                                        return RepaintBoundary(
                                          child: ValueListenableBuilder<double?>(
                                            valueListenable:
                                                _dragValueSecondsNotifier,
                                            builder: (context, dragValueSeconds, _) {
                                              final sliderValueMs =
                                                  (dragValueSeconds != null)
                                                  ? (dragValueSeconds * 1000)
                                                        .clamp(
                                                          0,
                                                          durationMs.toDouble(),
                                                        )
                                                  : position.inMilliseconds
                                                        .clamp(0, durationMs)
                                                        .toDouble();
                                              return Column(
                                                children: [
                                                  SizedBox(
                                                    width: progressBarWidth,
                                                    child: ClipRect(
                                                      child: TweenAnimationBuilder<double>(
                                                      duration: const Duration(
                                                        milliseconds: 400,
                                                      ),
                                                      curve: Curves.easeInOut,
                                                      tween: Tween<double>(
                                                        begin: isPlaying
                                                            ? 0.0
                                                            : 0.0,
                                                        end: isPlaying
                                                            ? 3.0
                                                            : 0.0,
                                                      ),
                                                      builder: (context, amplitude, child) {
                                                        return SquigglySlider(
                                                          min: 0.0,
                                                          max: durationMs
                                                              .toDouble(),
                                                          value: sliderValueMs
                                                              .toDouble(),
                                                          inactiveColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                                          onChanged: (value) {
                                                            _dragValueSecondsNotifier
                                                                    .value =
                                                                value / 1000.0;
                                                          },
                                                          onChangeEnd: (value) {
                                                            final now =
                                                                DateTime.now();
                                                            final ms = value
                                                                .toInt();
                                                            if (now
                                                                    .difference(
                                                                      _lastSeekTime,
                                                                    )
                                                                    .inMilliseconds >
                                                                _seekThrottleMs) {
                                                              audioHandler?.seek(
                                                                Duration(
                                                                  milliseconds:
                                                                      ms,
                                                                ),
                                                              );
                                                              _lastSeekTime =
                                                                  now;
                                                            } else {
                                                              _lastSeekMs = ms;
                                                              Future.delayed(
                                                                Duration(
                                                                  milliseconds:
                                                                      _seekThrottleMs,
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
                                                                        milliseconds:
                                                                            _lastSeekMs!,
                                                                      ),
                                                                    );
                                                                    _lastSeekTime =
                                                                        DateTime.now();
                                                                    _lastSeekMs =
                                                                        null;
                                                                  }
                                                                },
                                                              );
                                                            }
                                                            _dragValueSecondsNotifier
                                                                    .value =
                                                                null;
                                                          },
                                                          squiggleAmplitude:
                                                              amplitude,
                                                          squiggleWavelength:
                                                              6.0,
                                                          squiggleSpeed: 0.05,
                                                        );
                                                      },
                                                    ),
                                                    ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 24,
                                                        ),
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(
                                                          _formatDuration(
                                                            Duration(
                                                              milliseconds:
                                                                  sliderValueMs
                                                                      .toInt(),
                                                            ),
                                                          ),
                                                          style: TextStyle(
                                                            fontSize: is16by9
                                                                ? 18
                                                                : 15,
                                                          ),
                                                        ),
                                                        Text(
                                                          // Si la duración es desconocida, muestra '--:--'
                                                          (mediaDuration ==
                                                                      null ||
                                                                  mediaDuration
                                                                          .inMilliseconds <=
                                                                      0)
                                                              ? '--:--'
                                                              : _formatDuration(
                                                                  duration,
                                                                ),
                                                          style: TextStyle(
                                                            fontSize: is16by9
                                                                ? 18
                                                                : 15,
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
                                state?.repeatMode ??
                                AudioServiceRepeatMode.none;
                            // Detect AMOLED theme to adapt control visibility
                            final bool isAmoledTheme =
                                colorSchemeNotifier.value ==
                                AppColorScheme.amoled;

                            IconData repeatIcon;
                            Color repeatColor;
                            switch (repeatMode) {
                              case AudioServiceRepeatMode.one:
                                repeatIcon = Symbols.repeat_one_rounded;
                                repeatColor = Theme.of(
                                  context,
                                ).colorScheme.primary;
                                break;
                              case AudioServiceRepeatMode.all:
                                repeatIcon = Symbols.repeat_rounded;
                                repeatColor = Theme.of(
                                  context,
                                ).colorScheme.primary;
                                break;
                              default:
                                repeatIcon = Symbols.repeat_rounded;
                                repeatColor =
                                    Theme.of(context).brightness ==
                                        Brightness.light
                                    ? Theme.of(context).colorScheme.onSurface
                                          .withValues(alpha: 0.9)
                                    : (isAmoledTheme
                                          ? Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.7)
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface);
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
                                    (maxControlsWidth / 400 * 76).clamp(
                                      60,
                                      100,
                                    );
                                final double playIconSize =
                                    (maxControlsWidth / 400 * 52).clamp(40, 80);

                                return Center(
                                  child: RepaintBoundary(
                                    child: Container(
                                      alignment: Alignment.center,
                                      constraints: BoxConstraints(
                                        maxWidth: progressBarWidth,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        mainAxisSize: MainAxisSize.max,
                                        children: [
                                          // Combinar todos los ValueListenableBuilder en uno solo
                                          ValueListenableBuilder<bool>(
                                            valueListenable:
                                                playLoadingNotifier,
                                            builder: (context, isLoading, _) {
                                              return ValueListenableBuilder<
                                                bool
                                              >(
                                                valueListenable:
                                                    (audioHandler
                                                            as MyAudioHandler)
                                                        .isShuffleNotifier,
                                                builder: (context, isShuffle, _) {
                                                  return Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    mainAxisSize:
                                                        MainAxisSize.max,
                                                    children: [
                                                      (isAmoledTheme &&
                                                              isShuffle)
                                                          ? Container(
                                                              decoration: BoxDecoration(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.12,
                                                                    ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      12,
                                                                    ),
                                                              ),
                                                              child: IconButton(
                                                                icon: const Icon(
                                                                  Symbols.shuffle_rounded,
                                                                  weight: 600,
                                                                ),
                                                                color: Colors
                                                                    .white,
                                                                iconSize:
                                                                    iconSize,
                                                                onPressed: () async {
                                                                  if (isLoading) {
                                                                    return;
                                                                  }
                                                                  await (audioHandler
                                                                          as MyAudioHandler)
                                                                      .toggleShuffle(
                                                                        !isShuffle,
                                                                      );
                                                                },
                                                                tooltip:
                                                                    LocaleProvider.tr(
                                                                      'shuffle',
                                                                    ),
                                                              ),
                                                            )
                                                          : IconButton(
                                                              icon: const Icon(
                                                                Symbols.shuffle_rounded,
                                                                grade: 200,
                                                              ),
                                                              color: isShuffle
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .primary
                                                                  : isAmoledTheme
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onSurface
                                                                        .withValues(
                                                                          alpha:
                                                                              0.7,
                                                                        )
                                                                  : Theme.of(
                                                                          context,
                                                                        ).brightness ==
                                                                        Brightness
                                                                            .light
                                                                  ? Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onSurface
                                                                        .withValues(
                                                                          alpha:
                                                                              0.9,
                                                                        )
                                                                  : Theme.of(
                                                                          context,
                                                                        )
                                                                        .colorScheme
                                                                        .onSurface,
                                                              iconSize:
                                                                  iconSize,
                                                              onPressed: () async {
                                                                if (isLoading) {
                                                                  return;
                                                                }
                                                                await (audioHandler
                                                                        as MyAudioHandler)
                                                                    .toggleShuffle(
                                                                      !isShuffle,
                                                                    );
                                                              },
                                                              tooltip:
                                                                  LocaleProvider.tr(
                                                                    'shuffle',
                                                                  ),
                                                            ),
                                                      IconButton(
                                                        icon: const Icon(
                                                          Symbols.skip_previous_rounded,
                                                          grade: 200,
                                                          fill: 1,
                                                        ),
                                                        color:
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
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurface,
                                                        iconSize: sideIconSize,
                                                        onPressed: () {
                                                          if (isLoading) return;
                                                          audioHandler
                                                              ?.skipToPrevious();
                                                        },
                                                      ),
                                                      Padding(
                                                        padding:
                                                            EdgeInsets.symmetric(
                                                              horizontal:
                                                                  iconSize / 4,
                                                            ),
                                                        child: Material(
                                                          color: Colors
                                                              .transparent,
                                                          child: InkWell(
                                                            customBorder: RoundedRectangleBorder(
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    isPlaying
                                                                        ? (mainIconSize /
                                                                              3)
                                                                        : (mainIconSize /
                                                                              2),
                                                                  ),
                                                            ),
                                                            splashColor: Colors
                                                                .transparent,
                                                            highlightColor:
                                                                Colors
                                                                    .transparent,
                                                            onTap: () {
                                                              if (isLoading) {
                                                                return;
                                                              }
                                                              isPlaying
                                                                  ? audioHandler
                                                                        ?.pause()
                                                                  : audioHandler
                                                                        ?.play();
                                                            },
                                                            child: AnimatedContainer(
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        250,
                                                                  ),
                                                              curve: Curves
                                                                  .easeInOut,
                                                              width:
                                                                  mainIconSize,
                                                              height:
                                                                  mainIconSize,
                                                              decoration: BoxDecoration(
                                                                color:
                                                                    Theme.of(
                                                                          context,
                                                                        ).brightness ==
                                                                        Brightness
                                                                            .light
                                                                    ? Theme.of(
                                                                        context,
                                                                      ).colorScheme.onSurface.withValues(
                                                                        alpha:
                                                                            0.9,
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
                                                                child: isLoading
                                                                    ? SizedBox(
                                                                        width:
                                                                            playIconSize -
                                                                            10,
                                                                        height:
                                                                            playIconSize -
                                                                            10,
                                                                        child: CircularProgressIndicator(
                                                                          strokeWidth:
                                                                              5,
                                                                          strokeCap:
                                                                              StrokeCap.round,
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
                                                                        isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                                                                        size:
                                                                            playIconSize,
                                                                        grade: 200,
                                                                        fill: 1,
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
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      IconButton(
                                                        icon: const Icon(
                                                          Symbols.skip_next_rounded,
                                                          grade: 200,
                                                          fill: 1,
                                                        ),
                                                        color:
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
                                                            : Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurface,
                                                        iconSize: sideIconSize,
                                                        onPressed: () {
                                                          if (isLoading) return;
                                                          audioHandler
                                                              ?.skipToNext();
                                                        },
                                                      ),
                                                      (isAmoledTheme &&
                                                              repeatMode !=
                                                                  AudioServiceRepeatMode
                                                                      .none)
                                                          ? Container(
                                                              decoration: BoxDecoration(
                                                                color: Colors
                                                                    .white
                                                                    .withValues(
                                                                      alpha:
                                                                          0.12,
                                                                    ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      12,
                                                                    ),
                                                              ),
                                                              child: IconButton(
                                                                icon: Icon(
                                                                  repeatIcon,
                                                                ),
                                                                color: Colors
                                                                    .white,
                                                                iconSize:
                                                                    iconSize,
                                                                onPressed: () {
                                                                  if (isLoading) {
                                                                    return;
                                                                  }
                                                                  AudioServiceRepeatMode
                                                                  newMode;
                                                                  if (repeatMode ==
                                                                      AudioServiceRepeatMode
                                                                          .none) {
                                                                    newMode =
                                                                        AudioServiceRepeatMode
                                                                            .all;
                                                                  } else if (repeatMode ==
                                                                      AudioServiceRepeatMode
                                                                          .all) {
                                                                    newMode =
                                                                        AudioServiceRepeatMode
                                                                            .one;
                                                                  } else {
                                                                    newMode =
                                                                        AudioServiceRepeatMode
                                                                            .none;
                                                                  }
                                                                  audioHandler
                                                                      ?.setRepeatMode(
                                                                        newMode,
                                                                      );
                                                                },
                                                                tooltip:
                                                                    LocaleProvider.tr(
                                                                      'repeat',
                                                                    ),
                                                              ),
                                                            )
                                                          : IconButton(
                                                              icon: Icon(
                                                                repeatIcon,
                                                                grade: 200,
                                                              ),
                                                              color:
                                                                  repeatColor,
                                                              iconSize:
                                                                  iconSize,
                                                              onPressed: () {
                                                                if (isLoading) {
                                                                  return;
                                                                }
                                                                AudioServiceRepeatMode
                                                                newMode;
                                                                if (repeatMode ==
                                                                    AudioServiceRepeatMode
                                                                        .none) {
                                                                  newMode =
                                                                      AudioServiceRepeatMode
                                                                          .all;
                                                                } else if (repeatMode ==
                                                                    AudioServiceRepeatMode
                                                                        .all) {
                                                                  newMode =
                                                                      AudioServiceRepeatMode
                                                                          .one;
                                                                } else {
                                                                  newMode =
                                                                      AudioServiceRepeatMode
                                                                          .none;
                                                                }
                                                                audioHandler
                                                                    ?.setRepeatMode(
                                                                      newMode,
                                                                    );
                                                              },
                                                              tooltip:
                                                                  LocaleProvider.tr(
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

                        if (!is16by9 && !isSmallScreen) ...[
                          SizedBox(
                            height: is18by9
                                ? 20
                                : is195by9
                                ? 34
                                : 16,
                          ),
                          SafeArea(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final isSmall = constraints.maxWidth < 380;
                                return SizedBox(
                                  width: width * 0.85,
                                  child: HorizontalScrollWithFade(
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        // Botón Siguientes
                                        ValueListenableBuilder<bool>(
                                          valueListenable: playLoadingNotifier,
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
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(26),
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
                                                      Icons.queue_music,
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.onSurface,
                                                      size: isSmall ? 20 : 24,
                                                    ),
                                                    SizedBox(
                                                      width: isSmall ? 6 : 8,
                                                    ),
                                                    Text(
                                                      LocaleProvider.tr('next'),
                                                      style: TextStyle(
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: isSmall
                                                            ? 14
                                                            : 16,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),

                                        // Botón Guardar
                                        ValueListenableBuilder<bool>(
                                          valueListenable: playLoadingNotifier,
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
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(26),
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
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.onSurface,
                                                      size: isSmall ? 20 : 24,
                                                    ),
                                                    SizedBox(
                                                      width: isSmall ? 6 : 8,
                                                    ),
                                                    Text(
                                                      LocaleProvider.tr('save'),
                                                      style: TextStyle(
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: isSmall
                                                            ? 14
                                                            : 16,
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
                                              onTap: isLoading
                                                  ? () {}
                                                  : () async {
                                                      // Check if lyrics on cover is enabled
                                                      final prefs = await SharedPreferences.getInstance();
                                                      final showLyricsOnCover = prefs.getBool('show_lyrics_on_cover') ?? false;
                                                      
                                                      if (showLyricsOnCover) {
                                                        // Original behavior: toggle lyrics display on cover
                                                        if (!_showLyrics) {
                                                          setState(() {
                                                            _showLyrics = true;
                                                          });
                                                          await _loadLyrics(
                                                            currentMediaItem,
                                                          );
                                                        } else {
                                                          setState(() {
                                                            _showLyrics = false;
                                                          });
                                                        }
                                                      } else {
                                                        // New behavior: show lyrics in modal
                                                        if (!context.mounted) return;
                                                        _showLyricsModal(context, currentMediaItem);
                                                      }
                                                    },
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(26),
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
                                                      Icons.lyrics_outlined,
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.onSurface,
                                                      size: isSmall ? 20 : 24,
                                                    ),
                                                    SizedBox(
                                                      width: isSmall ? 6 : 8,
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
                                                        fontSize: isSmall
                                                            ? 14
                                                            : 16,
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
                                              onTap: isLoading
                                                  ? () {}
                                                  : () async {
                                                      // Acción del botón
                                                    },
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.08),
                                                  borderRadius:
                                                      BorderRadius.circular(26),
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: isSmall ? 14 : 20,
                                                  vertical: 16,
                                                ),
                                                child: InkWell(
                                                  splashColor:
                                                      Colors.transparent,
                                                  highlightColor:
                                                      Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(26),
                                                  onTap: () async {
                                                    final dataPath =
                                                        currentMediaItem
                                                                .extras?['data']
                                                            as String?;
                                                    if (dataPath != null &&
                                                        dataPath.isNotEmpty) {
                                                      await SharePlus.instance
                                                          .share(
                                                            ShareParams(
                                                              text:
                                                                  currentMediaItem
                                                                      .title,
                                                              files: [
                                                                XFile(dataPath),
                                                              ],
                                                            ),
                                                          );
                                                    }
                                                  },
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        Icons.share,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                        size: isSmall ? 18 : 22,
                                                      ),
                                                      SizedBox(
                                                        width: isSmall ? 6 : 8,
                                                      ),
                                                      Text(
                                                        LocaleProvider.tr(
                                                          'share',
                                                        ),
                                                        style: TextStyle(
                                                          color:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurface,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          fontSize: isSmall
                                                              ? 14
                                                              : 16,
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
      ),
    );
  }

  // Cache para evitar cargar letras repetidamente
  final Map<String, Future<LyricsResult>> _lyricsCache = {};

  Future<LyricsResult> _loadLyricsWithDelay(MediaItem mediaItem) async {
    final cacheKey = mediaItem.id;
    
    // Si ya está en cache, usar ese Future
    if (_lyricsCache.containsKey(cacheKey)) {
      return await _lyricsCache[cacheKey]!;
    }
    
    // Crear nuevo Future y cachearlo
    final future = _loadLyricsInternal(mediaItem);
    _lyricsCache[cacheKey] = future;
    
    return await future;
  }

  Future<LyricsResult> _loadLyricsInternal(MediaItem mediaItem) async {
    // Add a minimal delay to let the modal open completely
    await Future.delayed(Duration(milliseconds: 100));
    // Then load the lyrics
    return await SyncedLyricsService.getSyncedLyricsWithResult(mediaItem);
  }


  Future<void> _showLyricsModal(BuildContext context, MediaItem mediaItem) async {
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      useSafeArea: true,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height - MediaQuery.of(context).padding.top,
              ),
              child: StreamBuilder<MediaItem?>(
                stream: audioHandler?.mediaItem.distinct((prev, next) => prev?.id == next?.id),
                builder: (context, mediaSnapshot) {
                  final currentMediaItem = mediaSnapshot.data ?? mediaItem;
                  
                  return Column(
                    children: [
                      // Handle bar
                      Container(
                        margin: EdgeInsets.symmetric(vertical: 8),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      // Song Info Header
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            // Album Artwork
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                width: 52,
                                height: 52,
                                child: _buildLyricsModalArtwork(currentMediaItem),
                              ),
                            ),
                            SizedBox(width: 12),
                            // Song Info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TitleMarquee(
                                    text: currentMediaItem.title,
                                    maxWidth: MediaQuery.of(context).size.width - 140, // Account for artwork, spacing, and play button
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                  Text(
                                    currentMediaItem.artist ?? LocaleProvider.tr('unknown_artist'),
                                    style: TextStyle(
                                      fontSize: 14,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            // Buttons Row
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Lyrics Search Button
                                IconButton(
                                  onPressed: () async {
                                    // Cerrar el modal de letras antes de abrir la pantalla de búsqueda
                                    Navigator.of(context).pop();
                                    await Navigator.of(context).push(
                                      PageRouteBuilder(
                                        pageBuilder: (context, animation, secondaryAnimation) =>
                                            LyricsSearchScreen(
                                              currentSong: currentMediaItem,
                                            ),
                                        transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
                                  icon: Icon(
                                    Icons.lyrics_outlined,
                                    size: 24,
                                  ),
                                  tooltip: LocaleProvider.tr('search_lyrics'),
                                ),
                                // Play/Pause Button
                                StreamBuilder<PlaybackState>(
                                  stream: audioHandler?.playbackState,
                                  builder: (context, snapshot) {
                                    final playbackState = snapshot.data;
                                    final isPlaying = playbackState?.playing ?? false;
                                    
                                    return IconButton(
                                      onPressed: () {
                                        if (isPlaying) {
                                          audioHandler?.pause();
                                        } else {
                                          audioHandler?.play();
                                        }
                                      },
                                      icon: Icon(
                                        isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                                        size: 34,
                                        grade: 200,
                                        fill: 1,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Content
                      Expanded(
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
                          child: StreamBuilder<MediaItem?>(
                            stream: audioHandler?.mediaItem.distinct((prev, next) => prev?.id == next?.id),
                            builder: (context, mediaStreamSnapshot) {
                              final currentMediaItemForLyrics = mediaStreamSnapshot.data ?? currentMediaItem;
                              
                              return ValueListenableBuilder<String?>(
                                valueListenable: lyricsUpdatedNotifier,
                                builder: (context, updatedSongId, child) {
                                  // Forzar reconstrucción si se actualizó esta canción específica
                                  final shouldRebuild = updatedSongId == currentMediaItemForLyrics.id;
                                  return FutureBuilder<LyricsResult>(
                                    key: ValueKey('${currentMediaItemForLyrics.id}_${shouldRebuild ? DateTime.now().millisecondsSinceEpoch : _lyricsUpdateCounter}'), // Rebuild when song changes or lyrics are updated
                                    future: _loadLyricsWithDelay(currentMediaItemForLyrics),
                                    builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          
                          if (snapshot.hasError) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    LocaleProvider.tr('api_unavailable'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                          
                          final result = snapshot.data!;
                          
                          if (result.type == LyricsResultType.apiUnavailable) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    LocaleProvider.tr('api_unavailable'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          } else if (result.type == LyricsResultType.noConnection) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.wifi_off,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    LocaleProvider.tr('no_connection'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          } else if (result.type == LyricsResultType.found && result.data?.synced != null) {
                            // Parse lyrics
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
                            
                            if (parsed.isEmpty) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.lyrics_outlined,
                                      size: 64,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                                    SizedBox(height: 16),
                                    Text(
                                      LocaleProvider.tr('no_lyrics_found'),
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                      ),
                                    ),
                                    SizedBox(height: 24),
                                    ElevatedButton.icon(
                                      onPressed: () async {
                                        Navigator.of(context).pop();
                                        await Navigator.of(context).push(
                                          PageRouteBuilder(
                                            pageBuilder: (context, animation, secondaryAnimation) =>
                                                LyricsSearchScreen(
                                                  currentSong: currentMediaItemForLyrics,
                                                ),
                                            transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
                                      icon: Icon(Symbols.search_rounded),
                                      label: Text(LocaleProvider.tr('search_lyrics')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context).colorScheme.primary,
                                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                            
                            return _LyricsModalListView(
                              lyricLines: parsed,
                              isAmoled: isAmoled,
                              isDark: isDark,
                            );
                          } else {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.lyrics_outlined,
                                    size: 64,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    LocaleProvider.tr('no_lyrics_found'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                  SizedBox(height: 24),
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      // Cerrar el modal de letras antes de abrir la pantalla de búsqueda
                                      Navigator.of(context).pop();
                                      await Navigator.of(context).push(
                                        PageRouteBuilder(
                                          pageBuilder: (context, animation, secondaryAnimation) =>
                                              LyricsSearchScreen(
                                                currentSong: currentMediaItemForLyrics,
                                              ),
                                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
                                    icon: Icon(Symbols.search_rounded),
                                    label: Text(LocaleProvider.tr('search_lyrics')),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Theme.of(context).colorScheme.primary,
                                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }
                                },
                              );
                                },
                              );
                            },
                          ),
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
  }

  Widget _buildLyricsModalArtwork(MediaItem mediaItem) {
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local
      if (scheme == 'file' || scheme == 'content') {
        try {
          return Image.file(
            File(artUri.toFilePath()),
            width: 50,
            height: 50,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildFallbackIcon();
            },
          );
        } catch (e) {
          return _buildFallbackIcon();
        }
      }
      // Si es una URL remota
      else if (scheme == 'http' || scheme == 'https') {
        return Image.network(
          artUri.toString(),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          cacheWidth: 200,
          cacheHeight: 200,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      }
    }

    // Si no hay artUri o no se puede cargar, verificar caché primero
    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];
    
    if (songId != null && songPath != null) {
      // Verificar si está en caché primero
      final cachedArtwork = _getCachedArtwork(songPath);
      if (cachedArtwork != null) {
        // print('✅ LYRICS MODAL: Usando carátula desde caché para: ${songPath.split('/').last}');
        return Image.file(
          File(cachedArtwork.toFilePath()),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      } else {
        // Si no está en cache, cargar de forma asíncrona
        _loadArtworkAsync(songId, songPath);
      }
      
      // Si no está en caché, cargar desde la base de datos
      // print('🔄 LYRICS MODAL: Cargando carátula desde BD para: ${songPath.split('/').last}');
      return FutureBuilder<Uri?>(
        future: getOrCacheArtwork(songId, songPath),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // print('✅ LYRICS MODAL: Carátula cargada desde BD para: ${songPath.split('/').last}');
            return Image.file(
              File(snapshot.data!.toFilePath()),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return _buildFallbackIcon();
              },
            );
          }
          // print('❌ LYRICS MODAL: No se pudo cargar carátula para: ${songPath.split('/').last}');
          return _buildFallbackIcon();
        },
      );
    }

    return _buildFallbackIcon();
  }

  Widget _buildFallbackIcon() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note,
        size: 24,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      ),
    );
  }
}

class _LyricsModalListView extends StatefulWidget {
  final List<LyricLine> lyricLines;
  final bool isAmoled;
  final bool isDark;

  const _LyricsModalListView({
    required this.lyricLines,
    required this.isAmoled,
    required this.isDark,
  });

  @override
  State<_LyricsModalListView> createState() => _LyricsModalListViewState();
}

class _LyricsModalListViewState extends State<_LyricsModalListView> {
  late final AutoScrollController _scrollController;
  int _currentLyricIndex = 0;
  int _lastCurrentIndex = -1;
  Timer? _scrollTimer;
  bool _isManualScrolling = false;

  @override
  void initState() {
    super.initState();
    _scrollController = AutoScrollController();
    
    // Calculate initial current lyric index
    _calculateCurrentLyricIndex();
    
    _startPositionListener();
    // Scroll to current lyric when modal opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentLyric();
    });
    
    // Listen for manual scroll events
    _scrollController.addListener(_onScroll);
  }
  
  void _onScroll() {
    // Detect if user is manually scrolling
    if (_scrollController.hasClients && _scrollController.position.isScrollingNotifier.value) {
      _isManualScrolling = true;
      // Reset flag after scroll ends
      Timer(Duration(milliseconds: 500), () {
        if (mounted) {
          _isManualScrolling = false;
        }
      });
    }
  }

  void _calculateCurrentLyricIndex() {
    final position = audioHandler?.playbackState.value.position ?? Duration.zero;
    
    // Find current lyric line
    int currentIndex = 0;
    for (int i = 0; i < widget.lyricLines.length; i++) {
      if (position >= widget.lyricLines[i].time) {
        currentIndex = i;
      } else {
        break;
      }
    }
    
    _currentLyricIndex = currentIndex;
    _lastCurrentIndex = currentIndex;
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _startPositionListener() {
    _scrollTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
      if (!mounted) return;
      
      final position = audioHandler?.playbackState.value.position ?? Duration.zero;
      
      // Find current lyric line
      int currentIndex = 0;
      for (int i = 0; i < widget.lyricLines.length; i++) {
        if (position >= widget.lyricLines[i].time) {
          currentIndex = i;
        } else {
          break;
        }
      }
      
      if (currentIndex != _currentLyricIndex) {
        setState(() {
          _currentLyricIndex = currentIndex;
        });
        
        // Only scroll if the index actually changed and user is not manually scrolling
        if (_currentLyricIndex != _lastCurrentIndex && !_isManualScrolling) {
          _lastCurrentIndex = _currentLyricIndex;
          _scrollToCurrentLyric();
        }
      }
    });
  }

  Future<void> _scrollToCurrentLyric() async {
    if (_currentLyricIndex >= 0 && _currentLyricIndex < widget.lyricLines.length) {
      await _scrollController.scrollToIndex(
        _currentLyricIndex,
        preferPosition: AutoScrollPosition.middle,
        duration: Duration(milliseconds: 500),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.only(top: 60, bottom: MediaQuery.of(context).padding.bottom),
      itemCount: widget.lyricLines.length,
      itemBuilder: (context, index) {
        final isCurrent = index == _currentLyricIndex;
        final textStyle = TextStyle(
          color: isCurrent
              ? (widget.isAmoled && widget.isDark
                  ? Colors.white
                  : Theme.of(context).colorScheme.primary)
              : widget.isAmoled && widget.isDark
                  ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)
                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
          fontWeight: FontWeight.bold,
          fontSize: isCurrent ? 24 : 22,
        );
        
        return AutoScrollTag(
          key: ValueKey(index),
          controller: _scrollController,
          index: index,
          child: GestureDetector(
            onTap: () {
              // Seek to the time of this lyric line
              final targetTime = widget.lyricLines[index].time;
              audioHandler?.seek(targetTime);
              
              // Set manual scrolling flag
              _isManualScrolling = true;
              
              // Update current index immediately
              setState(() {
                _currentLyricIndex = index;
                _lastCurrentIndex = index;
              });
              
              // Reset manual scrolling flag after a delay
              Timer(Duration(seconds: 3), () {
                _isManualScrolling = false;
              });
            },
            child: Container(
              padding: EdgeInsets.symmetric(vertical: 8, horizontal: 32),
              child: Text(
                widget.lyricLines[index].text,
                textAlign: TextAlign.left,
                style: textStyle,
              ),
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
  Timer? _marqueeTimer;

  @override
  void didUpdateWidget(covariant TitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      // Cancelar timer anterior si existe
      _marqueeTimer?.cancel();
      setState(() => _showMarquee = false);
      
      // Crear nuevo timer para la nueva canción
      _marqueeTimer = Timer(const Duration(milliseconds: 3000), () {
        if (mounted) setState(() => _showMarquee = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _marqueeTimer = Timer(const Duration(milliseconds: 3000), () {
      if (mounted) setState(() => _showMarquee = true);
    });
  }

  @override
  void dispose() {
    _marqueeTimer?.cancel();
    super.dispose();
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
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
      return SizedBox(
        height: 40,
        width: widget.maxWidth,
        child: Center(
          child: Marquee(
            key: ValueKey(widget.text),
            text: widget.text,
            style: widget.style!,
            velocity: 30.0,
            blankSpace: 120.0,
            startPadding: 0.0,
            fadingEdgeStartFraction: 0.1,
            fadingEdgeEndFraction: 0.1,
            showFadingOnlyWhenScrolling: false,
            pauseAfterRound: const Duration(seconds: 3),
          ),
        ),
      );
    } else {
      return SizedBox(
        height: 40,
        width: widget.maxWidth,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }
}

class HorizontalScrollWithFade extends StatefulWidget {
  final Widget child;

  const HorizontalScrollWithFade({super.key, required this.child});

  @override
  State<HorizontalScrollWithFade> createState() =>
      _HorizontalScrollWithFadeState();
}

class _HorizontalScrollWithFadeState extends State<HorizontalScrollWithFade> {
  final ScrollController _scrollController = ScrollController();
  bool _showLeftFade = false;
  bool _showRightFade = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // Verificar si se puede hacer scroll después de que se construya el widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateFadeStates();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    _updateFadeStates();
  }

  void _updateFadeStates() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;

    setState(() {
      _showLeftFade = currentScroll > 0;
      _showRightFade = maxScroll > 0 && currentScroll < maxScroll;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Contenido principal con scroll
        SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: widget.child,
        ),

        // Gradiente izquierdo (solo si hay scroll hacia la izquierda)
        if (_showLeftFade)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 20,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Theme.of(context).scaffoldBackgroundColor,
                    Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),

        // Gradiente derecho (si hay más contenido hacia la derecha)
        if (_showRightFade)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 20,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0),
                    Theme.of(context).scaffoldBackgroundColor,
                  ],
                ),
              ),
            ),
          ),
      ],
    );
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
                padding: EdgeInsets.only(top: 60, bottom: 0, left: 10, right: 10),
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
  bool _isShuffling = false;

  /// Verifica si la carátula está en el caché del audio handler
  Uri? _getCachedArtwork(String songPath) {
    final cache = artworkCache;
    final cached = cache[songPath];
    if (cached != null) {
      // print('⚡ PLAYLIST CACHÉ HIT: Carátula encontrada en caché para: ${songPath.split('/').last}');
    } else {
      // print('❌ PLAYLIST CACHÉ MISS: Carátula NO encontrada en caché para: ${songPath.split('/').last}');
    }
    return cached;
  }

  /// Carga carátula de forma asíncrona si no está en cache (para playlist)
  void _loadArtworkAsync(int songId, String songPath) {
    // Cargar de forma asíncrona usando el sistema unificado
    getOrCacheArtwork(songId, songPath).then((artUri) {
      if (artUri != null && mounted) {
        // Forzar rebuild para mostrar la carátula cargada
        setState(() {});
      }
    }).catchError((error) {
      // print('❌ Error cargando carátula en playlist: $error');
    });
  }

  @override
  void initState() {
    super.initState();
    // Calcular la posición inicial para centrar la canción actual
    final itemHeight = 72.0; // Altura aproximada de cada ListTile
    final initialOffset = widget.currentIndex >= 0
        ? (widget.currentIndex * itemHeight) -
              (widget.maxHeight / 2) +
              (itemHeight / 2)
        : 0.0;

    _scrollController = ScrollController(
      initialScrollOffset: initialOffset.clamp(0.0, double.infinity),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildCurrentSongArtwork(MediaItem mediaItem) {
    final artUri = mediaItem.artUri;
    if (artUri != null) {
      final scheme = artUri.scheme.toLowerCase();

      // Si es un archivo local
      if (scheme == 'file' || scheme == 'content') {
        try {
          return Image.file(
            File(artUri.toFilePath()),
            width: 50,
            height: 50,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildFallbackIcon();
            },
          );
        } catch (e) {
          return _buildFallbackIcon();
        }
      }
      // Si es una URL remota
      else if (scheme == 'http' || scheme == 'https') {
        return Image.network(
          artUri.toString(),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          cacheWidth: 200,
          cacheHeight: 200,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      }
    }

    // Si no hay artUri o no se puede cargar, verificar caché primero
    final songId = mediaItem.extras?['songId'];
    final songPath = mediaItem.extras?['data'];
    
    if (songId != null && songPath != null) {
      // Verificar si está en caché primero
      final cachedArtwork = _getCachedArtwork(songPath);
      if (cachedArtwork != null) {
        // print('✅ PLAYLIST: Usando carátula desde caché para: ${songPath.split('/').last}');
        return Image.file(
          File(cachedArtwork.toFilePath()),
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        );
      } else {
        // Si no está en cache, cargar de forma asíncrona
        _loadArtworkAsync(songId, songPath);
      }
      
      // Si no está en caché, cargar desde la base de datos
      // print('🔄 PLAYLIST: Cargando carátula desde BD para: ${songPath.split('/').last}');
      return FutureBuilder<Uri?>(
        future: getOrCacheArtwork(songId, songPath),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // print('✅ PLAYLIST: Carátula cargada desde BD para: ${songPath.split('/').last}');
            return Image.file(
              File(snapshot.data!.toFilePath()),
              width: 50,
              height: 50,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return _buildFallbackIcon();
              },
            );
          }
          // print('❌ PLAYLIST: No se pudo cargar carátula para: ${songPath.split('/').last}');
          return _buildFallbackIcon();
        },
      );
    }

    return _buildFallbackIcon();
  }

  Widget _buildFallbackIcon() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note,
        size: 25,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Lista de canciones con padding superior para el encabezado fijo
        ListView.builder(
          controller: _scrollController,
          shrinkWrap: true,
          padding: EdgeInsets.only(
            top: 80 + MediaQuery.of(context).padding.top, // Reducir padding para evitar recorte de la primera canción
            bottom: MediaQuery.of(context).padding.bottom, // Padding inferior para evitar que se oculte detrás de la barra de navegación
          ),
          itemCount: widget.queue.length,
          itemBuilder: (context, index) {
            final item = widget.queue[index];
            final isCurrent = item.id == widget.currentMediaItem?.id;
            final isAmoledTheme =
                colorSchemeNotifier.value == AppColorScheme.amoled;
            final songId = item.extras?['songId'] ?? 0;
            final songPath = item.extras?['data'] ?? '';
            
            // Agregar padding adicional al primer y último elemento para evitar recorte
            final isFirstItem = index == 0;
            final isLastItem = index == widget.queue.length - 1;
            
            return Padding(
              padding: EdgeInsets.only(
                top: isFirstItem ? 42.0 : 0.0,
                bottom: isFirstItem ? 8.0 : (isLastItem ? 20.0 : 0.0),
              ),
              child: ListTile(
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
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    color: isCurrent
                        ? (isAmoledTheme
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary)
                        : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.artist ?? LocaleProvider.tr('unknown_artist'),
                  maxLines: 1,
                ),
                selected: isCurrent,
                selectedTileColor: isCurrent
                    ? (isAmoledTheme
                        ? null
                        : Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.8))
                    : null,
                shape: isCurrent
                    ? RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      )
                    : null,
                onTap: () {
                  audioHandler?.skipToQueueItem(index);
                  // No cerramos el modal, así se mantiene abierto
                },
              ),
            );
          },
        ),
        
        // Encabezado fijo en la parte superior con bordes redondeados
        Positioned(
          top: MediaQuery.of(context).padding.top, // Respeta la barra de estado
          left: 0,
          right: 0,
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 16),
                // Información de la canción actual
                if (widget.currentMediaItem != null)
                  Row(
                    children: [
                      // Carátula de la canción actual
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: _buildCurrentSongArtwork(widget.currentMediaItem!),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Título y artista de la canción actual
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TitleMarquee(
                              text: widget.currentMediaItem!.title,
                              maxWidth: MediaQuery.of(context).size.width - 150,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            Text(
                              widget.currentMediaItem!.artist ??
                                  LocaleProvider.tr('unknown_artist'),
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).textTheme.bodyMedium?.color?.withValues(alpha: 1),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Ícono de aleatorio
                      InkWell(
                        onTap: _isShuffling ? null : () async {
                          if (widget.queue.isNotEmpty && !_isShuffling) {
                            setState(() {
                              _isShuffling = true;
                            });
                            
                            final random = Random();
                            final randomIndex = random.nextInt(widget.queue.length);
                            audioHandler?.skipToQueueItem(randomIndex);
                            
                            // Delay de 500ms antes de permitir otro toque
                            await Future.delayed(const Duration(milliseconds: 500));
                            
                            if (mounted) {
                              setState(() {
                                _isShuffling = false;
                              });
                            }
                          }
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Symbols.shuffle_rounded,
                            size: 32,
                            color: Theme.of(context).colorScheme.onSurface,
                            weight: 600,
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
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
    if (widget.artUri != null &&
        (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      setState(() => _artUri = widget.artUri);
      return;
    }
    
    // Verificar si está en caché primero
    final cache = artworkCache;
    final cachedArtwork = cache[widget.songPath];
    if (cachedArtwork != null) {
      // print('✅ ARTWORK LIST TILE: Usando carátula desde caché para: ${widget.songPath.split('/').last}');
      if (mounted) setState(() => _artUri = cachedArtwork);
      return;
    }
    
    // Si no está en caché, cargar desde la base de datos
    // print('🔄 ARTWORK LIST TILE: Cargando carátula desde BD para: ${widget.songPath.split('/').last}');
    final uri = await getOrCacheArtwork(widget.songId, widget.songPath);
    if (mounted) {
      if (uri != null) {
        // print('✅ ARTWORK LIST TILE: Carátula cargada desde BD para: ${widget.songPath.split('/').last}');
      } else {
        // print('❌ ARTWORK LIST TILE: No se pudo cargar carátula para: ${widget.songPath.split('/').last}');
      }
      setState(() => _artUri = uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: _buildArtworkContent(),
    );
  }

  Widget _buildArtworkContent() {
    if (widget.artUri != null &&
        (widget.artUri!.isScheme('http') || widget.artUri!.isScheme('https'))) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.network(
          widget.artUri.toString(),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: 400,
          cacheHeight: 400,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
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
          errorBuilder: (context, error, stackTrace) {
            return _buildFallbackIcon();
          },
        ),
      );
    } else {
      return _buildFallbackIcon();
    }
  }

  Widget _buildFallbackIcon() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: widget.borderRadius,
      ),
      child: Icon(
        Icons.music_note, 
        size: widget.size * 0.5,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

