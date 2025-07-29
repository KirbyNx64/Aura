import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/utils/db/recent_db.dart';
import 'package:music/utils/db/mostplayer_db.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/main.dart' show audioHandler, getAudioServiceSafely;
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/screens/home/ota_update_screen.dart';
import 'package:music/screens/home/settings_screen.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/screens/play/player_screen.dart';
import 'dart:async';

enum OrdenCancionesPlaylist { normal, alfabetico, invertido, ultimoAgregado }

class HomeScreen extends StatefulWidget {
  final void Function(int)? onTabChange;
  final void Function(AppThemeMode)? setThemeMode;
  final void Function(AppColorScheme)? setColorScheme;
  const HomeScreen({super.key, this.onTabChange, this.setThemeMode, this.setColorScheme});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<SongModel> _recentSongs = [];
  bool _showingRecents = false;
  bool _showingPlaylistSongs = false;
  List<SongModel> _playlistSongs = [];
  Map<String, dynamic>? _selectedPlaylist;
  double _lastBottomInset = 0.0;
  String? _updateVersion;
  String? _updateApkUrl;
  bool _updateChecked = false;

  List<SongModel> _mostPlayed = [];
  final PageController _pageController = PageController(viewportFraction: 0.95);
  final PageController _quickPickPageController = PageController(
    viewportFraction: 0.90,
  );
  List<Map<String, dynamic>> _playlists = [];

  final TextEditingController _searchRecentsController =
      TextEditingController();
  final FocusNode _searchRecentsFocus = FocusNode();
  List<SongModel> _filteredRecents = [];
  OrdenCancionesPlaylist _ordenCancionesPlaylist = OrdenCancionesPlaylist.normal;
  static const String _orderPrefsKey = 'home_screen_playlist_order_filter';

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
  List<SongModel> _shuffledQuickPick = [];

  Timer? _debounce;

  /// Helper para obtener el AudioHandler de forma segura
  Future<MyAudioHandler?> _getAudioHandler() async {
    final handler = await getAudioServiceSafely();
    return handler as MyAudioHandler?;
  }

  // Devuelve la lista de accesos directos para mostrar en quick_access
  List<SongModel> get _accessDirectSongs {
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toList();
    final List<SongModel> combined = [
      ..._shortcutSongs,
      ..._mostPlayed.where((s) => !shortcutPaths.contains(s.data)),
    ];
    return combined.take(18).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOrderFilter().then((_) {
      _loadAllSongs();
      _loadMostPlayed().then((_) async {
        await _loadShortcuts();
        _initQuickPickPages();
        setState(() {});
      });
      _loadPlaylists();
    });
    playlistsShouldReload.addListener(_onPlaylistsShouldReload);
    shortcutsShouldReload.addListener(_onShortcutsShouldReload);
    _buscarActualizacion();
  }

  void _onShortcutsShouldReload() {
    refreshShortcuts();
  }

  Future<void> _loadOrderFilter() async {
    final prefs = await SharedPreferences.getInstance();
    final int? savedIndex = prefs.getInt(_orderPrefsKey);
    if (savedIndex != null && savedIndex >= 0 && savedIndex < OrdenCancionesPlaylist.values.length) {
      setState(() {
        _ordenCancionesPlaylist = OrdenCancionesPlaylist.values[savedIndex];
      });
    }
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
    // Primero los accesos directos, luego las más escuchadas sin repetir
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toList();
    final List<SongModel> shortcutOrdered = [];
    for (final path in shortcutPaths) {
      try {
        final song = _shortcutSongs.firstWhere((s) => s.data == path);
        shortcutOrdered.add(song);
      } catch (_) {}
    }
    final List<SongModel> combined = [
      ...shortcutOrdered,
      ..._mostPlayed.where((s) => !shortcutPaths.contains(s.data)),
    ];
    final limited = combined.take(18).toList();
    // Divide la lista en páginas de 6
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
    _initQuickPickPages();
    setState(() {});
  }

  Future<void> _loadShortcuts() async {
    final shortcutPaths = await ShortcutsDB().getShortcuts();
    List<SongModel> shortcutSongs = [];
    for (final path in shortcutPaths) {
      try {
        final song = allSongs.firstWhere((s) => s.data == path);
        shortcutSongs.add(song);
      } catch (_) {}
    }
    setState(() {
      _shortcutSongs = shortcutSongs;
    });
    _shuffleQuickPick();
  }

  Future<void> refreshShortcuts() async {
    await _loadShortcuts();
    _initQuickPickPages();
    setState(() {});
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
    final query = OnAudioQuery();
    final songs = await query.querySongs();
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
    setState(() {
      _playlists = playlistsWithSongs;
    });
  }

  Future<void> _loadPlaylistSongs(Map<String, dynamic> playlist) async {
    final songs = await PlaylistsDB().getSongsFromPlaylist(playlist['id']);
    setState(() {
      _originalPlaylistSongs = List.from(songs);
      _selectedPlaylist = playlist;
      _showingPlaylistSongs = true;
      _showingRecents = false;
    });
    _ordenarCancionesPlaylist();
    
    // Precargar carátulas de la playlist
    unawaited(_preloadArtworksForSongs(songs));
  }

