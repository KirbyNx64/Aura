import 'dart:async';
import 'package:flutter/material.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:music/utils/db/songs_index_db.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:url_launcher/url_launcher.dart';
import 'package:music/widgets/song_info_dialog.dart';
import 'package:music/widgets/hero_cached.dart';
import 'package:music/widgets/artwork_list_tile.dart';
import 'package:music/screens/artist/artist_screen.dart';

enum OrdenFavoritos { normal, alfabetico, invertido, ultimoAgregado }

OrdenFavoritos _orden = OrdenFavoritos.normal;

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<SongModel> _favorites = [];
  List<SongModel> _originalFavorites = [];
  late AnimationController _refreshController;
  bool _isReloading = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<SongModel> _filteredFavorites = [];
  double _lastBottomInset = 0.0;
  final ScrollController _scrollController = ScrollController();

  bool _isSelecting = false;
  final Set<int> _selectedSongIds = {};

  static const String _orderPrefsKey = 'favorites_screen_order_filter';

  Timer? _debounce;
  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

  static String? _pathFromMediaItem(MediaItem? item) =>
      item?.extras?['data'] ?? item?.id;

  void _onFavoritesReload() => _loadFavorites();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadOrderFilter().then((_) => _loadFavorites(initial: true));

    _searchFocusNode.addListener(() {
      setState(() {});
    });
    favoritesShouldReload.addListener(_onFavoritesReload);

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

    // Un solo listener para MediaItem: evita rebuilds duplicados (antes 50ms + 200ms)
    // Solo actualizar si la ruta de la canción realmente cambió
    audioHandler?.mediaItem.listen((mediaItem) {
      final newPath = _pathFromMediaItem(mediaItem);
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 80), () {
        if (mounted &&
            _pathFromMediaItem(_currentMediaItemNotifier.value) != newPath) {
          _currentMediaItemNotifier.value = mediaItem;
        }
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    favoritesShouldReload.removeListener(_onFavoritesReload);
    _debounce?.cancel();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites({bool initial = false}) async {
    if (_isReloading) return;
    if (!initial) {
      if (!mounted) return;
      setState(() {
        _isReloading = true;
        _refreshController.repeat();
      });
    }

    // Actualizar los notifiers con los valores actuales del audioHandler
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _mediaItemDebounce?.cancel();
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    final favs = await FavoritesDB().getFavorites();
    if (!initial) {
      // Espera un poco para que la animación sea visible
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (!mounted) return;
    setState(() {
      _favorites = favs;
      _originalFavorites = List.from(favs);
      _isReloading = false;
      _refreshController.stop();
      _refreshController.reset();
    });
    if (_orden != OrdenFavoritos.normal) {
      _ordenarFavoritos();
    }

    // Precargar carátulas de favoritos
    unawaited(_preloadArtworksForSongs(favs));
  }

  /// Función específica para refrescar la lista de favoritos
  Future<void> _refreshFavorites() async {
    await _loadFavorites();
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

  Future<void> _playSong(SongModel song) async {
    final index = _favorites.indexWhere((s) => s.data == song.data);

    if (index == -1) return;

    final handler = audioHandler as MyAudioHandler;
    /*
    final currentQueue = handler.queue.value;
    bool isSameQueue = false;
    if (currentQueue.length == _favorites.length) {
      isSameQueue = true;
      for (int i = 0; i < _favorites.length; i++) {
        if (currentQueue[i].id != _favorites[i].data) {
          isSameQueue = false;
          break;
        }
      }
    }

    if (isSameQueue) {
      await handler.skipToQueueItem(index);
      await handler.play();
      return;
    }
    */

    // Limpiar la cola y el MediaItem antes de mostrar la nueva canción
    (audioHandler as MyAudioHandler).queue.add([]);
    // (audioHandler as MyAudioHandler).mediaItem.add(null);

    // Limpiar el fallback de las carátulas para evitar parpadeo
    ArtworkHeroCached.clearFallback();

    // Precargar la carátula antes de crear el MediaItem temporal
    /*
    Uri? cachedArtUri;
    try {
      cachedArtUri = await getOrCacheArtwork(song.id, song.data);
    } catch (e) {
      // Si falla, continuar sin carátula
    }

    // Crear MediaItem temporal para mostrar el overlay inmediatamente
    final tempMediaItem = MediaItem(
      id: song.data,
      title: song.title,
      artist: song.artist,
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
    (audioHandler as MyAudioHandler).mediaItem.add(tempMediaItem);
    */

    // Solo guardar el origen si se va a cambiar la cola
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'last_queue_source',
      LocaleProvider.tr('favorites_title'),
    );

    await handler.setQueueFromSongs(_favorites, initialIndex: index);
    await handler.play();
  }

  Future<void> _removeFromFavorites(SongModel song) async {
    await FavoritesDB().removeFavorite(song.data);
    await _loadFavorites();
  }

  void _onSearchChanged() {
    final query = quitarDiacriticos(_searchController.text.trim());
    if (query.isEmpty) {
      setState(() {
        _filteredFavorites = [];
      });
      return;
    }
    setState(() {
      _filteredFavorites = _favorites.where((song) {
        final title = quitarDiacriticos(song.title);
        final artist = quitarDiacriticos(song.artist ?? '');
        return title.contains(query) || artist.contains(query);
      }).toList();
    });
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null &&
        savedIndex >= 0 &&
        savedIndex < OrdenFavoritos.values.length) {
      setState(() {
        _orden = OrdenFavoritos.values[savedIndex];
      });
    }
  }

  Future<void> _saveOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_orderPrefsKey, _orden.index);
  }

  void _ordenarFavoritos() {
    setState(() {
      switch (_orden) {
        case OrdenFavoritos.normal:
          _favorites = List.from(
            _originalFavorites,
          ); // Restaura el orden original
          break;
        case OrdenFavoritos.alfabetico:
          _favorites.sort((a, b) => a.title.compareTo(b.title));
          break;
        case OrdenFavoritos.invertido:
          _favorites.sort((a, b) => b.title.compareTo(a.title));
          break;
        case OrdenFavoritos.ultimoAgregado:
          _favorites = List.from(_originalFavorites.reversed);
          break;
      }
    });
    _saveOrderFilter();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (mounted && _searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  String quitarDiacriticos(String texto) {
    const conAcentos = 'áàäâãéèëêíìïîóòöôõúùüûÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛ';
    const sinAcentos = 'aaaaaeeeeiiiiooooouuuuaaaaaeeeeiiiiooooouuuu';

    for (int i = 0; i < conAcentos.length; i++) {
      texto = texto.replaceAll(conAcentos[i], sinAcentos[i]);
    }
    return texto.toLowerCase();
  }

  String _formatArtistWithDuration(SongModel song) {
    final artist = (song.artist == null || song.artist!.trim().isEmpty)
        ? LocaleProvider.tr('unknown_artist')
        : song.artist!;

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

  void _onSongSelected(SongModel song) async {
    if (playLoadingNotifier.value) return;
    try {
      (audioHandler as MyAudioHandler).isShuffleNotifier.value = false;
    } catch (_) {}
    if (_isSelecting) {
      setState(() {
        if (_selectedSongIds.contains(song.id)) {
          _selectedSongIds.remove(song.id);
          if (_selectedSongIds.isEmpty) {
            _isSelecting = false;
          }
        } else {
          _selectedSongIds.add(song.id);
        }
      });
      return;
    }

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
      cachedArtUri = await artUriFuture.timeout(
        const Duration(milliseconds: 25),
      );
    } catch (_) {
      // Si no es rápido, actualizar cuando esté listo para evitar el flash del placeholder
      artUriFuture.then((uri) {
        if (uri != null && mounted && audioHandler is MyAudioHandler) {
          final handler = audioHandler as MyAudioHandler;
          final current = handler.mediaItem.value;
          // Verificar que seguimos en la misma canción
          if (current != null && current.extras?['songId'] == songId) {
            final updatedItem = current.copyWith(artUri: uri);
            handler.mediaItem.add(updatedItem);
          }
        }
      });
    }

    final tempMediaItem = MediaItem(
      id: song.data,
      title: song.title,
      artist: song.artist,
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
    (audioHandler as MyAudioHandler).mediaItem.add(tempMediaItem);

    // Abrir el panel del reproductor con la nueva animación
    if (!mounted) return;
    openPlayerPanelNotifier.value = true;
    // Activar indicador de carga
    playLoadingNotifier.value = true;

    // Reproducir la canción después de un breve delay para que se abra la pantalla
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) {
        _playSong(song);
        // Desactivar indicador de carga después de reproducir
        Future.delayed(const Duration(milliseconds: 200), () {
          playLoadingNotifier.value = false;
        });
      }
    });
  }

  void _handleLongPress(BuildContext context, SongModel song) async {
    final isPinned = await ShortcutsDB().isShortcut(song.data);
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
                            song.title,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.artist ?? LocaleProvider.tr('unknown_artist'),
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
                  Navigator.of(context).pop();
                  await (audioHandler as MyAudioHandler).addSongsToQueueEnd([
                    song,
                  ]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: TranslatedText('remove_from_favorites'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _removeFromFavorites(song);
                  favoritesShouldReload.value = !favoritesShouldReload.value;
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: TranslatedText('add_to_playlist'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _handleAddToPlaylistSingle(context, song);
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
                    await ShortcutsDB().removeShortcut(song.data);
                  } else {
                    await ShortcutsDB().addShortcut(song.data);
                  }
                  shortcutsShouldReload.value = !shortcutsShouldReload.value;
                },
              ),
              if ((song.artist ?? '').trim().isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const TranslatedText('go_to_artist'),
                  onTap: () {
                    Navigator.of(context).pop();
                    final name = (song.artist ?? '').trim();
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
                leading: const Icon(Icons.check_box_outlined),
                title: TranslatedText('select'),
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() {
                    _isSelecting = true;
                    _selectedSongIds.add(song.id);
                  });
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

  Future<void> _handleAddToPlaylistSingle(
    BuildContext context,
    SongModel song,
  ) async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    final allSongs = await SongsIndexDB().getIndexedSongs();
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

  Future<void> _handleAddToPlaylistMassive(BuildContext context) async {
    final playlists = await PlaylistsDB().getAllPlaylists();
    final allSongs = await SongsIndexDB().getIndexedSongs();
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
                                    final selectedSongs =
                                        (_searchController.text.isNotEmpty
                                                ? _filteredFavorites
                                                : _favorites)
                                            .where(
                                              (s) => _selectedSongIds.contains(
                                                s.id,
                                              ),
                                            );
                                    for (final song in selectedSongs) {
                                      await PlaylistsDB().addSongToPlaylist(
                                        pl.id,
                                        song,
                                      );
                                    }
                                    setState(() {
                                      _isSelecting = false;
                                      _selectedSongIds.clear();
                                    });
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
                            final selectedSongs =
                                (_searchController.text.isNotEmpty
                                        ? _filteredFavorites
                                        : _favorites)
                                    .where(
                                      (s) => _selectedSongIds.contains(s.id),
                                    );
                            for (final song in selectedSongs) {
                              await PlaylistsDB().addSongToPlaylist(id, song);
                            }
                            setState(() {
                              _isSelecting = false;
                              _selectedSongIds.clear();
                            });
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
                        final selectedSongs =
                            (_searchController.text.isNotEmpty
                                    ? _filteredFavorites
                                    : _favorites)
                                .where((s) => _selectedSongIds.contains(s.id));
                        for (final song in selectedSongs) {
                          await PlaylistsDB().addSongToPlaylist(id, song);
                        }
                        setState(() {
                          _isSelecting = false;
                          _selectedSongIds.clear();
                        });
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

  Future<void> _removeFromFavoritesMassive() async {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final selectedSongs =
        (_searchController.text.isNotEmpty ? _filteredFavorites : _favorites)
            .where((s) => _selectedSongIds.contains(s.id));
    final count = _selectedSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: TranslatedText('remove_from_favorites'),
        content: Text(
          count == 1
              ? LocaleProvider.tr('confirm_remove_favorite')
              : "${LocaleProvider.tr('confirm_remove_favorites')} ($count)",
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
      await FavoritesDB().removeFavorite(song.data);
    }
    await _loadFavorites();
    setState(() {
      _isSelecting = false;
      _selectedSongIds.clear();
    });
  }

  Future<void> _showAddSongsToFavoritesDialog() async {
    final allSongs = await SongsIndexDB().getIndexedSongs();
    final currentFavoritePaths = _favorites.map((s) => s.data).toSet();

    // Filtrar canciones que ya están en favoritos
    final availableSongs = allSongs
        .where((s) => !currentFavoritePaths.contains(s.data))
        .toList();

    if (!mounted) return;

    final Set<String> selectedPaths = {};
    String query = "";

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return StatefulBuilder(
              builder: (context, setStateDialog) {
                // Optimizar filtrado para evitar procesar toda la lista en cada frame si es posible
                final filtered = query.isEmpty
                    ? availableSongs
                    : availableSongs.where((s) {
                        final title = s.title.toLowerCase();
                        final artist = (s.artist ?? "").toLowerCase();
                        final q = query.toLowerCase();
                        return title.contains(q) || artist.contains(q);
                      }).toList();

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
                  content: SizedBox(
                    width: 500, // Forzar ancho
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.7,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.favorite_rounded, size: 32),
                          const SizedBox(height: 16),
                          TranslatedText(
                            'add_songs',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: TextField(
                              decoration: InputDecoration(
                                hintText: LocaleProvider.tr('search_songs'),
                                prefixIcon: const Icon(Icons.search),
                                filled: true,
                                fillColor: isDark
                                    ? Colors.white.withAlpha(20)
                                    : Colors.black.withAlpha(10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              onChanged: (v) {
                                setStateDialog(() {
                                  query = v;
                                });
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          Flexible(
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                color: isDark
                                    ? Colors.white.withAlpha(10)
                                    : Colors.black.withAlpha(5),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: filtered.isEmpty
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24.0),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.music_off_rounded,
                                                size: 48,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(100),
                                              ),
                                              const SizedBox(height: 12),
                                              TranslatedText(
                                                'no_songs',
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withAlpha(150),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final song = filtered[index];
                                          final isSelected = selectedPaths
                                              .contains(song.data);
                                          return ListTile(
                                            onTap: () {
                                              setStateDialog(() {
                                                if (isSelected) {
                                                  selectedPaths.remove(
                                                    song.data,
                                                  );
                                                } else {
                                                  selectedPaths.add(song.data);
                                                }
                                              });
                                            },
                                            leading: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: ArtworkListTile(
                                                songId: song.id,
                                                songPath: song.data,
                                                size: 40,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                            title: Text(
                                              song.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            subtitle: Text(
                                              song.artist ??
                                                  LocaleProvider.tr('unknown'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(150),
                                              ),
                                            ),
                                            trailing: Checkbox(
                                              value: isSelected,
                                              activeColor: primaryColor,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              onChanged: (v) {
                                                setStateDialog(() {
                                                  if (v == true) {
                                                    selectedPaths.add(
                                                      song.data,
                                                    );
                                                  } else {
                                                    selectedPaths.remove(
                                                      song.data,
                                                    );
                                                  }
                                                });
                                              },
                                            ),
                                          );
                                        },
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 24,
                              bottom: 8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: TranslatedText(
                                    'cancel',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TextButton(
                                  onPressed: selectedPaths.isEmpty
                                      ? null
                                      : () => Navigator.pop(
                                          context,
                                          selectedPaths.toList(),
                                        ),
                                  style: TextButton.styleFrom(
                                    foregroundColor: primaryColor,
                                  ),
                                  child: TranslatedText(
                                    'add',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );

    if (selected != null && selected.isNotEmpty) {
      for (final path in selected) {
        try {
          final song = allSongs.firstWhere((s) => s.data == path);
          await FavoritesDB().addFavorite(song);
        } catch (_) {}
      }
      favoritesShouldReload.value = !favoritesShouldReload.value;
      await _loadFavorites();
    }
  }

  Future<void> _showSortOptionsDialog() async {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

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
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort_rounded, size: 32),
                  const SizedBox(height: 16),
                  TranslatedText(
                    'filters',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSortOption(
                    OrdenFavoritos.normal,
                    'last_added',
                    Icons.history_rounded,
                  ),
                  _buildSortOption(
                    OrdenFavoritos.ultimoAgregado,
                    'invert_order',
                    Icons.swap_vert_rounded,
                  ),
                  _buildSortOption(
                    OrdenFavoritos.alfabetico,
                    'alphabetical_az',
                    Icons.sort_by_alpha_rounded,
                  ),
                  _buildSortOption(
                    OrdenFavoritos.invertido,
                    'alphabetical_za',
                    Icons.sort_by_alpha_rounded,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSortOption(
    OrdenFavoritos value,
    String labelKey,
    IconData icon,
  ) {
    final isSelected = _orden == value;
    final colorScheme = Theme.of(context).colorScheme;
    final primaryColor = colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final useSubtleStyling = isAmoled && isDark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () {
          setState(() {
            _orden = value;
            _ordenarFavoritos();
          });
          Navigator.pop(context);
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? (useSubtleStyling ? primaryColor.withAlpha(30) : primaryColor)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: isSelected && useSubtleStyling
                ? Border.all(color: primaryColor.withAlpha(100), width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected
                    ? (useSubtleStyling ? primaryColor : colorScheme.onPrimary)
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TranslatedText(
                  labelKey,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected
                        ? (useSubtleStyling
                              ? primaryColor
                              : colorScheme.onPrimary)
                        : colorScheme.onSurface,
                  ),
                ),
              ),
              if (isSelected)
                Icon(
                  Icons.check_circle_rounded,
                  color: useSubtleStyling
                      ? primaryColor
                      : colorScheme.onPrimary,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptimizedListTile(
    BuildContext context,
    SongModel song,
    bool isCurrent,
    bool playing,
    bool isAmoledTheme, {
    BorderRadius? borderRadius,
  }) {
    return ListTile(
      onLongPress: () {
        if (_isSelecting) {
          setState(() {
            if (_selectedSongIds.contains(song.id)) {
              _selectedSongIds.remove(song.id);
              if (_selectedSongIds.isEmpty) {
                _isSelecting = false;
              }
            } else {
              _selectedSongIds.add(song.id);
            }
          });
        } else {
          _handleLongPress(context, song);
        }
      },
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSelecting)
            Checkbox(
              value: _selectedSongIds.contains(song.id),
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selectedSongIds.add(song.id);
                  } else {
                    _selectedSongIds.remove(song.id);
                    if (_selectedSongIds.isEmpty) {
                      _isSelecting = false;
                    }
                  }
                });
              },
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ArtworkListTile(
              key: ValueKey('fav_art_${song.data}'),
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
              padding: const EdgeInsets.only(right: 8.0),
              child: MiniMusicVisualizer(
                color: Theme.of(context).colorScheme.primary,
                width: 4,
                height: 15,
                radius: 4,
                animate: playing ? true : false,
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
        _formatArtistWithDuration(song),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(20),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: Icon(
            isCurrent && playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            grade: 200,
            fill: 1,
            color: isCurrent ? Theme.of(context).colorScheme.primary : null,
          ),
          onPressed: () {
            if (isCurrent) {
              playing
                  ? (audioHandler as MyAudioHandler).pause()
                  : (audioHandler as MyAudioHandler).play();
            } else {
              _onSongSelected(song);
            }
          },
        ),
      ),
      selected: isCurrent,
      selectedTileColor: Colors.transparent,
      shape: borderRadius != null
          ? RoundedRectangleBorder(borderRadius: borderRadius)
          : null,
      onTap: () => _onSongSelected(song),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: _isSelecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: LocaleProvider.tr('cancel_selection'),
                onPressed: () {
                  setState(() {
                    _isSelecting = false;
                    _selectedSongIds.clear();
                  });
                },
              )
            : null,
        title: _isSelecting
            ? Text(
                '${_selectedSongIds.length} ${LocaleProvider.tr('selected')}',
              )
            : TranslatedText(
                'favorites',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
        actions: _isSelecting
            ? [
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: LocaleProvider.tr('remove_from_favorites'),
                  onPressed: _selectedSongIds.isEmpty
                      ? null
                      : _removeFromFavoritesMassive,
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: LocaleProvider.tr('add_to_playlist'),
                  onPressed: _selectedSongIds.isEmpty
                      ? null
                      : () => _handleAddToPlaylistMassive(context),
                ),
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: LocaleProvider.tr('select_all'),
                  onPressed: () {
                    final songsToShow = _searchController.text.isNotEmpty
                        ? _filteredFavorites
                        : _favorites;
                    setState(() {
                      if (_selectedSongIds.length == songsToShow.length) {
                        // Si todos están seleccionados, deseleccionar todos
                        _selectedSongIds.clear();
                        if (_selectedSongIds.isEmpty) {
                          _isSelecting = false;
                        }
                      } else {
                        // Seleccionar todos
                        _selectedSongIds.addAll(songsToShow.map((s) => s.id));
                      }
                    });
                  },
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(
                    Icons.shuffle_rounded,
                    size: 28,
                    weight: 600,
                  ),
                  tooltip: LocaleProvider.tr('shuffle'),
                  onPressed: () {
                    final List<SongModel> songsToShow =
                        _searchController.text.isNotEmpty
                        ? _filteredFavorites
                        : _favorites;
                    if (songsToShow.isNotEmpty) {
                      final random = (songsToShow.toList()..shuffle()).first;
                      _onSongSelected(random);
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 28),
                  tooltip: LocaleProvider.tr('add_songs'),
                  onPressed: _showAddSongsToFavoritesDialog,
                ),
                IconButton(
                  icon: const Icon(Icons.sort, size: 28),
                  tooltip: LocaleProvider.tr('filters'),
                  onPressed: _showSortOptionsDialog,
                ),
              ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ValueListenableBuilder<String>(
              valueListenable: languageNotifier,
              builder: (context, lang, child) {
                final colorScheme = colorSchemeNotifier.value;
                final isAmoled = colorScheme == AppColorScheme.amoled;
                final isDark = Theme.of(context).brightness == Brightness.dark;
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
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: (_) => _onSearchChanged(),
                  cursorColor: Theme.of(context).colorScheme.primary,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('search_by_title_or_artist'),
                    hintStyle: TextStyle(
                      color: isAmoled
                          ? Colors.white.withAlpha(160)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 15,
                    ),
                    prefixIcon: Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged();
                              setState(() {});
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
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshFavorites,
        child: ValueListenableBuilder<MediaItem?>(
          valueListenable: _currentMediaItemNotifier,
          builder: (context, currentMediaItem, child) {
            final List<SongModel> songsToShow =
                _searchController.text.isNotEmpty
                ? _filteredFavorites
                : _favorites;

            if (songsToShow.isEmpty) {
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: SizedBox(
                  height: MediaQuery.of(context).size.height - 200,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.favorite_outline_rounded,
                          weight: 600,
                          size: 48,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        const SizedBox(height: 16),
                        TranslatedText(
                          'no_songs',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final bottomPadding = MediaQuery.of(context).padding.bottom;
            final space =
                (currentMediaItem != null ? 100.0 : 0.0) + bottomPadding;

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

            return RawScrollbar(
                  controller: _scrollController,
                  thumbColor: Theme.of(context).colorScheme.primary,
                  thickness: 6.0,
                  radius: const Radius.circular(8),
                  interactive: true,
                  padding: EdgeInsets.only(bottom: space),
                  child: ListView.builder(
                    controller: _scrollController,
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

                      // Solo usar ValueListenableBuilder para la canción actual
                      Widget listTileWidget;
                      if (isCurrent) {
                        listTileWidget = ValueListenableBuilder<bool>(
                          valueListenable: _isPlayingNotifier,
                          builder: (context, playing, child) {
                            return _buildOptimizedListTile(
                              context,
                              song,
                              isCurrent,
                              playing,
                              isAmoled,
                              borderRadius: borderRadius,
                            );
                          },
                        );
                      } else {
                        listTileWidget = _buildOptimizedListTile(
                          context,
                          song,
                          isCurrent,
                          false,
                          isAmoled,
                          borderRadius: borderRadius,
                        );
                      }

                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                          child: Card(
                            color: isCurrent
                                ? Theme.of(context).colorScheme.primary.withAlpha(
                                    isDark ? 40 : 25,
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
      ),
    );
  }

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
      final title = song.title;
      final artist = song.artist ?? '';

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
      final title = song.title;
      final artist = song.artist ?? '';

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

  // Función para mostrar opciones de búsqueda
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

  /// Generar cuadrícula de carátulas para una playlist
  Widget _buildPlaylistArtworkGrid(
    hive_model.PlaylistModel playlist,
    List<SongModel> allSongs,
  ) {
    final rawList = playlist.songPaths;
    // Filtra solo rutas válidas
    final filtered = rawList.where((e) => e.isNotEmpty).toList();

    // Obtener las canciones reales que existen en el índice cargado
    final List<SongModel> validSongs = [];
    for (final songPath in filtered) {
      final songIndex = allSongs.indexWhere((s) => s.data == songPath);
      if (songIndex != -1) {
        validSongs.add(allSongs[songIndex]);
        if (validSongs.length >= 4) break; // Máximo 4 para el grid
      }
    }

    return SizedBox(
      width: 40,
      height: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildArtworkLayout(validSongs),
      ),
    );
  }

  Widget _buildArtworkLayout(List<SongModel> songs) {
    switch (songs.length) {
      case 0:
        return Container(
          color: Theme.of(context).colorScheme.primaryContainer.withAlpha(100),
          child: Center(
            child: Icon(
              Icons.queue_music_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 20,
            ),
          ),
        );

      case 1:
        return ArtworkListTile(
          songId: songs[0].id,
          songPath: songs[0].data,
          width: 40,
          height: 40,
          borderRadius: BorderRadius.zero,
        );

      case 2:
      case 3:
        // Caso 2 y 3: mostramos 2 (lado a lado)
        return Row(
          children: [
            Expanded(
              child: ArtworkListTile(
                songId: songs[0].id,
                songPath: songs[0].data,
                width: 20,
                height: 40,
                borderRadius: BorderRadius.zero,
              ),
            ),
            Expanded(
              child: ArtworkListTile(
                songId: songs[1].id,
                songPath: songs[1].data,
                width: 20,
                height: 40,
                borderRadius: BorderRadius.zero,
              ),
            ),
          ],
        );

      default:
        // 4 o más canciones: Cuadrícula 2x2
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: ArtworkListTile(
                      songId: songs[0].id,
                      songPath: songs[0].data,
                      width: 20,
                      height: 20,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  Expanded(
                    child: ArtworkListTile(
                      songId: songs[1].id,
                      songPath: songs[1].data,
                      width: 20,
                      height: 20,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: ArtworkListTile(
                      songId: songs[2].id,
                      songPath: songs[2].data,
                      width: 20,
                      height: 20,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  Expanded(
                    child: ArtworkListTile(
                      songId: songs[3].id,
                      songPath: songs[3].data,
                      width: 20,
                      height: 20,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}
