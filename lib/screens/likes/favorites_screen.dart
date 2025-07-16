import 'package:flutter/material.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:music/main.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/theme_preferences.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _loadFavorites(initial: true);

    _searchFocusNode.addListener(() {
      setState(() {});
    });
    favoritesShouldReload.addListener(() {
      _loadFavorites();
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
  }

  Future<void> _playSong(SongModel song) async {
    const int maxQueueSongs = 200;
    final index = _favorites.indexWhere((s) => s.data == song.data);

    if (index != -1) {
      int before = (maxQueueSongs / 2).floor();
      int after = maxQueueSongs - before;
      int start = (index - before).clamp(0, _favorites.length);
      int end = (index + after).clamp(0, _favorites.length);
      List<SongModel> limitedQueue = _favorites.sublist(start, end);
      int newIndex = index - start;

      await (audioHandler as MyAudioHandler).setQueueFromSongs(
        limitedQueue,
        initialIndex: newIndex,
      );
      await audioHandler.play();
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border, size: 28),
            const SizedBox(width: 8),
            TranslatedText('favorites'),
          ],
        ),
        actions: [
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
                _playSong(random);
              }
            },
          ),
          PopupMenuButton<OrdenFavoritos>(
            icon: const Icon(Icons.sort, size: 28),
            onSelected: (orden) {
              setState(() {
                _orden = orden;
                _ordenarFavoritos();
              });
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
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 16),
                          TranslatedText('no_songs', style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                        ],
                      ),
                    );
                  }
                  return StreamBuilder<MediaItem?>(
                    stream: audioHandler.mediaItem,
                    builder: (context, currentSnapshot) {
                      final current = currentSnapshot.data;
                      return StreamBuilder<bool>(
                        stream: audioHandler.playbackState
                            .map((s) => s.playing)
                            .distinct(),
                        initialData: false,
                        builder: (context, playingSnapshot) {
                          final playing = playingSnapshot.data ?? false;
                          final space = current != null ? 100.0 : 0.0;
                          return Padding(
                            padding: EdgeInsets.only(bottom: space),
                            child: ListView.builder(
                              itemCount: songsToShow.length,
                              itemBuilder: (context, index) {
                                final song = songsToShow[index];
                                final isCurrent =
                                    current?.extras?['data'] == song.data;
                                final isAmoledTheme = colorSchemeNotifier.value == AppColorScheme.amoled;
                                return ListTile(
                                  onLongPress: () async {
                                    showModalBottomSheet(
                                      context: context,
                                      builder: (context) => SafeArea(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            ListTile(
                                              leading: const Icon(
                                                Icons.delete_outline,
                                              ),
                                              title: TranslatedText(
                                                'remove_from_favorites',
                                              ),
                                              onTap: () async {
                                                Navigator.of(context).pop();
                                                await _removeFromFavorites(
                                                  song,
                                                );
                                                favoritesShouldReload.value =
                                                    !favoritesShouldReload
                                                        .value;
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
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
                                    style: isCurrent
                                        ? TextStyle(
                                            color: isAmoledTheme
                                                ? Colors.white
                                                : Theme.of(context).colorScheme.primary,
                                            fontWeight: FontWeight.bold,
                                          )
                                        : null,
                                  ),
                                  subtitle: Text(
                                    (song.artist == null ||
                                            song.artist!.trim().isEmpty)
                                        ? LocaleProvider.tr('unknown_artist')
                                        : song.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(
                                      isCurrent && playing
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                    onPressed: () {
                                      if (isCurrent) {
                                        playing
                                            ? audioHandler.pause()
                                            : audioHandler.play();
                                      } else {
                                        _playSong(song);
                                      }
                                    },
                                  ),
                                  selected: isCurrent,
                                  selectedTileColor: isAmoledTheme
                                      ? Colors.white.withValues(alpha: 0.1)
                                      : Theme.of(context).colorScheme.primaryContainer,
                                  onTap: () => _playSong(song),
                                );
                              },
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
}
