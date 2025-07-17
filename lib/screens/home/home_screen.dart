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

enum OrdenCancionesPlaylist { normal, alfabetico, invertido, ultimoAgregado }

class HomeScreen extends StatefulWidget {
  final void Function(int)? onTabChange;
  final void Function(AppThemeMode)? setThemeMode;
  final void Function(AppColorScheme)? setColorScheme;
  const HomeScreen({super.key, this.onTabChange, this.setThemeMode, this.setColorScheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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

  /// Helper para obtener el AudioHandler de forma segura
  Future<MyAudioHandler?> _getAudioHandler() async {
    final handler = await getAudioServiceSafely();
    return handler as MyAudioHandler?;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOrderFilter().then((_) {
      _loadAllSongs();
      _loadMostPlayed().then((_) {
        _initQuickPickPages();
        setState(() {});
      });
      _loadPlaylists();
    });
    playlistsShouldReload.addListener(_onPlaylistsShouldReload);
    _buscarActualizacion();
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

  void _initQuickPickPages() {
    _quickPickPages.clear();
    final songs = List<SongModel>.from(_mostPlayed);
    songs.shuffle();
    // Divide la lista en páginas de 4, sin repetir
    for (int i = 0; i < 5; i++) {
      final start = i * 4;
      final end = (start + 4).clamp(0, songs.length);
      if (start < songs.length) {
        _quickPickPages.add(songs.sublist(start, end));
      }
    }
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
    final db = PlaylistsDB();
    List<Map<String, dynamic>> playlistsWithSongs = [];
    for (final playlist in playlists) {
      final dbInstance = await db.database;
      final songsRows = await dbInstance.query(
        'playlist_songs',
        where: 'playlist_id = ?',
        whereArgs: [playlist['id']],
        orderBy: 'id DESC',
      );
      final songPaths = songsRows.map((e) => e['song_path'] as String).toList();
      playlistsWithSongs.add({...playlist, 'songs': songPaths});
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
  }

  Future<void> _loadMostPlayed() async {
    final songs = await MostPlayedDB().getMostPlayed(limit: 40);
    setState(() {
      _mostPlayed = songs;
    });
  }

  Future<void> _loadRecents() async {
    try {
      final recents = await RecentsDB().getRecents();
      setState(() {
        _recentSongs = recents;
        _showingRecents = true;
      });
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

  Future<bool> _onWillPop() async {
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
    _pageController.dispose();
    _searchRecentsController.dispose();
    _searchRecentsFocus.dispose();
    _searchPlaylistController.dispose();
    _searchPlaylistFocus.dispose();
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

  Future<void> _playSong(SongModel song, List<SongModel> queue) async {
    const int maxQueueSongs = 200;
    final index = queue.indexWhere((s) => s.data == song.data);

    if (index != -1) {
      // Obtener AudioService de forma segura
      final handler = await _getAudioHandler();
      if (handler == null) {
        // print('❌ No se pudo obtener el AudioService');
        return;
      }
      
      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, queue.length);
      int end = (index + after).clamp(0, queue.length);
      List<SongModel> limitedQueue = queue.sublist(start, end);
      int newIndex = index - start;

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
    _playSong(song, _playlistSongs);
  }

  void _handlePlaylistSongLongPress(BuildContext context, SongModel song) async {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: FutureBuilder<bool>(
          future: FavoritesDB().isFavorite(song.data),
          builder: (context, snapshot) {
            final isFav = snapshot.data ?? false;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(isFav ? Icons.delete_outline : Icons.favorite_border),
                  title: TranslatedText(isFav ? 'remove_from_favorites' : 'add_to_favorites'),
                  onTap: () async {
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
                    Navigator.of(context).pop();
                    await PlaylistsDB().removeSongFromPlaylist(_selectedPlaylist!['id'], song.data);
                    await _loadPlaylistSongs(_selectedPlaylist!);
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
            );
          },
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    // Divide las canciones en páginas de 6
    List<List<SongModel>> pages = List.generate(3, (i) {
      final start = i * 6;
      final end = (start + 6).clamp(0, _mostPlayed.length);
      return _mostPlayed.length > start
          ? _mostPlayed.sublist(start, end)
          : <SongModel>[];
    });

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

    return WillPopScope(
      onWillPop: _onWillPop,
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
                              _playSong(random, songsToShow);
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
                              title: Text(
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
                                    _playSong(song, songsToShow);
                                  }
                                },
                              ),
                              selected: isCurrent,
                              selectedTileColor: isAmoledTheme
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Theme.of(context).colorScheme.primaryContainer,
                              onTap: () async {
                                await _playSong(song, songsToShow);
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
                              onTap: () => _onPlaylistSongSelected(song),
                              onLongPress: () {
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
                                  _handlePlaylistSongLongPress(context, song);
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
                              title: Text(
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
                                    _playSong(song, songsToShow);
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
                                  final items = pages[pageIndex];
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
                                          audioHandler
                                                  ?.mediaItem
                                                  .value
                                                  ?.extras?['data'] ==
                                              song.data;
                                          return AnimatedTapButton(
                                            onTap: () {
                                              _playSong(song, _mostPlayed);
                                            },
                                            onLongPress: () {
                                              _handleLongPress(context, song);
                                            },
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: Stack(
                                                children: [
                                                  QueryArtworkWidget(
                                                    id: song.id,
                                                    type: ArtworkType.AUDIO,
                                                    artworkFit: BoxFit.cover,
                                                    artworkBorder:
                                                        BorderRadius.circular(12),
                                                    keepOldArtwork: true,
                                                    artworkHeight: 120,
                                                    artworkWidth: 120,
                                                    artworkQuality:
                                                        FilterQuality.high,
                                                    size: 400,
                                                    nullArtworkWidget: Container(
                                                      width: 120,
                                                      height: 120,
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(context).colorScheme.surfaceContainer,
                                                        borderRadius: BorderRadius.circular(12),
                                                      ),
                                                      child: Center(
                                                        child: Icon(
                                                          Icons.music_note,
                                                          color: Theme.of(context).colorScheme.onSurface,
                                                          size: 48,
                                                        ),
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
                          const SizedBox(height: 18),
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
                                  TranslatedText('no_songs_to_show', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                                ],
                              ))
                              : Column(
                                  children: [
                                    SizedBox(
                                      height: 320,
                                      child: PageView.builder(
                                        controller: _quickPickPageController,
                                        itemCount: _quickPickPages.length,
                                        itemBuilder: (context, pageIndex) {
                                          final songs =
                                              _quickPickPages[pageIndex];
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
                                                    title: Text(
                                                      song.title,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
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
                                                    ),
                                                    trailing: const Opacity(
                                                      opacity: 0,
                                                      child: Icon(
                                                        Icons.more_vert,
                                                      ),
                                                    ),
                                                    onTap: () => _playSong(
                                                      song,
                                                      _mostPlayed,
                                                    ),
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
                                      count: _quickPickPages.length,
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