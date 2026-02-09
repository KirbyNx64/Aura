import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:music/utils/audio/synced_lyrics_service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_loading_indicator/loading_indicator.dart';

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
      builder: (context) {
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
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.lyrics_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              title: TranslatedText(
                'select_lyrics',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 16,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withAlpha(200),
                        height: 1.5,
                      ),
                      children: [
                        TextSpan(
                          text: '${LocaleProvider.tr('confirm_apply_lyrics')} ',
                        ),
                        TextSpan(
                          text: '"${widget.currentSong.title}"',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const TextSpan(text: '?'),
                      ],
                    ),
                  ),
                ],
              ),
              actionsPadding: EdgeInsets.only(right: 16, bottom: 16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: TranslatedText(
                    'cancel',
                    style: TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: TranslatedText(
                    'apply',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
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
              contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              icon: Icon(
                Icons.task_alt_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              title: Text(
                title,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              content: Text(
                description,
                style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              actionsPadding: EdgeInsets.all(16),
              actions: [
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).pop(),
                  child: TranslatedText(
                    'ok',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showInfoDialog() async {
    await showDialog(
      context: context,
      builder: (context) {
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
                    Icon(
                      Icons.info_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    TranslatedText(
                      'info',
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
                        'lyrics_search_info',
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
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: TranslatedText(
                            'ok',
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TranslatedText(
          'search_lyrics_title',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
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
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      onChanged: (value) {
                        if (mounted) {
                          setState(() {});
                        }
                      },
                      onSubmitted: (_) => _performSearch(),
                      cursorColor: Theme.of(context).colorScheme.primary,
                      decoration: InputDecoration(
                        hintText: LocaleProvider.tr('search_lyrics_hint'),
                        hintStyle: TextStyle(
                          color: isAmoled
                              ? Colors.white.withAlpha(160)
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 15,
                        ),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
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
              Icons.search_rounded,
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [LoadingIndicator()],
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
    final colorScheme = colorSchemeNotifier.value;
    final isAmoled = colorScheme == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    final isExpanded = _expandedCards.contains(index);
    final fullLyrics = _getFullLyrics(result.syncedLyrics);
    final previewLyrics = _getLyricsPreview(result.syncedLyrics);

    final cardColor = isAmoled && isDark
        ? Colors.white.withAlpha(20)
        : isDark
        ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.05)
        : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

    return Card(
      elevation: 0,
      color: cardColor,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide.none,
      ),
      child: InkWell(
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
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: isAmoled
                          ? Colors.white
                          : Theme.of(
                              context,
                            ).colorScheme.primaryContainer.withAlpha(100),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.lyrics_rounded,
                        color: isAmoled ? Colors.black : primaryColor,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          result.artist,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    // Botón de acción más prominente
                    onPressed: () => _selectLyrics(result),
                    icon: Icon(
                      Icons.download_rounded,
                      color: isAmoled
                          ? Colors.black
                          : isDark
                          ? null
                          : primaryColor,
                    ),
                    style: IconButton.styleFrom(
                      padding: const EdgeInsets.all(12),
                      backgroundColor: isAmoled ? Colors.white : null,
                    ),
                    tooltip: LocaleProvider.tr('apply'),
                  ),
                ],
              ),
              if (fullLyrics.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isAmoled
                        ? Colors.black.withAlpha(100)
                        : Theme.of(context).colorScheme.surface.withAlpha(150),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.text_snippet_rounded,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            LocaleProvider.tr('preview'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 20,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      isExpanded
                          ? _buildFullLyricsDisplay(fullLyrics)
                          : _buildPreviewLyricsDisplay(previewLyrics),
                    ],
                  ),
                ),
              ],
            ],
          ),
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
