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
import 'package:music/utils/db/recent_db.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/db/shortcuts_db.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:music/utils/db/playlist_model.dart' as hive_model;
import 'package:music/screens/play/player_screen.dart';

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

  bool _isSelecting = false;
  final Set<int> _selectedSongIds = {};

  static const String _orderPrefsKey = 'favorites_screen_order_filter';

  Timer? _debounce;
  Timer? _playingDebounce;
  Timer? _mediaItemDebounce;
  final ValueNotifier<bool> _isPlayingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<MediaItem?> _currentMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);
  final ValueNotifier<MediaItem?> _immediateMediaItemNotifier =
      ValueNotifier<MediaItem?>(null);

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
    favoritesShouldReload.addListener(() {
      _loadFavorites();
    });

    // Inicializar con el valor actual si ya hay algo reproduciéndose
    if (audioHandler?.mediaItem.valueOrNull != null) {
      _immediateMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
      _currentMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
    }

    // Inicializar el estado de reproducción actual
    if (audioHandler?.playbackState.valueOrNull != null) {
      _isPlayingNotifier.value =
          audioHandler!.playbackState.valueOrNull!.playing;
    }

    // Escuchar cambios en el estado de reproducción con debounce
    audioHandler?.playbackState.listen((state) {
      _playingDebounce?.cancel();
      _playingDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
          _isPlayingNotifier.value = state.playing;
        }
      });
    });

    // Escuchar cambios en el MediaItem inmediatamente (para detección de canción actual)
    audioHandler?.mediaItem.listen((mediaItem) {
      if (mounted) {
        _immediateMediaItemNotifier.value = mediaItem;
      }
    });

    // Escuchar cambios en el MediaItem con debounce (para espaciado y elementos no críticos)
    audioHandler?.mediaItem.listen((mediaItem) {
      _mediaItemDebounce?.cancel();
      _mediaItemDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) {
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
    favoritesShouldReload.removeListener(() {
      _loadFavorites();
    });
    _debounce?.cancel();
    _playingDebounce?.cancel();
    _mediaItemDebounce?.cancel();
    _isPlayingNotifier.dispose();
    _currentMediaItemNotifier.dispose();
    _immediateMediaItemNotifier.dispose();
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
      _immediateMediaItemNotifier.value = audioHandler!.mediaItem.valueOrNull;
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
    const int maxQueueSongs = 200;
    final index = _favorites.indexWhere((s) => s.data == song.data);

    if (index == -1) return;
    final handler = audioHandler as MyAudioHandler;
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

    // Limpiar la cola y el MediaItem antes de mostrar la nueva canción
    (audioHandler as MyAudioHandler).queue.add([]);
    (audioHandler as MyAudioHandler).mediaItem.add(null);

    // Precargar la carátula antes de crear el MediaItem temporal
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

    // Solo guardar el origen si se va a cambiar la cola
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'last_queue_source',
      LocaleProvider.tr('favorites_title'),
    );

    int before = (maxQueueSongs / 2).floor();
    int after = maxQueueSongs - before;
    int start = (index - before).clamp(0, _favorites.length);
    int end = (index + after).clamp(0, _favorites.length);
    List<SongModel> limitedQueue = _favorites.sublist(start, end);
    int newIndex = index - start;

    await handler.setQueueFromSongs(limitedQueue, initialIndex: newIndex);
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
      extras: {'songId': song.id, 'albumId': song.albumId, 'data': song.data},
    );

    // Navegar a la pantalla del reproductor primero
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            FullPlayerScreen(initialMediaItem: mediaItem),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );

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
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
          ],
        ),
      ),
    );
  }

  Future<void> _handleAddToPlaylistSingle(
    BuildContext context,
    SongModel song,
  ) async {
    final playlists = await PlaylistsDB()
        .getAllPlaylists(); // List<PlaylistModel>
    if (!context.mounted) return;
    final TextEditingController playlistNameController =
        TextEditingController();
    final selectedPlaylistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty) ...[
                for (final playlist in playlists)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.of(context).pop(playlist.id);
                    },
                    child: Text(playlist.name),
                  ),
                const Divider(),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                  autofocus: playlists.isEmpty,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: TranslatedText('create_playlist'),
                onPressed: () async {
                  final name = playlistNameController.text.trim();
                  if (name.isEmpty) return;
                  final id = await PlaylistsDB().createPlaylist(name);
                  setStateDialog(() {
                    playlists.insert(
                      0,
                      hive_model.PlaylistModel(
                        id: id,
                        name: name,
                        songPaths: [],
                      ),
                    );
                  });
                  playlistNameController.clear();

                  // Notificar a la pantalla de inicio que debe actualizar las playlists
                  playlistsShouldReload.value = !playlistsShouldReload.value;

                  if (context.mounted) {
                    Navigator.of(context).pop(id);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
    if (selectedPlaylistId != null) {
      await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);

      // Notificar a la pantalla de inicio que debe actualizar las playlists
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }
  }

  Future<void> _handleAddToPlaylistMassive(BuildContext context) async {
    final playlists = await PlaylistsDB()
        .getAllPlaylists(); // List<PlaylistModel>
    if (!context.mounted) return;
    final TextEditingController playlistNameController =
        TextEditingController();
    final selectedPlaylistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) => SimpleDialog(
            title: TranslatedText('select_playlist'),
            children: [
              if (playlists.isNotEmpty) ...[
                for (final playlist in playlists)
                  SimpleDialogOption(
                    onPressed: () {
                      Navigator.of(context).pop(playlist.id);
                    },
                    child: Text(playlist.name),
                  ),
                const Divider(),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: playlistNameController,
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('new_playlist_name'),
                  ),
                  autofocus: playlists.isEmpty,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.add),
                label: TranslatedText('create_playlist'),
                onPressed: () async {
                  final name = playlistNameController.text.trim();
                  if (name.isEmpty) return;
                  final id = await PlaylistsDB().createPlaylist(name);
                  playlistsShouldReload.value = !playlistsShouldReload.value;
                  setStateDialog(() {
                    playlists.insert(
                      0,
                      hive_model.PlaylistModel(
                        id: id,
                        name: name,
                        songPaths: [],
                      ),
                    );
                  });
                  playlistNameController.clear();
                  if (context.mounted) {
                    Navigator.of(context).pop(id);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
    if (selectedPlaylistId != null) {
      final selectedSongs =
          (_searchController.text.isNotEmpty ? _filteredFavorites : _favorites)
              .where((s) => _selectedSongIds.contains(s.id));
      for (final song in selectedSongs) {
        await PlaylistsDB().addSongToPlaylist(selectedPlaylistId, song);
      }
      setState(() {
        _isSelecting = false;
        _selectedSongIds.clear();
      });

      // Notificar a la pantalla de inicio que debe actualizar las playlists
      playlistsShouldReload.value = !playlistsShouldReload.value;
    }
  }

  Future<void> _removeFromFavoritesMassive() async {
    final selectedSongs =
        (_searchController.text.isNotEmpty ? _filteredFavorites : _favorites)
            .where((s) => _selectedSongIds.contains(s.id));
    final count = _selectedSongIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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

  Future<void> _showAddFromRecentsDialog() async {
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
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainer,
                                      width: 40,
                                      height: 40,
                                      child: Icon(
                                        Icons.music_note,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
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
                            ),
                            subtitle: Text(
                              song.artist ??
                                  LocaleProvider.tr('unknown_artist'),
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
                            await FavoritesDB().addFavorite(song);
                          }
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            await _loadFavorites();
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

  Widget _buildOptimizedListTile(
    BuildContext context,
    SongModel song,
    bool isCurrent,
    bool playing,
    bool isAmoledTheme,
  ) {
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
                animate: playing ? true : false,
              ),
            ),
          Expanded(
            child: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCurrent
                  ? TextStyle(
                      color: isAmoledTheme
                          ? Colors.white
                          : Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
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
        icon: Icon(isCurrent && playing ? Icons.pause : Icons.play_arrow),
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
      selected: isCurrent,
      selectedTileColor: isAmoledTheme
          ? Colors.white.withValues(alpha: 0.1)
          : Theme.of(context).colorScheme.primaryContainer,
      onTap: () => _onSongSelected(song),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: _isSelecting
            ? Text(
                '${_selectedSongIds.length} ${LocaleProvider.tr('selected')}',
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_border, size: 28),
                  const SizedBox(width: 8),
                  TranslatedText('favorites'),
                ],
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
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: LocaleProvider.tr('cancel_selection'),
                  onPressed: () {
                    setState(() {
                      _isSelecting = false;
                      _selectedSongIds.clear();
                    });
                  },
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.shuffle, size: 28),
                  tooltip: 'Aleatorio',
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
                  tooltip: LocaleProvider.tr('add_from_recents'),
                  onPressed: _showAddFromRecentsDialog,
                ),
                PopupMenuButton<OrdenFavoritos>(
                  icon: const Icon(Icons.sort, size: 28),
                  onSelected: (orden) {
                    setState(() {
                      _orden = orden;
                      _ordenarFavoritos();
                    });
                    _saveOrderFilter();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: OrdenFavoritos.normal,
                      child: TranslatedText('last_added'),
                    ),
                    PopupMenuItem(
                      value: OrdenFavoritos.ultimoAgregado,
                      child: TranslatedText('invert_order'),
                    ),
                    PopupMenuItem(
                      value: OrdenFavoritos.alfabetico,
                      child: TranslatedText('alphabetical_az'),
                    ),
                    PopupMenuItem(
                      value: OrdenFavoritos.invertido,
                      child: TranslatedText('alphabetical_za'),
                    ),
                  ],
                ),
              ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ValueListenableBuilder<String>(
              valueListenable: languageNotifier,
              builder: (context, lang, child) {
                return TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: (_) => _onSearchChanged(),
                  decoration: InputDecoration(
                    hintText: LocaleProvider.tr('search_by_title_or_artist'),
                    prefixIcon: const Icon(Icons.search),
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
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Builder(
                builder: (context) {
                  final List<SongModel> songsToShow =
                      _searchController.text.isNotEmpty
                      ? _filteredFavorites
                      : _favorites;
                  if (songsToShow.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.favorite_border,
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
                    );
                  }
                  return ValueListenableBuilder<MediaItem?>(
                    valueListenable: _currentMediaItemNotifier,
                    builder: (context, debouncedMediaItem, child) {
                      final space = debouncedMediaItem != null ? 100.0 : 0.0;
                      return Padding(
                        padding: EdgeInsets.only(bottom: space),
                        child: ValueListenableBuilder<MediaItem?>(
                          valueListenable: _immediateMediaItemNotifier,
                          builder: (context, immediateMediaItem, child) {
                            return ListView.builder(
                              itemCount: songsToShow.length,
                              itemBuilder: (context, index) {
                                final song = songsToShow[index];
                                final path = song.data;
                                final isCurrent =
                                    (immediateMediaItem?.id != null &&
                                    path.isNotEmpty &&
                                    (immediateMediaItem!.id == path ||
                                        immediateMediaItem.extras?['data'] ==
                                            path));
                                final isAmoledTheme =
                                    colorSchemeNotifier.value ==
                                    AppColorScheme.amoled;

                                // Solo usar ValueListenableBuilder para la canción actual
                                if (isCurrent) {
                                  return ValueListenableBuilder<bool>(
                                    valueListenable: _isPlayingNotifier,
                                    builder: (context, playing, child) {
                                      return _buildOptimizedListTile(
                                        context,
                                        song,
                                        isCurrent,
                                        playing,
                                        isAmoledTheme,
                                      );
                                    },
                                  );
                                } else {
                                  // Para canciones que no están reproduciéndose, no usar StreamBuilder
                                  return _buildOptimizedListTile(
                                    context,
                                    song,
                                    isCurrent,
                                    false, // No playing
                                    isAmoledTheme,
                                  );
                                }
                              },
                            );
                          },
                        ),
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
}
