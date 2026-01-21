import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_symbols_icons/symbols.dart';

class LyricsSearchResult {
  final String title;
  final String artist;
  final String syncedLyrics;
  final String? plainLyrics;
  final int duration;

  LyricsSearchResult({
    required this.title,
    required this.artist,
    required this.syncedLyrics,
    this.plainLyrics,
    required this.duration,
  });
}

class LyricsSearchScreen extends StatefulWidget {
  final MediaItem currentSong;

  const LyricsSearchScreen({super.key, required this.currentSong});

  @override
  State<LyricsSearchScreen> createState() => _LyricsSearchScreenState();
}

class _LyricsSearchScreenState extends State<LyricsSearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<LyricsSearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  final Set<int> _expandedCards = <int>{};
  double _lastViewInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Establecer texto inicial basado en la canción actual
    _searchController.text =
        '${widget.currentSong.artist ?? ''} ${widget.currentSong.title}'.trim();

    // Realizar búsqueda inicial automáticamente
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _performSearch();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    if (_lastViewInset > 0 && viewInsets == 0) {
      // El teclado se ocultó
      _searchFocusNode.unfocus();
    }
    _lastViewInset = viewInsets;
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    // Quitar el foco del TextField
    _searchFocusNode.unfocus();

    if (mounted) {
      setState(() {
        _isSearching = true;
        _hasSearched = true;
      });
    }

    try {
      final dio = Dio();
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 10);

      final response = await dio.get(
        'https://lrclib.net/api/search',
        queryParameters: {'q': query},
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final List<dynamic> data = response.data;
        final results = <LyricsSearchResult>[];

        for (final item in data) {
          if (item is Map<String, dynamic>) {
            final title = item['trackName']?.toString() ?? '';
            final artist = item['artistName']?.toString() ?? '';
            final syncedLyrics = item['syncedLyrics']?.toString() ?? '';
            final plainLyrics = item['plainLyrics']?.toString();
            final duration = item['duration'] is int ? item['duration'] : 0;

            if (title.isNotEmpty &&
                artist.isNotEmpty &&
                syncedLyrics.isNotEmpty) {
              results.add(
                LyricsSearchResult(
                  title: title,
                  artist: artist,
                  syncedLyrics: syncedLyrics,
                  plainLyrics: plainLyrics,
                  duration: duration,
                ),
              );
            }
          }
        }

        if (mounted) {
          setState(() {
            _searchResults = results;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _searchResults = [];
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searchResults = [];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _selectLyrics(LyricsSearchResult result) async {
    // Mostrar diálogo de confirmación
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
              child: Text(
                LocaleProvider.tr('select_lyrics'),
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            content: RichText(
              text: TextSpan(
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 18,
                ),
                children: [
                  TextSpan(
                    text: '${LocaleProvider.tr('confirm_apply_lyrics')} "',
                  ),
                  TextSpan(
                    text: widget.currentSong.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: '"?'),
                ],
              ),
            ),
            actions: [
              SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 20),
                    // Botón de seleccionar letra (AMOLED-aware)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(true),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.4)
                                : Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: isAmoled && isDark
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : Theme.of(context).colorScheme.primary
                                          .withValues(alpha: 0.1),
                              ),
                              child: Icon(
                                Symbols.check_rounded,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('apply'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Botón de cancelar (AMOLED-aware)
                    InkWell(
                      onTap: () => Navigator.of(context).pop(false),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(
                                    context,
                                  ).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.transparent,
                              ),
                              child: Icon(
                                Icons.cancel,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('cancel'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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

    if (confirmed == true) {
      // Aplicar la letra después de la confirmación
      await _applyLyrics(result);
    }
  }

  Future<void> _applyLyrics(LyricsSearchResult result) async {
    try {
      final lyricsBox = await SyncedLyricsService.box;

      final lyricsData = LyricsData(
        id: widget.currentSong.id,
        synced: result.syncedLyrics,
        plainLyrics: result.plainLyrics,
      );

      await lyricsBox.put(widget.currentSong.id, lyricsData);

      if (mounted) {
        // Notificar que se actualizó la letra usando el ValueNotifier global
        lyricsUpdatedNotifier.value = widget.currentSong.id;

        // Mostrar mensaje de éxito y esperar a que el usuario presione "Aceptar"
        await _showMessage(
          title: LocaleProvider.tr('success'),
          description: LocaleProvider.tr('lyrics_selected_desc'),
        );

        // Cerrar la pantalla
        if (mounted) {
          Navigator.of(context).pop(false);
        }
      }
    } catch (e) {
      if (mounted) {
        await _showMessage(
          title: LocaleProvider.tr('Error'),
          description: 'Error al guardar la letra: ${e.toString()}',
        );
      }
    }
  }

  Future<void> _showMessage({
    required String title,
    required String description,
  }) async {
    await showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
              child: Text(
                title,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
            content: Text(description, style: TextStyle(fontSize: 16)),
            actions: [
              SizedBox(
                width: 400,
                child: InkWell(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isAmoled && isDark
                          ? Colors.white.withValues(alpha: 0.2)
                          : Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isAmoled && isDark
                            ? Colors.white.withValues(alpha: 0.4)
                            : Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                          ),
                          child: Icon(
                            Symbols.check_rounded,
                            size: 30,
                            color: isAmoled && isDark
                                ? Colors.white
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                LocaleProvider.tr('ok'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showInfoDialog() async {
    await showDialog(
      context: context,
      builder: (context) => ValueListenableBuilder<AppColorScheme>(
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
              child: Text(
                LocaleProvider.tr('info'),
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            content: Text(LocaleProvider.tr('lyrics_search_info')),
            actions: [
              SizedBox(height: 16),
              InkWell(
                onTap: () => Navigator.of(context).pop(),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isAmoled && isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isAmoled && isDark
                          ? Colors.white.withValues(alpha: 0.4)
                          : Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.3),
                      width: 2,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.1),
                        ),
                        child: Icon(
                          Icons.check_circle,
                          size: 30,
                          color: isAmoled && isDark
                              ? Colors.white
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              LocaleProvider.tr('ok'),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(LocaleProvider.tr('search_lyrics_title')),
        leading: IconButton(
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
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.08),
            ),
            child: const Icon(Icons.arrow_back, size: 24),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.info_outline, size: 28),
            onPressed: () => _showInfoDialog(),
          ),
        ],
      ),
      body: ValueListenableBuilder<AppColorScheme>(
        valueListenable: colorSchemeNotifier,
        builder: (context, colorScheme, child) {
          final isAmoled = colorScheme == AppColorScheme.amoled;
          final isDark = Theme.of(context).brightness == Brightness.dark;

          return Column(
            children: [
              // Barra de búsqueda con botón
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    // TextField
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: InputDecoration(
                          hintText: LocaleProvider.tr('search_lyrics_hint'),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Symbols.clear_rounded),
                                  onPressed: () {
                                    _searchController.clear();
                                    if (mounted) {
                                      setState(() {
                                        _searchResults = [];
                                        _hasSearched = false;
                                      });
                                    }
                                  },
                                )
                              : null,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onSubmitted: (_) => _performSearch(),
                        onChanged: (value) {
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Botón de búsqueda
                    SizedBox(
                      height: 56,
                      width: 56,
                      child: Material(
                        borderRadius: BorderRadius.circular(8),
                        color: colorScheme == AppColorScheme.amoled
                            ? Colors.white
                            : Theme.of(context).brightness == Brightness.light
                            ? Theme.of(context).colorScheme.primary
                            : colorScheme == AppColorScheme.system
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.primaryContainer,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _isSearching ? null : _performSearch,
                          child: Tooltip(
                            message: LocaleProvider.tr('search_lyrics'),
                            child: Icon(
                              Icons.search,
                              color: colorScheme == AppColorScheme.amoled
                                  ? Colors.black
                                  : Theme.of(context).brightness ==
                                        Brightness.light
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : colorScheme == AppColorScheme.system
                                  ? Theme.of(context).colorScheme.onPrimary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Resultados
              Expanded(child: _buildResults(isAmoled, isDark)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildResults(bool isAmoled, bool isDark) {
    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.search_rounded,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              LocaleProvider.tr('enter_search_term'),
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (_isSearching) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [CircularProgressIndicator()],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              LocaleProvider.tr('no_lyrics_found'),
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            children: [
              Text(
                LocaleProvider.tr('search_results'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(${_searchResults.length})',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              bottom: MediaQuery.of(context).padding.bottom + 16.0,
            ),
            itemCount: _searchResults.length,
            itemBuilder: (context, index) {
              final result = _searchResults[index];
              return _buildResultCard(result, index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(LyricsSearchResult result, int index) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final isExpanded = _expandedCards.contains(index);
    final fullLyrics = _getFullLyrics(result.syncedLyrics);
    final previewLyrics = _getLyricsPreview(result.syncedLyrics);

    return Card(
      shadowColor: Colors.transparent,
      color: isSystem && isDark
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: 0.3)
          : isSystem && isLight
          ? Theme.of(
              context,
            ).colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isAmoled && isDark
            ? const BorderSide(color: Colors.white, width: 1)
            : BorderSide.none,
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        result.artist,
                        style: TextStyle(fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Botón de aplicar mejorado
                Tooltip(
                  message: LocaleProvider.tr('apply'),
                  child: ElevatedButton(
                    onPressed: () => _selectLyrics(result),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isAmoled && isDark
                          ? Colors.white
                          : Theme.of(context).colorScheme.onPrimaryContainer,
                      foregroundColor: isAmoled && isDark
                          ? Colors.black
                          : Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.all(16),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Icon(Symbols.check_rounded, size: 28),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Mostrar preview de la letra con botón de expandir
            if (fullLyrics.length > previewLyrics.length)
              InkWell(
                onTap: () {
                  if (mounted) {
                    setState(() {
                      if (isExpanded) {
                        _expandedCards.remove(index);
                      } else {
                        _expandedCards.add(index);
                      }
                    });
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isSystem
                        ? Theme.of(context).colorScheme.secondaryContainer
                              .withValues(alpha: 0.5)
                        : Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: isAmoled && isDark
                        ? Border.all(color: Colors.white, width: 1)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            LocaleProvider.tr('preview'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                          const Spacer(),
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                            ),
                            child: Icon(
                              isExpanded
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      isExpanded
                          ? _buildFullLyricsDisplay(fullLyrics)
                          : _buildPreviewLyricsDisplay(previewLyrics),
                    ],
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: isAmoled && isDark
                      ? Border.all(color: Colors.white, width: 1.5)
                      : null,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleProvider.tr('preview'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildPreviewLyricsDisplay(previewLyrics),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _getLyricsPreview(String syncedLyrics) {
    // Extraer el texto de la letra sin los timestamps
    final lines = syncedLyrics.split('\n');
    final textLines = <String>[];

    for (final line in lines) {
      final regExp = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\](.*)');
      final match = regExp.firstMatch(line);
      if (match != null && match.group(4) != null) {
        final text = match.group(4)!.trim();
        if (text.isNotEmpty) {
          textLines.add(text);
        }
      }
    }

    return textLines.take(3).join('\n');
  }

  String _getFullLyrics(String syncedLyrics) {
    // Extraer el texto completo de la letra sin los timestamps
    final lines = syncedLyrics.split('\n');
    final textLines = <String>[];

    for (final line in lines) {
      final regExp = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\](.*)');
      final match = regExp.firstMatch(line);
      if (match != null && match.group(4) != null) {
        final text = match.group(4)!.trim();
        if (text.isNotEmpty) {
          textLines.add(text);
        }
      }
    }

    return textLines.join('\n');
  }

  Widget _buildPreviewLyricsDisplay(String previewLyrics) {
    final lines = previewLyrics.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines
          .map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildFullLyricsDisplay(String fullLyrics) {
    final lines = fullLyrics.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines
          .map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
