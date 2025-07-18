import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music/utils/download_manager.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// Clase para manejar la cola de descargas
class DownloadQueue {
  static final DownloadQueue _instance = DownloadQueue._internal();
  factory DownloadQueue() => _instance;
  DownloadQueue._internal();

  final List<DownloadTask> _queue = [];
  bool _isProcessing = false;
  DownloadTask? _currentTask;
  bool _isFirstDownload = true;
  
  // Callbacks globales para actualizar la UI
  Function(double progress)? _onProgressCallback;
  Function(bool isDownloading, bool isProcessing)? _onStateChangeCallback;
  Function(String title, String message)? _onSuccessCallback;
  Function(String title, String message)? _onErrorCallback;
  Function(String title, String artist)? _onDownloadStartCallback;
  Function(String title, String artist)? _onDownloadAddedToQueueCallback;

  void setCallbacks({
    Function(double progress)? onProgress,
    Function(bool isDownloading, bool isProcessing)? onStateChange,
    Function(String title, String message)? onSuccess,
    Function(String title, String message)? onError,
    Function(String title, String artist)? onDownloadStart,
    Function(String title, String artist)? onDownloadAddedToQueue,
  }) {
    _onProgressCallback = onProgress;
    _onStateChangeCallback = onStateChange;
    _onSuccessCallback = onSuccess;
    _onErrorCallback = onError;
    _onDownloadStartCallback = onDownloadStart;
    _onDownloadAddedToQueueCallback = onDownloadAddedToQueue;
  }

  // Agregar una descarga a la cola
  Future<void> addToQueue({
    required BuildContext context,
    required String videoId,
    required String title,
    required String artist,
  }) async {
    final task = DownloadTask(
      context: context,
      videoId: videoId,
      title: title,
      artist: artist,
    );
    
    _queue.add(task);
    
    // Si no hay ninguna descarga en proceso, mostrar el título inmediatamente e iniciar el procesamiento
    if (!_isProcessing) {
      _onDownloadStartCallback?.call(task.title, task.artist);
      _processQueue();
    } else {
      // Si ya hay una descarga en proceso, notificar que se agregó a la cola
      _onDownloadAddedToQueueCallback?.call(task.title, task.artist);
    }
  }

  // Procesar la cola de descargas
  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    
    _isProcessing = true;
    
    while (_queue.isNotEmpty) {
      _isFirstDownload = false;
      final task = _queue.removeAt(0);
      _currentTask = task;
      
      try {
        // Para descargas adicionales (no la primera), notificar el inicio
        if (!_isFirstDownload) {
          _onDownloadStartCallback?.call(task.title, task.artist);
        }
        
        // Iniciar la descarga
        await _downloadTask(task);
        
        // Pequeña pausa entre descargas
        await Future.delayed(const Duration(milliseconds: 500));
        
      } catch (e) {
        // Manejar errores individuales sin detener la cola
        _onErrorCallback?.call(task.title, 'Error: $e');
      } finally {
        _currentTask = null;
      }
    }
    
    // Cuando la cola está vacía, notificar que no hay más descargas
    if (_queue.isEmpty) {
      _onStateChangeCallback?.call(false, false);
      _isFirstDownload = true; // Resetear para la próxima descarga
    }
    
    _isProcessing = false;
  }

  // Descargar una tarea específica
  Future<void> _downloadTask(DownloadTask task) async {
    final videoUrl = 'https://www.youtube.com/watch?v=${task.videoId}';
    final downloadManager = DownloadManager();
    await downloadManager.initialize();
    
    downloadManager.setCallbacks(
      onInfoUpdate: (title, artist, coverBytes) {
        // print('Descargando: $title - $artist');
      },
      onProgressUpdate: (progress) {
        // print('Progreso: ${(progress * 100).toStringAsFixed(1)}%');
        _onProgressCallback?.call(progress);
      },
      onStateUpdate: (isDownloading, isProcessing) {
        // print('Estado: Descargando=$isDownloading, Procesando=$isProcessing');
        _onStateChangeCallback?.call(isDownloading, isProcessing);
      },
      onError: (title, message) {
        _showDialogSafely(task.context, title, message);
        _onErrorCallback?.call(title, message);
      },
      onSuccess: (title, message) {
        _showDialogSafely(task.context, title, message);
        _onSuccessCallback?.call(title, message);
      },
    );
    
    await downloadManager.downloadAudio(url: videoUrl);
  }

  // Método seguro para mostrar diálogo verificando si el contexto sigue válido
  void _showDialogSafely(BuildContext context, String title, String message) {
    // Verificar si el contexto sigue montado antes de mostrar el diálogo
    if (context.mounted) {
      // No mostrar nada si es mensaje de descarga completada
      if (message == LocaleProvider.tr('download_completed_desc')) {
        return;
      } else {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('ok')),
              ),
            ],
          ),
        );
      }
    } else {
      // Si el contexto no está disponible, mostrar en consola
      //print('$title: $message');
      // También mostrar un snackbar si es posible usando el contexto global
      _showSnackbarGlobal(title, message);
    }
  }
  
  // Método para mostrar snackbar global
  void _showSnackbarGlobal(String title, String message) {
    // Usar un enfoque más simple: mostrar en consola y usar un callback global si está disponible
    // print('Descarga completada: $title - $message');
    // Aquí podrías implementar un sistema de notificaciones globales si es necesario
  }

  // Obtener el estado actual de la cola
  bool get isProcessing => _isProcessing;
  int get queueLength => _queue.length;
  List<DownloadTask> get queue => List.unmodifiable(_queue);
  DownloadTask? get currentTask => _currentTask;
  
  // Obtener el número total de descargas (actual + en cola)
  int get totalDownloads => (_currentTask != null ? 1 : 0) + _queue.length;
}

