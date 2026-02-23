import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import '../../l10n/locale_provider.dart';
import '../../services/download_history_service.dart';
import '../../models/download_record.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../utils/theme_preferences.dart';
import '../../utils/notifiers.dart';
import '../../widgets/song_info_dialog.dart';
import 'package:audio_service/audio_service.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import '../../utils/simple_yt_download.dart';

class DownloadHistoryScreen extends StatefulWidget {
  const DownloadHistoryScreen({super.key});

  @override
  State<DownloadHistoryScreen> createState() => _DownloadHistoryScreenState();
}

class _DownloadHistoryScreenState extends State<DownloadHistoryScreen> {
  List<DownloadRecord> _downloadRecords = [];
  bool _isLoading = true;

  // Cache para IDs de canciones para evitar consultas repetidas
  final Map<String, int?> _songIdCache = {};

  // Cache de los *objetos* Future — evita que FutureBuilder reinicie
  // en ConnectionState.waiting en cada rebuild del padre (sin este cache
  // hay un flash de carátula en cada setState).
  final Map<String, Future<int?>> _songIdFutureCache = {};

  // Cache global de todas las canciones (path -> song ID)
  Map<String, int>? _allSongsPathMap;

  // Estado de descargas activas
  DownloadTask? _currentTask;
  List<DownloadTask> _queuedTasks = [];
  StreamSubscription? _downloadStateSubscription;

  @override
  void initState() {
    super.initState();
    _loadDownloadHistory(withDelay: true);
    _markAsViewed();
    _setupDownloadListener();
  }

  void _setupDownloadListener() {
    // Polling ligero para actualizar current/queue (igual que SimpleDownloadButton)
    // El progreso ya se maneja dentro de _ActiveDownloadCard con ValueListenableBuilder.
    _downloadStateSubscription =
        Stream.periodic(const Duration(milliseconds: 200)).listen((_) {
          if (!mounted) return;
          final q = DownloadQueue();
          final current = q.currentTask;
          final queued = List<DownloadTask>.from(q.queue);

          final currentChanged =
              current?.notificationId != _currentTask?.notificationId;

          if (currentChanged || queued.length != _queuedTasks.length) {
            // Recargar historial cada vez que cambia la tarea actual:
            // - cuando termina una sola descarga y pasa a la siguiente
            // - cuando termina la cola completa
            if (currentChanged && _currentTask != null) {
              _appendNewDownloads();
            }
            setState(() {
              _currentTask = current;
              _queuedTasks = queued;
            });
          }
        });
  }

  @override
  void dispose() {
    _downloadStateSubscription?.cancel();
    super.dispose();
  }

  Future<void> _markAsViewed() async {
    await DownloadHistoryService().markAllAsViewed();
    hasNewDownloadsNotifier.value = false;
  }

  /// Añade solo las canciones nuevas al inicio de la lista, sin recargar todo.
  /// Actualiza el mapa de paths para que las carátulas aparezcan correctamente.
  Future<void> _appendNewDownloads() async {
    try {
      // Obtener todos los registros de la DB
      final allRecords = await DownloadHistoryService().getCompletedDownloads();

      // Calcular cuáles NO están ya en la lista actual
      final existingIds = _downloadRecords.map((r) => r.id).toSet();
      final newRecords = allRecords
          .where((r) => !existingIds.contains(r.id))
          .toList();

      if (newRecords.isEmpty || !mounted) return;

      // Refrescar el mapa de paths del MediaStore para poder resolver carátulas
      // de las canciones recién escaneadas (re-query completo, una sola vez).
      // IMPORTANTE: solo se invalida _allSongsPathMap, NO _songIdCache,
      // porque los IDs ya conocidos siguen siendo válidos. Limpiar el caché
      // haría que todos los FutureBuilder pasaran por ConnectionState.waiting
      // y mostraran el icono de fallback un instante (flash de carátulas).
      _allSongsPathMap = null;
      await _preloadSongPaths();

      if (!mounted) return;
      setState(() {
        // Insertar los nuevos al inicio (el historial muestra el más reciente arriba)
        _downloadRecords = [...newRecords, ..._downloadRecords];
      });
    } catch (e) {
      // No hacer nada — la lista existente sigue intacta
    }
  }

