import 'package:flutter/material.dart';
import 'dart:io';
import '../../l10n/locale_provider.dart';
import '../../services/download_history_service.dart';
import '../../models/download_record.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../utils/theme_preferences.dart';
import '../../utils/notifiers.dart';
import '../../widgets/song_info_dialog.dart';
import 'package:audio_service/audio_service.dart';
import 'package:media_scanner/media_scanner.dart';

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
  
  // Cache global de todas las canciones (path -> song ID)
  Map<String, int>? _allSongsPathMap;

  @override
  void initState() {
    super.initState();
    _loadDownloadHistory();
    _markAsViewed();
  }

  Future<void> _markAsViewed() async {
    await DownloadHistoryService().markAllAsViewed();
    hasNewDownloadsNotifier.value = false;
  }

  Future<void> _loadDownloadHistory() async {
    try {
      setState(() {
        _isLoading = true;
      });
      
      // Iniciar timer para delay mínimo
      final startTime = DateTime.now();
      
      // Pre-cargar el mapa de rutas de canciones UNA SOLA VEZ
      await _preloadSongPaths();
      
      final records = await DownloadHistoryService().getCompletedDownloads();
      
      // Calcular tiempo transcurrido
      final elapsed = DateTime.now().difference(startTime);
      final remainingDelay = const Duration(seconds: 1) - elapsed;
      
      // Si no han pasado 2 segundos, esperar el tiempo restante
      if (remainingDelay > Duration.zero) {
        await Future.delayed(remainingDelay);
      }
      
      setState(() {
        _downloadRecords = records;
        _isLoading = false;
      });
    } catch (e) {
      // En caso de error, esperar al menos 1 segundo antes de mostrar el mensaje
      await Future.delayed(const Duration(seconds: 1));
      setState(() {
        _isLoading = false;
      });
      // print('Error cargando historial: $e');
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
          normalizedPath = normalizedPath.substring('/storage/emulated/0'.length);
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
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
          await MediaScanner.loadMedia(path: record.filePath);
        } catch (_) {}
      }
      
      // Eliminar de la base de datos
      await DownloadHistoryService().deleteDownload(record.id!);
      
      // Limpiar del cache
      _songIdCache.remove(record.filePath);
      _songIdCache.remove(record.filePath.replaceFirst('/storage/emulated/0', ''));
      
      // Limpiar del mapa global
      if (_allSongsPathMap != null) {
        String normalizedPath = record.filePath;
        if (normalizedPath.startsWith('/storage/emulated/0')) {
          normalizedPath = normalizedPath.substring('/storage/emulated/0'.length);
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
                                    color: Theme.of(context).colorScheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.delete_outline,
                                    color: Theme.of(context).colorScheme.onSecondaryContainer,
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
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: Text(
                  LocaleProvider.tr('delete_download'),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          '${LocaleProvider.tr('delete_download_confirm')} "${record.title}"?',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de confirmar borrado
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _deleteDownload(record);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.red.withValues(alpha: 0.2) // Color personalizado para amoled
                              : Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.red.withValues(alpha: 0.4) // Borde personalizado para amoled
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
                              child: Icon(
                                Icons.delete_forever,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.red // Ícono rojo para amoled
                                    : Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('delete'),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isAmoled && isDark
                                      ? Colors.red // Texto rojo para amoled
                                      : Theme.of(context).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de cancelar
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
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
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
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
                              child: Icon(
                                Icons.cancel_outlined,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white // Ícono blanco para amoled
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                LocaleProvider.tr('cancel'),
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

  void _showFileInfo(DownloadRecord record) async {
    // Crear un MediaItem temporal para usar con SongInfoDialog
    final mediaItem = MediaItem(
      id: record.filePath,
      title: record.title,
      artist: record.artist,
      album: '', // No tenemos álbum en DownloadRecord
      duration: null, // No tenemos duración en DownloadRecord
      artUri: null,
      extras: {
        'data': record.filePath,
      },
    );
    
    await SongInfoDialog.show(context, mediaItem, colorSchemeNotifier);
  }

  Widget _buildAudioArtwork(String filePath) {
    return FutureBuilder<int?>(
      future: _getSongIdFromPath(filePath),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return QueryArtworkWidget(
            id: snapshot.data!,
            type: ArtworkType.AUDIO,
            artworkBorder: BorderRadius.circular(8),
            artworkHeight: 48,
            artworkWidth: 48,
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
    if (_allSongsPathMap != null && _allSongsPathMap!.containsKey(normalizedPath)) {
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
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: isSystem
            ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5)
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
    return FutureBuilder<int?>(
      future: _getSongIdFromPath(record.filePath.replaceFirst('/storage/emulated/0', '')),
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
                color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
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
            color: isSystem ? Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5) : Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.music_note, size: 30),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(LocaleProvider.tr('download_history')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            ),
            padding: const EdgeInsets.all(8),
            child: const Icon(Icons.arrow_back),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : _downloadRecords.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.download_done_outlined,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        LocaleProvider.tr('no_downloads'),
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _downloadRecords.length,
                  padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
                  itemBuilder: (context, index) {
                    final record = _downloadRecords[index];
                    final fileSize = _formatFileSize(record.fileSize);
                    
                    return FutureBuilder<bool>(
                      future: File(record.filePath).exists(),
                      builder: (context, snapshot) {
                        final fileExists = snapshot.data ?? true;
                        final opacity = fileExists ? 1.0 : 0.4;
                        
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onLongPress: fileExists ? () => _showOptionsModal(context, record) : null,
                            child: Opacity(
                              opacity: opacity,
                              child: ListTile(
                                leading: fileExists
                                    ? ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: _buildAudioArtwork(record.filePath.replaceFirst('/storage/emulated/0', '')),
                                      )
                                    : Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.secondaryContainer,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          Icons.delete_outline,
                                          color: Theme.of(context).colorScheme.onSecondaryContainer,
                                          size: 24,
                                        ),
                                      ),
                                title: Text(
                                  record.title,
                                  style: const TextStyle(fontWeight: FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(fileSize),
                                    const SizedBox(height: 4),
                                    Text(
                                      record.filePath.replaceFirst('/storage/emulated/0', ''),
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
    );
  }
}