  Future<void> _loadMostPlayed() async {
    final songs = await MostPlayedDB().getMostPlayed(limit: 40);
    setState(() {
      _mostPlayed = songs;
    });
    _shuffleQuickPick();
    
    // Precargar carátulas de canciones más reproducidas
    unawaited(_preloadArtworksForSongs(songs));
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
      // Si no está en caché, cargarla inmediatamente
      if (!artworkCache.containsKey(song.data)) {
        await getOrCacheArtwork(song.id, song.data);
      }
    } catch (e) {
      // Ignorar errores de precarga
    }
  }

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        _showingRecents = true;
      });
      
      // Precargar carátulas de canciones recientes
      unawaited(_preloadArtworksForSongs(recents));
    } catch (e) {
      setState(() {
        _recentSongs = [];
        _showingRecents = true;
      });
    }
  }

  void _onSearchRecentsChanged() {
    final query = _quitarDiacriticos(_searchRecentsController.text.trim());
    if (query.isEmpty) {
      setState(() => _filteredRecents = []);
      return;
    }
    setState(() {
      _filteredRecents = _recentSongs.where((song) {
        final title = _quitarDiacriticos(song.title);
        final artist = _quitarDiacriticos(song.artist ?? '');
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
      final title = _quitarDiacriticos(song.title);
      final artist = _quitarDiacriticos(song.artist ?? '');
      return title.contains(query) || artist.contains(query);
    }).toList();
    
    setState(() {
      _filteredPlaylistSongs = filteredList;
    });
  }

  void _onPlaylistsShouldReload() {
    _loadPlaylists();
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

  // Agrega un ValueNotifier para el índice de tab si no existe
  final ValueNotifier<int> _selectedTabIndex = ValueNotifier<int>(0);

  Future<bool> onWillPop() async {
    // print('WillPopScope: tab= [32m${_selectedTabIndex.value} [0m');
    final state = ytScreenKey.currentState as dynamic;
    // print('YT state: $state');
    if (_selectedTabIndex.value == 1 && state?.canPopInternally() == true) {
      // print('Delegando pop a YT');
      state.handleInternalPop();
      return false;
    }
    // print('Pop manejado por home');
    if (_showingRecents || _showingPlaylistSongs) {
      setState(() {
        _showingRecents = false;
        _showingPlaylistSongs = false;
      });
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    playlistsShouldReload.removeListener(_onPlaylistsShouldReload);
    shortcutsShouldReload.removeListener(_onShortcutsShouldReload);
    _pageController.dispose();
    _searchRecentsController.dispose();
    _searchRecentsFocus.dispose();
    _searchPlaylistController.dispose();
    _searchPlaylistFocus.dispose();
    _debounce?.cancel();
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
  }

  Future<void> _playSongAndOpenPlayer(SongModel song, List<SongModel> queue, {String? queueSource}) async {
    // Deshabilitar temporalmente la navegación del overlay
    overlayPlayerNavigationEnabled.value = false;
    
    // Obtener la carátula para la pantalla del reproductor
    final songId = song.id;
    final songPath = song.data;
    final artUri = await getOrCacheArtwork(songId, songPath);
    
    // Crear el MediaItem para la pantalla del reproductor
    final mediaItem = MediaItem(
      id: song.data,
      title: song.title,
      artist: song.artist,
      duration: (song.duration != null && song.duration! > 0)
          ? Duration(milliseconds: song.duration!)
          : null,
      artUri: artUri,
      extras: {
        'songId': song.id,
        'albumId': song.albumId,
        'data': song.data,
      },
    );
    
    // Navegar a la pantalla del reproductor primero
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
          FullPlayerScreen(
            initialMediaItem: mediaItem,
            initialArtworkUri: artUri,
          ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
    
    // Activar indicador de carga
    playLoadingNotifier.value = true;
    
    // Reproducir la canción después de un breve delay para que se abra la pantalla
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        _playSong(song, queue, queueSource: queueSource);
        // Desactivar indicador de carga después de reproducir
        Future.delayed(const Duration(milliseconds: 200), () {
          playLoadingNotifier.value = false;
        });
      }
    });
    
    // Rehabilitar la navegación del overlay después de un delay
    Future.delayed(const Duration(milliseconds: 1000), () {
      overlayPlayerNavigationEnabled.value = true;
    });
  }

  Future<void> _playSong(SongModel song, List<SongModel> queue, {String? queueSource}) async {
    // Desactiva visualmente el shuffle
    try {
      final handler = await _getAudioHandler();
      if (handler != null) {
        handler.isShuffleNotifier.value = false;
      }
    } catch (_) {}
    const int maxQueueSongs = 200;
    final index = queue.indexWhere((s) => s.data == song.data);

    if (index != -1) {
      // Obtener AudioService de forma segura
      final handler = await _getAudioHandler();
      if (handler == null) {
        return;
      }

      // Comprobar si la cola actual es igual a la nueva (por ids y orden)
      final currentQueue = handler.queue.value;
      final isSameQueue = currentQueue.length == queue.length &&
        List.generate(queue.length, (i) => currentQueue[i].id == queue[i].data).every((x) => x);

      if (isSameQueue) {
        // Solo cambiar de canción
        await handler.skipToQueueItem(index);
        await handler.play();
        return;
      }

      // Limpiar la cola y el MediaItem antes de mostrar la nueva canción
      handler.queue.add([]);
      handler.mediaItem.add(null);
      
      // Crear MediaItem temporal para mostrar el overlay inmediatamente
      Uri? cachedArtUri;
      if (artworkCache.containsKey(song.data)) {
        cachedArtUri = artworkCache[song.data];
      } else {
        // Si no está en caché, intentar cargarla inmediatamente
        try {
          cachedArtUri = await getOrCacheArtwork(song.id, song.data);
        } catch (e) {
          // Si falla, continuar sin carátula
        }
      }
      
      final tempMediaItem = MediaItem(
        id: song.data,
        album: song.album ?? '',
        title: song.title,
        artist: song.artist ?? '',
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
      handler.mediaItem.add(tempMediaItem);

      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, queue.length);
      int end = (index + after).clamp(0, queue.length);
      List<SongModel> limitedQueue = queue.sublist(start, end);
      int newIndex = index - start;

      // Guardar el origen en SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      String origen = queueSource ??
        (_showingPlaylistSongs && _selectedPlaylist != null
          ? "${_selectedPlaylist?['name'] ?? ''}"
          : _showingRecents
            ? LocaleProvider.tr('recent_songs_title')
            : "Home");
      await prefs.setString('last_queue_source', origen);
      await (handler).setQueueFromSongs(
        limitedQueue,
        initialIndex: newIndex,
      );
      await (handler).play();
    }
  }

  Future<void> _addToFavorites(SongModel song) async {
    await FavoritesDB().addFavorite(song);
    favoritesShouldReload.value = !favoritesShouldReload.value;
  }

  Future<void> _handleLongPress(BuildContext context, SongModel song) async {
    HapticFeedback.mediumImpact();
    final isFavorite = await FavoritesDB().isFavorite(song.data);

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isFavorite ? Icons.delete_outline : Icons.favorite_border,
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
          ],
        ),
      ),
    );
  }

  Future<void> _removeFromPlaylistMassive() async {
    final selectedSongs = (_searchPlaylistController.text.isNotEmpty ? _filteredPlaylistSongs : _playlistSongs)
        .where((s) => _selectedPlaylistSongIds.contains(s.id));
    final count = _selectedPlaylistSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: TranslatedText('remove_from_playlist'),
        content: Text(count == 1
            ? LocaleProvider.tr('confirm_remove_from_playlist')
            : "${LocaleProvider.tr('confirm_remove_from_playlist')} ($count)"),
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
      await PlaylistsDB().removeSongFromPlaylist(_selectedPlaylist!['id'], song.data);
    }
    await _loadPlaylistSongs(_selectedPlaylist!);
    setState(() {
      _isSelectingPlaylistSongs = false;
      _selectedPlaylistSongIds.clear();
    });
  }

  Future<void> _addToFavoritesMassive() async {
    final selectedSongs = (_searchPlaylistController.text.isNotEmpty ? _filteredPlaylistSongs : _playlistSongs)
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
    final recents = await RecentsDB().getRecents();
    if (!mounted) return;
    final Set<int> selectedIds = {};
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
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
                                  child: QueryArtworkWidget(
                                    id: song.id,
                                    type: ArtworkType.AUDIO,
                                    artworkBorder: BorderRadius.circular(8),
                                    artworkHeight: 40,
                                    artworkWidth: 40,
                                    keepOldArtwork: true,
                                    nullArtworkWidget: Container(
                                      color: Theme.of(context).colorScheme.surfaceContainer,
                                      width: 40,
                                      height: 40,
                                      child: Icon(
                                        Icons.music_note,
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(song.artist ?? LocaleProvider.tr('unknown_artist'), maxLines: 1, overflow: TextOverflow.ellipsis),
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
                          final toAdd = recents.where((s) => selectedIds.contains(s.id));
                          for (final song in toAdd) {
                            await PlaylistsDB().addSongToPlaylist(_selectedPlaylist!['id'], song);
                          }
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            await _loadPlaylistSongs(_selectedPlaylist!);
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

  void _shuffleQuickPick() {
    final shortcutPaths = _shortcutSongs.map((s) => s.data).toSet();
    _shuffledQuickPick = _mostPlayed.where((s) => !shortcutPaths.contains(s.data)).toList();
    _shuffledQuickPick.shuffle();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final isSmallScreen = screenHeight < 650;

    final sizeScreen = MediaQuery.of(context).size;
    final aspectRatio = sizeScreen.height / sizeScreen.width;

    // Para 16:9 (≈1.77)
    final is16by9 = (aspectRatio < 1.85);

    // Para 18:9 (≈2.0)
    // final is18by9 = (aspectRatio >= 1.95 && aspectRatio < 2.05);

    // Para 19.5:9 (≈2.16)
    // final is195by9 = (aspectRatio >= 2.10);

    final quickPickSongsPerPage = 4;
    final limitedQuickPick = _shuffledQuickPick.take(20).toList();
    final quickPickPageCount = (limitedQuickPick.length / quickPickSongsPerPage).ceil();

    return WillPopScope(
      onWillPop: onWillPop,
      child: Scaffold(
        appBar: AppBar(
          leading: (_showingRecents || _showingPlaylistSongs)
              ? (_isSelectingPlaylistSongs
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () {
                        setState(() {
                          _showingRecents = false;
                          _showingPlaylistSongs = false;
                        });
                      },
                    ))
              : null,
          title: Row(
            children: [
              if (!_showingRecents && !_showingPlaylistSongs)
                const Icon(Icons.home_outlined, size: 28),
              if (!_showingRecents && !_showingPlaylistSongs)
                const SizedBox(width: 8),
              Expanded(
                child: _showingRecents
                    ? TranslatedText('recent', maxLines: 1, overflow: TextOverflow.ellipsis)
                    : _showingPlaylistSongs
                        ? (_isSelectingPlaylistSongs
                            ? Text('${_selectedPlaylistSongIds.length} ${LocaleProvider.tr('selected')}')
                            : ((_selectedPlaylist?['name'] ?? '').isNotEmpty
                                ? Text(
                                    (_selectedPlaylist?['name'] ?? '').length > 15
                                        ? (_selectedPlaylist?['name'] ?? '').substring(0, 15) + '...'
                                        : (_selectedPlaylist?['name'] ?? ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : TranslatedText('playlists', maxLines: 1, overflow: TextOverflow.ellipsis)))
                        : TranslatedText('home', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          actions: (!_showingRecents && !_showingPlaylistSongs)
              ? [
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
                              SettingsScreen(setThemeMode: widget.setThemeMode, setColorScheme: widget.setColorScheme),
                          transitionsBuilder: (context, animation, secondaryAnimation, child) {
                            const begin = Offset(1.0, 0.0);
                            const end = Offset.zero;
                            const curve = Curves.ease;
                            final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
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
              : _showingPlaylistSongs
                  ? [
                      if (_isSelectingPlaylistSongs) ...[
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: LocaleProvider.tr('remove_from_playlist'),
                          onPressed: _selectedPlaylistSongIds.isEmpty ? null : _removeFromPlaylistMassive,
                        ),
                        IconButton(
                          icon: const Icon(Icons.favorite_border),
                          tooltip: LocaleProvider.tr('add_to_favorites'),
                          onPressed: _selectedPlaylistSongIds.isEmpty ? null : _addToFavoritesMassive,
                        ),
                        IconButton(
                          icon: const Icon(Icons.select_all),
                          tooltip: LocaleProvider.tr('select_all'),
                          onPressed: () {
                            final songsToShow = _searchPlaylistController.text.isNotEmpty
                                ? _filteredPlaylistSongs
                                : _playlistSongs;
                            setState(() {
                              if (_selectedPlaylistSongIds.length == songsToShow.length) {
                                // Si todos están seleccionados, deseleccionar todos
                                _selectedPlaylistSongIds.clear();
                                if (_selectedPlaylistSongIds.isEmpty) {
                                  _isSelectingPlaylistSongs = false;
                                }
                              } else {
                                // Seleccionar todos
                                _selectedPlaylistSongIds.addAll(songsToShow.map((s) => s.id));
                              }
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: LocaleProvider.tr('cancel_selection'),
                          onPressed: () {
                            setState(() {
                              _isSelectingPlaylistSongs = false;
                              _selectedPlaylistSongIds.clear();
                            });
                          },
                        ),
                      ]
                      else ...[
                        IconButton(
                          icon: const Icon(Icons.shuffle, size: 28),
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
                              _playSongAndOpenPlayer(random, songsToShow, queueSource: _selectedPlaylist?['name'] ?? '');
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
                    child: TextField(
                      controller: _showingRecents
                          ? _searchRecentsController
                          : _searchPlaylistController,
                      focusNode: _showingRecents
                          ? _searchRecentsFocus
                          : _searchPlaylistFocus,
                      onChanged: (_) => _showingRecents
                          ? _onSearchRecentsChanged()
                          : _onSearchPlaylistChanged(),
                      decoration: InputDecoration(
                        hintText: LocaleProvider.tr('search_by_title_or_artist'),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: (_showingRecents
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
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      ),
                    ),
                  ),
                )
              : null,
        ),
        body: StreamBuilder<MediaItem?>(
          stream: audioHandler?.mediaItem,
          builder: (context, currentSnapshot) {
            final current = currentSnapshot.data;
            final space = current != null ? 100.0 : 0.0;

            return Padding(
              padding: EdgeInsets.only(bottom: space),
              child: _showingRecents
                  ? Builder(
                      builder: (context) {
                        final List<SongModel> songsToShow =
                            _searchRecentsController.text.isNotEmpty
                            ? _filteredRecents
                            : _recentSongs;
                        if (songsToShow.isEmpty) {
                          return const Center(
                            child: TranslatedText('no_recent_songs', style: TextStyle(fontSize: 16)),
                          );
                        }
                        return ListView.builder(
                          itemCount: songsToShow.length,
                          itemBuilder: (context, index) {
                            final song = songsToShow[index];
                            final isCurrent =
                                audioHandler?.mediaItem.value?.extras?['data'] ==
                                song.data;
                            final isPlaying =
                                audioHandler?.playbackState.value.playing ?? false;
                            final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: QueryArtworkWidget(
                                  id: song.id,
                                  type: ArtworkType.AUDIO,
                                  artworkBorder: BorderRadius.circular(8),
                                  artworkHeight: 50,
                                  artworkWidth: 50,
                                  keepOldArtwork: true,
                                  nullArtworkWidget: Container(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                                    width: 50,
                                    height: 50,
                                    child: Icon(
                                      Icons.music_note,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
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
                                        animate: isPlaying ? true : false,
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                        color: isCurrent
                                            ? (isAmoledTheme
                                                ? Colors.white
                                                : Theme.of(context).colorScheme.primary)
                                            : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                (song.artist?.trim().isEmpty ?? true)
                                    ? LocaleProvider.tr('unknown_artist')
                                    : song.artist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  isCurrent && isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: () {
                                  if (isCurrent) {
                                    isPlaying
                                        ? (audioHandler as MyAudioHandler).pause()
                                        : (audioHandler as MyAudioHandler).play();
                                  } else {
                                    // Precargar la carátula antes de reproducir
                                    unawaited(_preloadArtworkForSong(song));
                                    _playSongAndOpenPlayer(song, songsToShow);
                                  }
                                },
                              ),
                              selected: isCurrent,
                              selectedTileColor: isAmoledTheme
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.primaryContainer,
                              onTap: () async {
                                // Precargar la carátula antes de reproducir
                                unawaited(_preloadArtworkForSong(song));
                                _debounce?.cancel();
                                _debounce = Timer(const Duration(milliseconds: 300), () async {
                                  if (!mounted) return;
                                  await _playSongAndOpenPlayer(song, songsToShow);
                                });
                              },
                              onLongPress: () {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (context) => SafeArea(
                                    child: FutureBuilder<bool>(
                                      future: FavoritesDB().isFavorite(
                                        song.data,
                                      ),
                                      builder: (context, snapshot) {
                                        final isFav = snapshot.data ?? false;
                                        return Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
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
                                              leading: const Icon(Icons.delete_outline),
                                              title: TranslatedText('remove_from_recents'),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await RecentsDB().removeRecent(song.data);
                                                await _loadRecents();
                                              },
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    )
                  : _showingPlaylistSongs
                  ? Builder(
                      builder: (context) {
                        final List<SongModel> songsToShow =
                            _searchPlaylistController.text.isNotEmpty
                            ? _filteredPlaylistSongs
                            : _playlistSongs;
                        if (songsToShow.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.playlist_remove_outlined,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                                const SizedBox(height: 16),
                                TranslatedText('no_songs_in_playlist', style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                              ],
                            ),
                          );
                        }
                        return ListView.builder(
                          itemCount: songsToShow.length,
                          itemBuilder: (context, index) {
                            final song = songsToShow[index];
                            final isCurrent =
                                audioHandler?.mediaItem.value?.extras?['data'] ==
                                song.data;
                            final isPlaying =
                                audioHandler?.playbackState.value.playing ?? false;
                            final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
                            return ListTile(
                              onTap: () {
                                if (_isSelectingPlaylistSongs) {
                                  _onPlaylistSongSelected(song);
                                } else {
                                  _debounce?.cancel();
                                  _debounce = Timer(const Duration(milliseconds: 300), () async {
                                    if (!mounted) return;
                                    await _playSongAndOpenPlayer(song, songsToShow);
                                  });
                                }
                              },
                              onLongPress: () async {
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
                                } else {
                                  final isPinned = await ShortcutsDB().isShortcut(song.data);
                                  final isFav = await FavoritesDB().isFavorite(song.data);
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
                                            title: TranslatedText(
                                              isFav ? 'remove_from_favorites' : 'add_to_favorites',
                                            ),
                                            onTap: () async {
                                              if (!context.mounted) return;
                                              Navigator.of(context).pop();
                                              if (isFav) {
                                                await FavoritesDB().removeFavorite(song.data);
                                                favoritesShouldReload.value = !favoritesShouldReload.value;
                                              } else {
                                                await FavoritesDB().addFavorite(song);
                                                favoritesShouldReload.value = !favoritesShouldReload.value;
                                              }
                                            },
                                          ),
                                          ListTile(
                                            leading: const Icon(Icons.playlist_remove),
                                            title: TranslatedText('remove_from_playlist'),
                                            onTap: () async {
                                              if (!context.mounted) return;
                                              Navigator.of(context).pop();
                                              await PlaylistsDB().removeSongFromPlaylist(_selectedPlaylist!['id'], song.data);
                                              await _loadPlaylistSongs(_selectedPlaylist!);
                                            },
                                          ),
                                          ListTile(
                                            leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                                            title: TranslatedText(isPinned ? 'unpin_shortcut' : 'pin_shortcut'),
                                            onTap: () async {
                                              if (!context.mounted) return;
                                              Navigator.of(context).pop();
                                              if (isPinned) {
                                                await ShortcutsDB().removeShortcut(song.data);
                                              } else {
                                                await ShortcutsDB().addShortcut(song.data);
                                              }
                                              shortcutsShouldReload.value = !shortcutsShouldReload.value;
                                            },
                                          ),
                                          ListTile(
                                            leading: const Icon(Icons.check_box_outlined),
                                            title: TranslatedText('select'),
                                            onTap: () {
                                              Navigator.of(context).pop();
                                              setState(() {
                                                _isSelectingPlaylistSongs = true;
                                                _selectedPlaylistSongIds.add(song.id);
                                              });
                                            },
                                          ),
                                        ],
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
                                      value: _selectedPlaylistSongIds.contains(song.id),
                                      onChanged: (checked) {
                                        setState(() {
                                          if (checked == true) {
                                            _selectedPlaylistSongIds.add(song.id);
                                          } else {
                                            _selectedPlaylistSongIds.remove(song.id);
                                            if (_selectedPlaylistSongIds.isEmpty) {
                                              _isSelectingPlaylistSongs = false;
                                            }
                                          }
                                        });
                                      },
                                    ),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: QueryArtworkWidget(
                                      id: song.id,
                                      type: ArtworkType.AUDIO,
                                      artworkBorder: BorderRadius.circular(8),
                                      artworkHeight: 50,
                                      artworkWidth: 50,
                                      keepOldArtwork: true,
                                      nullArtworkWidget: Container(
                                        color: Theme.of(context).colorScheme.surfaceContainer,
                                        width: 50,
                                        height: 50,
                                        child: Icon(
                                          Icons.music_note,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                      ),
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
                                        animate: isPlaying ? true : false,
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      song.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                        color: isCurrent
                                            ? (isAmoledTheme
                                                ? Colors.white
                                                : Theme.of(context).colorScheme.primary)
                                            : Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                (song.artist?.trim().isEmpty ?? true)
                                    ? LocaleProvider.tr('unknown_artist')
                                    : song.artist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: Icon(
                                  isCurrent && isPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                onPressed: () {
                                  if (isCurrent) {
                                    isPlaying
                                        ? (audioHandler as MyAudioHandler).pause()
                                        : (audioHandler as MyAudioHandler).play();
                                  } else {
                                    // Precargar la carátula antes de reproducir
                                    unawaited(_preloadArtworkForSong(song));
                                    _playSongAndOpenPlayer(song, songsToShow);
                                  }
                                },
                              ),
                              selected: isCurrent,
                              selectedTileColor: isAmoledTheme
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.primaryContainer,
                              
                            );
                          },
                        );
                      },
                    )
                  : SingleChildScrollView(
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_updateVersion != null && _updateVersion!.isNotEmpty && _updateApkUrl != null)
                            ...[
                              const SizedBox(height: 16),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                                child: Material(
                                  color: Theme.of(context).colorScheme.surfaceContainer,
                                  borderRadius: BorderRadius.circular(12),
                                  child: ListTile(
                                    leading: Icon(Icons.system_update, color: Theme.of(context).colorScheme.onSurface),
                                    title: ValueListenableBuilder<String>(
                                      valueListenable: languageNotifier,
                                      builder: (context, lang, child) {
                                        return Text(
                                          '${LocaleProvider.tr('new_version_available')} $_updateVersion ${LocaleProvider.tr('available')}',
                                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold),
                                        );
                                      },
                                    ),
                                    trailing: TextButton(
                                      style: TextButton.styleFrom(
                                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      child: Text(LocaleProvider.tr('update'), style: TextStyle(color: colorSchemeNotifier.value == AppColorScheme.amoled ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurface),),
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (_) => const UpdateScreen()),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: TranslatedText(
                              'quick_access',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 0),
                            child: SizedBox(
                              height: is16by9
                                  ? screenHeight * 0.38
                                  : isSmallScreen
                                  ? screenHeight * 0.32
                                  : screenHeight * 0.30,
                              child: PageView(
                                controller: _pageController,
                                onPageChanged: (_) {},
                                children: List.generate(3, (pageIndex) {
                                  final items = _accessDirectSongs.skip(pageIndex * 6).take(6).toList();
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
                                          const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 3,
                                            mainAxisSpacing: 12,
                                            crossAxisSpacing: 12,
                                            childAspectRatio: 1,
                                          ),
                                      itemBuilder: (context, index) {
                                        if (index < items.length) {
                                          final song = items[index];
                                          final isPlaying = audioHandler?.playbackState.value.playing ?? false;
                                          audioHandler
                                                  ?.mediaItem
                                                  .value
                                                  ?.extras?['data'] ==
                                              song.data;
                                          return AnimatedTapButton(
                                            onTap: () {
                                              // Precargar la carátula antes de reproducir
                                              unawaited(_preloadArtworkForSong(song));
                                              _debounce?.cancel();
                                              _debounce = Timer(const Duration(milliseconds: 300), () async {
                                                if (!mounted) return;
                                                await _playSongAndOpenPlayer(song, _accessDirectSongs, queueSource: LocaleProvider.tr('quick_access_songs'));
                                              });
                                            },
                                            onLongPress: () async {
                                              HapticFeedback.mediumImpact();
                                              if (!context.mounted) return;
                                              final isPinned = _shortcutSongs.any((s) => s.data == song.data);
                                              final isFavorite = await FavoritesDB().isFavorite(song.data);
                                              if (!context.mounted) return;
                                              showModalBottomSheet(
                                                context: context,
                                                builder: (context) => SafeArea(
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      ListTile(
                                                        leading: Icon(
                                                          isFavorite ? Icons.delete_outline : Icons.favorite_border,
                                                        ),
                                                        title: TranslatedText(
                                                          isFavorite ? 'remove_from_favorites' : 'add_to_favorites',
                                                        ),
                                                        onTap: () async {
                                                          if (!context.mounted) return;
                                                          Navigator.of(context).pop();
                                                          if (isFavorite) {
                                                            await FavoritesDB().removeFavorite(song.data);
                                                            favoritesShouldReload.value = !favoritesShouldReload.value;
                                                          } else {
                                                            await FavoritesDB().addFavorite(song);
                                                            favoritesShouldReload.value = !favoritesShouldReload.value;
                                                          }
                                                        },
                                                      ),
                                                      if (isPinned)
                                                        ListTile(
                                                          leading: const Icon(Icons.push_pin),
                                                          title: TranslatedText('unpin_shortcut'),
                                                          onTap: () async {
                                                            if (!context.mounted) return;
                                                            Navigator.of(context).pop();
                                                            await ShortcutsDB().removeShortcut(song.data);
                                                            shortcutsShouldReload.value = !shortcutsShouldReload.value;
                                                          },
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            },
                                            child: AspectRatio(
                                              aspectRatio: 1,
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(12),
                                                child: Stack(
                                                  children: [
                                                    QueryArtworkWidget(
                                                      id: song.id,
                                                      type: ArtworkType.AUDIO,
                                                      artworkFit: BoxFit.cover,
                                                      artworkBorder: BorderRadius.circular(12),
                                                      keepOldArtwork: true,
                                                      artworkHeight: double.infinity,
                                                      artworkWidth: double.infinity,
                                                      artworkQuality: FilterQuality.high,
                                                      size: 400,
                                                      nullArtworkWidget: Container(
                                                        color: Theme.of(context).colorScheme.surfaceContainer,
                                                        child: Center(
                                                          child: Icon(
                                                            Icons.music_note,
                                                            color: Theme.of(context).colorScheme.onSurface,
                                                            size: 48,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    // Animación visualizer en la esquina superior izquierda si es la canción actual
                                                    if (audioHandler?.mediaItem.value?.extras?['data'] == song.data)
                                                      Positioned(
                                                        top: 6,
                                                        left: 6,
                                                        child: MiniMusicVisualizer(
                                                          color: Colors.white,
                                                          width: 5,
                                                          height: 22,
                                                          radius: 4,
                                                          animate: isPlaying ? true : false,
                                                        ),
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
                                                            size: 20,
                                                            shadows: [
                                                              Shadow(
                                                                blurRadius: 4,
                                                                color: Colors.black,
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    Positioned(
                                                      left: 0,
                                                      right: 0,
                                                      bottom: 0,
                                                      child: Container(
                                                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
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
                                                          song.title,
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: const TextStyle(
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
                                        } else {
                                          return Container(
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.surfaceContainer,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              Icons.music_note,
                                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                              size: 36,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  );
                                }),
                              ),
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
                                activeDotColor: Theme.of(context).colorScheme.primary,
                                dotColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24)
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),

                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: TranslatedText(
                              'quick_pick',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_quickPickPages.isEmpty)
                            const SizedBox(height: 40),
                          if (_quickPickPages.isNotEmpty)
                            const SizedBox(height: 12),
                          (_quickPickPages.isEmpty)
                              ? Center(
                                child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.music_off,
                                    size: 48,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(height: 16),
                                  TranslatedText('no_songs_to_show', style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                                ],
                              ))
                              : Column(
                                  children: [
                                    SizedBox(
                                      height: 320,
                                      child: PageView.builder(
                                        controller: _quickPickPageController,
                                        itemCount: quickPickPageCount,
                                        itemBuilder: (context, pageIndex) {
                                          final songs = limitedQuickPick.skip(pageIndex * quickPickSongsPerPage).take(quickPickSongsPerPage).toList();
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
                                                final isCurrent = audioHandler?.mediaItem.value?.extras?['data'] == song.data;
                                                final isPlaying = audioHandler?.playbackState.value.playing ?? false;
                                                return Padding(
                                                  padding: EdgeInsets.only(
                                                    bottom:
                                                        index < songs.length - 1
                                                        ? 8.0
                                                        : 0,
                                                  ),
                                                  child: ListTile(
                                                    key: ValueKey(song.id),
                                                    contentPadding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 0,
                                                        ),
                                                    splashColor:
                                                        Colors.transparent,
                                                    leading: ClipRRect(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: QueryArtworkWidget(
                                                        id: song.id,
                                                        type: ArtworkType.AUDIO,
                                                        artworkHeight: 60,
                                                        artworkWidth: 57,
                                                        artworkBorder:
                                                            BorderRadius.zero,
                                                        artworkFit:
                                                            BoxFit.cover,
                                                        keepOldArtwork: true,
                                                        nullArtworkWidget: Container(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .surfaceContainer,
                                                          width: 60,
                                                          height: 67,
                                                          child: Icon(
                                                            Icons.music_note,
                                                            color: Theme.of(context).colorScheme.onSurface,
                                                          ),
                                                        ),
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
                                                              animate: isPlaying ? true : false,
                                                            ),
                                                          ),
                                                        Expanded(
                                                          child: Text(
                                                            song.title,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow.ellipsis,
                                                            style: TextStyle(
                                                              fontWeight: isCurrent
                                                                  ? FontWeight.bold
                                                                  : FontWeight.normal,
                                                              color: isCurrent 
                                                                  ? Theme.of(context).colorScheme.primary
                                                                  : null,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    subtitle: Text(
                                                      (song.artist
                                                                  ?.trim()
                                                                  .isEmpty ??
                                                              true)
                                                          ? LocaleProvider.tr('unknown_artist')
                                                          : song.artist!,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: isCurrent
                                                            ? Theme.of(context).colorScheme.primary
                                                            : null,
                                                      ),
                                                    ),
                                                    trailing: const Opacity(
                                                      opacity: 0,
                                                      child: Icon(
                                                        Icons.more_vert,
                                                      ),
                                                    ),
                                                    onTap: () {
                                                      // Precargar la carátula antes de reproducir
                                                      unawaited(_preloadArtworkForSong(song));
                                                      _debounce?.cancel();
                                                      _debounce = Timer(const Duration(milliseconds: 300), () async {
                                                        if (!mounted) return;
                                                        await _playSongAndOpenPlayer(song, _mostPlayed, queueSource: LocaleProvider.tr('quick_pick_songs'));
                                                      });
                                                    },
                                                    onLongPress: () =>
                                                        _handleLongPress(
                                                          context,
                                                          song,
                                                        ),
                                                  ),
                                                );
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    SmoothPageIndicator(
                                      controller: _quickPickPageController,
                                      count: quickPickPageCount,
                                      effect: WormEffect(
                                        dotHeight: 8,
                                        dotWidth: 8,
                                        activeDotColor: Theme.of(context).colorScheme.primary,
                                        dotColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.24),
                                      ),
                                    ),
                                  ],
                                ),
                          const SizedBox(height: 32),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                                      icon: const Icon(Icons.refresh, size: 28),
                                      tooltip: LocaleProvider.tr('reload'),
                                      onPressed: _loadPlaylists,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.add, size: 28),
                                      tooltip: LocaleProvider.tr('create_new_playlist'),
                                      padding: const EdgeInsets.only(left: 8),
                                      onPressed: () async {
                                        final controller = TextEditingController();
                                        final result = await showDialog<String>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: TranslatedText('new_playlist'),
                                            content: TextField(
                                              controller: controller,
                                              autofocus: true,
                                              decoration: InputDecoration(
                                                labelText: LocaleProvider.tr('playlist_name'),
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(context).pop(),
                                                child: TranslatedText('cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () {
                                                  Navigator.of(
                                                    context,
                                                  ).pop(controller.text.trim());
                                                },
                                                child: TranslatedText('create'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (result != null && result.isNotEmpty) {
                                          await PlaylistsDB().createPlaylist(
                                            result,
                                          );
                                          await _loadPlaylists();
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Aquí mostramos las playlists
                          if (_playlists.isEmpty)
                            
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 22),
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.playlist_remove,
                                      size: 48,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                    ),
                                    const SizedBox(height: 16),
                                    TranslatedText('no_playlists', style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
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
                                      leading: (() {
                                        final rawList =
                                            playlist['songs'] as List?;
                                        // Filtra solo rutas válidas (no nulos ni vacíos)
                                        final filtered = (rawList ?? [])
                                            .where(
                                              (e) =>
                                                  e != null &&
                                                  e.toString().isNotEmpty,
                                            )
                                            .map((e) => e.toString())
                                            .toList();
                                        final firstSongPath =
                                            filtered.isNotEmpty
                                            ? filtered[0]
                                            : null;
                                        final songIndex = allSongs.indexWhere(
                                          (s) => s.data == firstSongPath,
                                        );
                                        if (songIndex != -1) {
                                          final song = allSongs[songIndex];
                                          return ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: QueryArtworkWidget(
                                              id: song.id,
                                              type: ArtworkType.AUDIO,
                                              artworkHeight: 60,
                                              artworkWidth: 57,
                                              artworkBorder:
                                                  BorderRadius.circular(8),
                                              nullArtworkWidget: Container(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.surfaceContainer,
                                                width: 50,
                                                height: 50,
                                                child: Icon(
                                                  Icons.music_note,
                                                  color: Theme.of(context).colorScheme.onSurface,
                                                ),
                                              ),
                                            ),
                                          );
                                        } else {
                                          return Container(
                                            width: 57,
                                            height: 57,
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.surfaceContainer,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Icon(
                                              Icons.music_note,
                                              color: Theme.of(context).colorScheme.onSurface,
                                            ),
                                          );
                                        }
                                      })(),
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
                                                  title: TranslatedText('rename_playlist'),
                                                  onTap: () async {
                                                    Navigator.of(context).pop();
                                                    final controller =
                                                        TextEditingController(
                                                          text:
                                                              playlist['name'],
                                                        );
                                                    final result = await showDialog<String>(
                                                      context: context,
                                                      builder: (context) => AlertDialog(
                                                        title: TranslatedText('rename_playlist'),
                                                        content: TextField(
                                                          controller:
                                                              controller,
                                                          autofocus: true,
                                                          decoration:
                                                              InputDecoration(
                                                                labelText: LocaleProvider.tr('new_name'),
                                                              ),
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.of(
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
                                                                controller.text
                                                                    .trim(),
                                                              );
                                                            },
                                                            child: TranslatedText(
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
                                                  title: TranslatedText('delete_playlist'),
                                                  onTap: () async {
                                                    Navigator.of(context).pop();
                                                    final confirm = await showDialog<bool>(
                                                      context: context,
                                                      builder: (context) => AlertDialog(
                                                        title: TranslatedText('delete_playlist'),
                                                        content: TranslatedText('delete_playlist_confirm'),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.of(
                                                                  context,
                                                                ).pop(false),
                                                            child: TranslatedText(
                                                              'cancel',
                                                            ),
                                                          ),
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.of(
                                                                  context,
                                                                ).pop(true),
                                                            child: TranslatedText(
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
                        ],
                      ),
                    ),
            );
          },
        ),
      ),
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