  Future<void> _loadDownloadHistory({bool withDelay = false}) async {
    try {
      setState(() {
        _isLoading = true;
      });

      final startTime = DateTime.now();

      // Pre-cargar el mapa de rutas de canciones
      await _preloadSongPaths();

      final records = await DownloadHistoryService().getCompletedDownloads();

      // Al entrar por primera vez aplicar delay mínimo para evitar lag visual
      if (withDelay) {
        final elapsed = DateTime.now().difference(startTime);
        final remaining = const Duration(seconds: 1) - elapsed;
        if (remaining > Duration.zero) await Future.delayed(remaining);
      }

      if (!mounted) return;
      setState(() {
        _downloadRecords = records;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _preloadSongPaths() async {
    if (_allSongsPathMap != null) return; // Ya está cargado

    try {
      final OnAudioQuery audioQuery = OnAudioQuery();
      final songs = await audioQuery.querySongs(
        sortType: null,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );

      // Crear un mapa de ruta normalizada -> song ID
      final Map<String, int> pathMap = {};
      for (final song in songs) {
        String normalizedPath = song.data;
        if (normalizedPath.startsWith('/storage/emulated/0')) {
          normalizedPath = normalizedPath.substring(
            '/storage/emulated/0'.length,
          );
        }
        pathMap[normalizedPath] = song.id;
      }

      _allSongsPathMap = pathMap;
    } catch (e) {
      // print('Error precargando rutas de canciones: $e');
      _allSongsPathMap = {}; // Mapa vacío para evitar reintentos
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _deleteDownload(DownloadRecord record) async {
    try {
      // Eliminar archivo del sistema
      final file = File(record.filePath);
      if (await file.exists()) {
        await file.delete();

        // Notificar al MediaStore de Android que el archivo fue eliminado
        try {
          await OnAudioQuery().scanMedia(record.filePath);
        } catch (_) {}
      }

      // Eliminar de la base de datos
      await DownloadHistoryService().deleteDownload(record.id!);

      // Limpiar del cache (resultado e historia del Future)
      _songIdCache.remove(record.filePath);
      _songIdCache.remove(
        record.filePath.replaceFirst('/storage/emulated/0', ''),
      );
      _songIdFutureCache.remove(record.filePath);
      _songIdFutureCache.remove(
        record.filePath.replaceFirst('/storage/emulated/0', ''),
      );

      // Limpiar del mapa global
      if (_allSongsPathMap != null) {
        String normalizedPath = record.filePath;
        if (normalizedPath.startsWith('/storage/emulated/0')) {
          normalizedPath = normalizedPath.substring(
            '/storage/emulated/0'.length,
          );
        }
        _allSongsPathMap!.remove(normalizedPath);
      }

      // Actualizar folders_screen.dart sin cerrar la carpeta
      foldersShouldReload.value = !foldersShouldReload.value;

      // Actualizar favorites_screen.dart
      favoritesShouldReload.value = !favoritesShouldReload.value;

      // Recargar la lista
      await _loadDownloadHistory();
    } catch (e) {
      // print('Error eliminando descarga: $e');
    }
  }

  void _showOptionsModal(BuildContext context, DownloadRecord record) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => FutureBuilder<bool>(
        future: File(record.filePath).exists(),
        builder: (context, snapshot) {
          final fileExists = snapshot.data ?? true;
          final opacity = fileExists ? 1.0 : 0.4;

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Encabezado con información de la descarga
                  Container(
                    padding: const EdgeInsets.all(16),
                    child: Opacity(
                      opacity: opacity,
                      child: Row(
                        children: [
                          // Carátula de la canción o icono de basurero
                          fileExists
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 60,
                                    height: 60,
                                    child: _buildModalArtwork(record),
                                  ),
                                )
                              : Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.delete_outline,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer,
                                    size: 30,
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
                                  record.title,
                                  maxLines: 1,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  record.artist,
                                  style: TextStyle(fontSize: 14),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Opciones
                  ListTile(
                    leading: const Icon(Icons.delete),
                    title: Text(LocaleProvider.tr('delete')),
                    onTap: () {
                      Navigator.pop(context);
                      _showDeleteConfirmation(record);
                    },
                  ),

                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(LocaleProvider.tr('song_info')),
                    onTap: () {
                      Navigator.pop(context);
                      _showFileInfo(record);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDeleteConfirmation(DownloadRecord record) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
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
                Icons.delete_forever_rounded,
                size: 32,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                LocaleProvider.tr('delete_download'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              content: Text(
                '${LocaleProvider.tr('delete_download_confirm')} "${record.title}"?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              actionsPadding: const EdgeInsets.all(16),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    LocaleProvider.tr('cancel'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _deleteDownload(record);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: Text(
                    LocaleProvider.tr('delete'),
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

  void _showFileInfo(DownloadRecord record) async {
    // Crear un MediaItem temporal para usar con SongInfoDialog
    final mediaItem = MediaItem(
      id: record.filePath,
      title: record.title,
      artist: record.artist,
      album: '', // No tenemos álbum en DownloadRecord
      duration: null, // No tenemos duración en DownloadRecord
      artUri: null,
      extras: {'data': record.filePath},
    );

    await SongInfoDialog.show(context, mediaItem, colorSchemeNotifier);
  }

  Widget _buildAudioArtwork(String filePath) {
    return FutureBuilder<int?>(
      // putIfAbsent garantiza que el mismo objeto Future se reutiliza
      // en cada rebuild, evitando el flash de ConnectionState.waiting.
      future: _songIdFutureCache.putIfAbsent(
        filePath,
        () => _getSongIdFromPath(filePath),
      ),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return QueryArtworkWidget(
            id: snapshot.data!,
            type: ArtworkType.AUDIO,
            artworkBorder: BorderRadius.circular(8),
            artworkHeight: 50,
            artworkWidth: 50,
            keepOldArtwork: true,
            nullArtworkWidget: _buildFallbackIcon(),
          );
        }
        return _buildFallbackIcon();
      },
    );
  }

  Future<int?> _getSongIdFromPath(String filePath) async {
    // Verificar cache primero
    if (_songIdCache.containsKey(filePath)) {
      return _songIdCache[filePath];
    }

    // Normalizar la ruta
    String normalizedPath = filePath;
    if (normalizedPath.startsWith('/storage/emulated/0')) {
      normalizedPath = normalizedPath.substring('/storage/emulated/0'.length);
    }

    // Buscar en el mapa pre-cargado (O(1) en lugar de O(n))
    if (_allSongsPathMap != null &&
        _allSongsPathMap!.containsKey(normalizedPath)) {
      final songId = _allSongsPathMap![normalizedPath];
      _songIdCache[filePath] = songId;
      return songId;
    }

    // No se encontró
    _songIdCache[filePath] = null;
    return null;
  }

  Widget _buildFallbackIcon() {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.5)
            : Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.onSurface,
        size: 24,
      ),
    );
  }

  // Función para construir la carátula del modal
  Widget _buildModalArtwork(DownloadRecord record) {
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final normalizedPath = record.filePath.replaceFirst(
      '/storage/emulated/0',
      '',
    );
    return FutureBuilder<int?>(
      future: _songIdFutureCache.putIfAbsent(
        normalizedPath,
        () => _getSongIdFromPath(normalizedPath),
      ),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return QueryArtworkWidget(
            id: snapshot.data!,
            type: ArtworkType.AUDIO,
            artworkBorder: BorderRadius.circular(8),
            artworkHeight: 60,
            artworkWidth: 60,
            keepOldArtwork: true,
            nullArtworkWidget: Container(
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
            ),
          );
        }
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: TranslatedText(
          'download_history',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
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
      ),
      body: _isLoading
          ? Center(child: LoadingIndicator())
          : (_downloadRecords.isEmpty &&
                _currentTask == null &&
                _queuedTasks.isEmpty)
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.download_done_outlined,
                    size: 48,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('no_downloads'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 14,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            )
          : ValueListenableBuilder<AppColorScheme>(
              valueListenable: colorSchemeNotifier,
              builder: (context, colorScheme, child) {
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

                // Construir lista de tareas activas (current + queued)
                final activeTasks = <DownloadTask>[
                  ..._queuedTasks,
                  if (_currentTask != null) _currentTask!,
                ];

                return ListView.builder(
                  itemCount: activeTasks.length + _downloadRecords.length,
                  padding: EdgeInsets.only(
                    left: 16.0,
                    right: 16.0,
                    top: 8.0,
                    bottom: MediaQuery.of(context).padding.bottom + 16,
                  ),
                  itemBuilder: (context, index) {
                    // ── Descargas activas al inicio ──
                    if (index < activeTasks.length) {
                      final task = activeTasks[index];
                      final isCurrentlyDownloading =
                          _currentTask?.notificationId == task.notificationId;

                      final bool activeIsFirst = index == 0;
                      final bool activeIsLast =
                          index == activeTasks.length - 1 &&
                          _downloadRecords.isEmpty;
                      final bool activeIsOnly =
                          activeTasks.length == 1 && _downloadRecords.isEmpty;

                      BorderRadius activeBorderRadius;
                      if (activeIsOnly) {
                        activeBorderRadius = BorderRadius.circular(16);
                      } else if (activeIsFirst) {
                        activeBorderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        );
                      } else if (activeIsLast) {
                        activeBorderRadius = const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                          bottomLeft: Radius.circular(16),
                          bottomRight: Radius.circular(16),
                        );
                      } else {
                        activeBorderRadius = BorderRadius.circular(4);
                      }

                      return _ActiveDownloadCard(
                        key: ValueKey(task.notificationId),
                        task: task,
                        isCurrentlyDownloading: isCurrentlyDownloading,
                        borderRadius: activeBorderRadius,
                        cardColor: cardColor,
                        isLast: activeIsLast && _downloadRecords.isEmpty,
                      );
                    }

                    // ── Historial de descargas completadas ──
                    final recordIndex = index - activeTasks.length;
                    final record = _downloadRecords[recordIndex];
                    final fileSize = _formatFileSize(record.fileSize);

                    final bool isFirst =
                        recordIndex == 0 && activeTasks.isEmpty;
                    final bool isLast =
                        recordIndex == _downloadRecords.length - 1;
                    final bool isOnly =
                        _downloadRecords.length == 1 && activeTasks.isEmpty;
                    // Si hay tareas activas, el primer record tiene esquinas superiores redondeadas pequeñas
                    final bool hasActivesAbove =
                        activeTasks.isNotEmpty && recordIndex == 0;

                    BorderRadius borderRadius;
                    if (isOnly) {
                      borderRadius = BorderRadius.circular(16);
                    } else if (isFirst && !hasActivesAbove) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(4),
                      );
                    } else if (isLast && !hasActivesAbove && !isFirst) {
                      borderRadius = const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      );
                    } else if (isLast && (hasActivesAbove || isFirst)) {
                      // Solo el elemento si no hay previos en historial, redondear abajo
                      borderRadius = hasActivesAbove && isFirst
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(4),
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            )
                          : const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(4),
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            );
                    } else {
                      borderRadius = BorderRadius.circular(4);
                    }

                    return FutureBuilder<bool>(
                      future: File(record.filePath).exists(),
                      builder: (context, snapshot) {
                        final fileExists = snapshot.data ?? true;
                        final opacity = fileExists ? 1.0 : 0.4;

                        return Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
                          child: Card(
                            color: cardColor,
                            margin: EdgeInsets.zero,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                            ),
                            child: ClipRRect(
                              borderRadius: borderRadius,
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onLongPress: fileExists
                                      ? () => _showOptionsModal(context, record)
                                      : null,
                                  child: Opacity(
                                    opacity: opacity,
                                    child: ListTile(
                                      leading: fileExists
                                          ? ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: _buildAudioArtwork(
                                                record.filePath.replaceFirst(
                                                  '/storage/emulated/0',
                                                  '',
                                                ),
                                              ),
                                            )
                                          : Container(
                                              width: 50,
                                              height: 50,
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .secondaryContainer,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Icon(
                                                Icons.delete_outline,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSecondaryContainer,
                                                size: 24,
                                              ),
                                            ),
                                      title: Text(
                                        record.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(fileSize),
                                          const SizedBox(height: 4),
                                          Text(
                                            record.filePath.replaceFirst(
                                              '/storage/emulated/0',
                                              '',
                                            ),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.7),
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }
}

/// Tarjeta de descarga activa. Aislada en su propio widget para que los
/// rebuildeos del [progressNotifier] NO afecten al resto del ListView.
class _ActiveDownloadCard extends StatelessWidget {
  const _ActiveDownloadCard({
    super.key,
    required this.task,
    required this.isCurrentlyDownloading,
    required this.borderRadius,
    required this.cardColor,
    required this.isLast,
  });

  final DownloadTask task;
  final bool isCurrentlyDownloading;
  final BorderRadius borderRadius;
  final Color cardColor;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 4),
      child: Card(
        color: cardColor,
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: SizedBox(
                  width: 50,
                  height: 50,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      Icon(
                        isCurrentlyDownloading
                            ? Icons.downloading
                            : Icons.queue_music,
                        color: Theme.of(context).colorScheme.primary,
                        size: 24,
                      ),
                    ],
                  ),
                ),
                title: Text(
                  task.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  isCurrentlyDownloading
                      ? LocaleProvider.tr('downloading')
                      : LocaleProvider.tr('in_queue'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 12,
                  ),
                ),
                // Trailing: porcentaje, solo cuando se está descargando
                trailing: isCurrentlyDownloading
                    ? ValueListenableBuilder<Map<int, double>>(
                        valueListenable: DownloadQueue().progressNotifier,
                        builder: (context, progressMap, _) {
                          final p = progressMap[task.notificationId] ?? 0.0;
                          if (p <= 0) return const SizedBox.shrink();
                          return Text(
                            '${(p * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          );
                        },
                      )
                    : null,
              ),
              // Progress bar — solo se reconstruye este widget, no el ListView
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: isCurrentlyDownloading
                      ? ValueListenableBuilder<Map<int, double>>(
                          valueListenable: DownloadQueue().progressNotifier,
                          builder: (context, progressMap, _) {
                            final p = progressMap[task.notificationId] ?? 0.0;
                            return LinearProgressIndicator(
                              value: p > 0 ? p : null,
                              minHeight: 4,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.15),
                              color: Theme.of(context).colorScheme.primary,
                            );
                          },
                        )
                      : LinearProgressIndicator(
                          value: null, // indeterminado para los de la cola
                          minHeight: 4,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.4),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