// Clase para representar una tarea de descarga
class DownloadTask {
  final BuildContext context;
  final String videoId;
  final String title;
  final String artist;

  DownloadTask({
    required this.context,
    required this.videoId,
    required this.title,
    required this.artist,
  });
}

// Clase simple para manejar descargas en YouTube
class SimpleYtDownload {
  
  // Método para descargar un video con callbacks de progreso
  static Future<void> downloadVideo(
    BuildContext context,
    String videoId,
    String title,
  ) async {
    // Agregar la descarga a la cola (los callbacks ya están configurados globalmente)
    final downloadQueue = DownloadQueue();
    await downloadQueue.addToQueue(
      context: context,
      videoId: videoId,
      title: title,
      artist: title, // Usar el título como artista por defecto
    );
  }
  
  // Método para descargar un video con artista específico
  static Future<void> downloadVideoWithArtist(
    BuildContext context,
    String videoId,
    String title,
    String artist,
  ) async {
    // Agregar la descarga a la cola (los callbacks ya están configurados globalmente)
    final downloadQueue = DownloadQueue();
    await downloadQueue.addToQueue(
      context: context,
      videoId: videoId,
      title: title,
      artist: artist,
    );
  }
}

// Widget simple para botón de descarga
class SimpleDownloadButton extends StatelessWidget {
  final YtMusicResult item;
  
  const SimpleDownloadButton({
    super.key,
    required this.item,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      width: 50,
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: item.videoId != null
              ? () async {
                  // Navigator.pop(context); // Ya no cerramos el modal al descargar
                  // Usar un pequeño delay para asegurar que el modal se cierre antes de iniciar la descarga
                  await Future.delayed(const Duration(milliseconds: 100));
                  // Verificar conexión a internet antes de descargar
                  final List<ConnectivityResult> connectivityResult = await Connectivity().checkConnectivity();
                  if (connectivityResult.contains(ConnectivityResult.none)) {
                    if (context.mounted) {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: TranslatedText('error'),
                          content: TranslatedText('no_internet_connection'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: TranslatedText('ok'),
                            ),
                          ],
                        ),
                      );
                    }
                    return;
                  }
                  if (context.mounted) {
                    SimpleYtDownload.downloadVideoWithArtist(
                      context,
                      item.videoId!,
                      item.title ?? '',
                      item.artist ?? '',
                    );
                  }
                }
              : null,
          child: Tooltip(
            message: LocaleProvider.tr('download_audio'),
            child: Icon(
              Icons.download,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

// Ejemplo de cómo usar en el modal existente
class ModalExample {
  static Widget buildModalContent(BuildContext context, YtMusicResult item) {
    final url = item.videoId != null
        ? 'https://music.youtube.com/watch?v=${item.videoId}'
        : null;
        
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: item.thumbUrl != null
                      ? Image.network(
                          item.thumbUrl!,
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          width: 64,
                          height: 64,
                          color: Colors.grey[300],
                          child: const Icon(
                            Icons.music_note,
                            size: 32,
                            color: Colors.grey,
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                // Información
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title ?? LocaleProvider.tr('title_unknown'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.artist ?? LocaleProvider.tr('artist_unknown'),
                        style: TextStyle(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Botón de descarga
                SimpleDownloadButton(item: item),
                const SizedBox(width: 8),
                // Botón de copiar enlace
                SizedBox(
                  height: 50,
                  width: 50,
                  child: Material(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: url != null
                          ? () {
                              Clipboard.setData(ClipboardData(text: url));
                              Navigator.pop(context);
                            }
                          : null,
                      child: Tooltip(
                        message: LocaleProvider.tr('copy_link'),
                        child: Icon(
                          Icons.link,
                          color: Theme.of(context).colorScheme.onSecondaryContainer,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
} 