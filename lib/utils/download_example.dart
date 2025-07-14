import 'package:flutter/material.dart';
import 'package:music/utils/download_manager.dart';
import 'package:music/l10n/locale_provider.dart';

// Ejemplo de cómo usar el DownloadManager en cualquier pantalla
class DownloadExample {
  
  // Método simple para descargar un video de YouTube
  static Future<void> downloadYouTubeVideo(
    BuildContext context,
    String videoUrl, {
    String? customDirectory,
    bool? useExplode,
    bool? useFFmpeg,
  }) async {
    final downloadManager = DownloadManager();
    await downloadManager.initialize();
    
    // Configurar callbacks para manejar eventos
    downloadManager.setCallbacks(
      onInfoUpdate: (title, artist, coverBytes) {
        // Se llama cuando se obtiene la información del video
        //print('Descargando: $title - $artist');
      },
      onProgressUpdate: (progress) {
        // Se llama para actualizar el progreso (0.0 a 1.0)
        // print('Progreso: ${(progress * 100).toStringAsFixed(1)}%');
      },
      onStateUpdate: (isDownloading, isProcessing) {
        // Se llama cuando cambia el estado de descarga/procesamiento
        // print('Estado: Descargando=$isDownloading, Procesando=$isProcessing');
      },
      onError: (title, message) {
        // Se llama cuando ocurre un error
        _showDialog(context, title, message);
      },
      onSuccess: (title, message) {
        // Se llama cuando la descarga se completa exitosamente
        _showDialog(context, title, message);
      },
    );
    
    // Iniciar la descarga
    await downloadManager.downloadAudio(
      url: videoUrl,
      directoryPath: customDirectory,
      usarExplode: useExplode,
      usarFFmpeg: useFFmpeg,
    );
  }
  
  // Método para mostrar un diálogo
  static void _showDialog(BuildContext context, String title, String message) {
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
  
  // Método para obtener la configuración actual del DownloadManager
  static Future<Map<String, dynamic>> getCurrentSettings() async {
    final downloadManager = DownloadManager();
    await downloadManager.initialize();
    
    return {
      'directoryPath': downloadManager.directoryPath,
      'usarExplode': downloadManager.usarExplode,
      'usarFFmpeg': downloadManager.usarFFmpeg,
      'isDownloading': downloadManager.isDownloading,
      'isProcessing': downloadManager.isProcessing,
    };
  }
}

// Ejemplo de widget que usa el DownloadManager
class DownloadButton extends StatefulWidget {
  final String videoUrl;
  final String? title;
  
  const DownloadButton({
    super.key,
    required this.videoUrl,
    this.title,
  });

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String? _currentTitle;
  String? _currentArtist;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_isDownloading) ...[
          // Mostrar información del video
          if (_currentTitle != null) ...[
            Text(
              _currentTitle!,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (_currentArtist != null)
              Text(_currentArtist!),
            const SizedBox(height: 8),
          ],
          // Barra de progreso
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
        ],
        // Botón de descarga
        ElevatedButton.icon(
          onPressed: _isDownloading ? null : _startDownload,
          icon: _isDownloading 
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(_isDownloading 
              ? LocaleProvider.tr('downloading')
              : LocaleProvider.tr('download_audio')),
        ),
      ],
    );
  }

  Future<void> _startDownload() async {
    final downloadManager = DownloadManager();
    await downloadManager.initialize();
    
    downloadManager.setCallbacks(
      onInfoUpdate: (title, artist, coverBytes) {
        setState(() {
          _currentTitle = title;
          _currentArtist = artist;
        });
      },
      onProgressUpdate: (progress) {
        setState(() {
          _progress = progress;
        });
      },
      onStateUpdate: (isDownloading, isProcessing) {
        setState(() {
          _isDownloading = isDownloading || isProcessing;
        });
      },
      onError: (title, message) {
        _showErrorDialog(title, message);
      },
      onSuccess: (title, message) {
        _showSuccessDialog(title, message);
      },
    );
    
    await downloadManager.downloadAudio(url: widget.videoUrl);
  }

  void _showErrorDialog(String title, String message) {
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

  void _showSuccessDialog(String title, String message) {
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
} 