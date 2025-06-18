import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:http/http.dart' as http;

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen>
    with WidgetsBindingObserver {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();
  bool _isDownloading = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  String? _directoryPath;

  double _lastBottomInset = 0.0; // <-- Ya está declarado

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedDirectory();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Actualiza el valor al entrar a la pantalla
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final bottomInset = View.of(context).viewInsets.bottom;
    if (_lastBottomInset > 0.0 && bottomInset == 0.0) {
      if (mounted && _focusNode.hasFocus) {
        _focusNode.unfocus();
      }
    }
    _lastBottomInset = bottomInset;
  }

  Future<void> _loadSavedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('download_directory');
    if (savedPath != null && savedPath.isNotEmpty) {
      setState(() {
        _directoryPath = savedPath;
      });
    }
  }

  Future<void> _saveDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_directory', path);
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.storage.isGranted) return true;
    if (await Permission.audio.isGranted) return true;
    final s = await Permission.storage.request();
    if (s.isGranted) return true;
    final a = await Permission.audio.request();
    return a.isGranted;
  }

  Future<void> _pickDirectory() async {
    final String? path = await getDirectoryPath();
    if (path == null) {
      // El usuario canceló la selección
    } else {
      setState(() {
        _directoryPath = path;
      });
      await _saveDirectory(path);
    }
  }

  // Future<void> _downloadAudio() async {
  //   final url = _urlController.text.trim();
  //   if (url.isEmpty) return;
  //   if (!await _ensurePermissions()) return;

  //   if (Platform.isAndroid && _directoryPath == null) {
  //     if (mounted) {
  //       showDialog(
  //         context: context,
  //         builder: (context) => AlertDialog(
  //           title: const Text('Carpeta no seleccionada'),
  //           content: const Text(
  //             'Debes seleccionar una carpeta antes de descargar el audio.',
  //           ),
  //           actions: [
  //             TextButton(
  //               onPressed: () => Navigator.of(context).pop(),
  //               child: const Text('Aceptar'),
  //             ),
  //           ],
  //         ),
  //       );
  //     }
  //     return;
  //   }

  //   setState(() {
  //     _isDownloading = true;
  //     _progress = 0.0;
  //   });

  //   final yt = YoutubeExplode();
  //   try {
  //     final video = await yt.videos.get(url);
  //     final manifest = await yt.videos.streamsClient
  //         .getManifest(video.id)
  //         .timeout(const Duration(seconds: 10));

  //     final audioStreams = manifest.audioOnly;

  //     final audioInfo = audioStreams.withHighestBitrate();

  //     final safeTitle = video.title
  //         .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
  //         .trim();
  //     final saveDir = Platform.isAndroid
  //         ? _directoryPath!
  //         : (await getApplicationDocumentsDirectory()).path;

  //     final inputPath = '$saveDir/$safeTitle.m4a';
  //     final mp3Path = '$saveDir/$safeTitle.mp3';
  //     final metaPath = '$saveDir/${safeTitle}_final.mp3';
  //     final coverPath = '$saveDir/${safeTitle}_cover.jpg';

  //     // Limpieza previa
  //     for (final path in [inputPath, mp3Path, metaPath, coverPath]) {
  //       final file = File(path);
  //       if (file.existsSync()) await file.delete();
  //     }

  //     // Verificar acceso al stream antes de abrir archivo
  //     late Stream<List<int>> stream;
  //     try {
  //       stream = yt.videos.streamsClient.get(audioInfo);
  //     } on YoutubeExplodeException catch (e) {
  //       throw Exception('Error al obtener el stream: ${e.message}');
  //     }

  //     final file = File(inputPath);
  //     final sink = file.openWrite();
  //     final totalBytes = audioInfo.size.totalBytes;
  //     var received = 0;

  //     try {
  //       await for (final chunk in stream) {
  //         received += chunk.length;
  //         sink.add(chunk);
  //         setState(() => _progress = received / totalBytes * 0.6); // 0-60%
  //       }
  //     } finally {
  //       await sink.flush();
  //       await sink.close();
  //     }

  //     if (!await file.exists()) throw Exception('La descarga falló.');

  //     // Conversión a MP3
  //     setState(() => _progress = 0.65);
  //     final session = await FFmpegKit.execute(
  //       '-i "$inputPath" -vn -acodec libmp3lame "$mp3Path"',
  //     );
  //     final returnCode = await session.getReturnCode();
  //     if (returnCode?.isValueSuccess() != true) {
  //       throw Exception('Conversión fallida.');
  //     }

  //     await file.delete();

  //     // Descargar portada
  //     setState(() => _progress = 0.75);
  //     final response = await http.get(Uri.parse(video.thumbnails.highResUrl));
  //     await File(coverPath).writeAsBytes(response.bodyBytes);

  //     // Insertar metadata
  //     setState(() => _progress = 0.85);
  //     final artist = video.author.replaceFirst(
  //       RegExp(r' - Topic$', caseSensitive: false),
  //       '',
  //     );
  //     final metaSession = await FFmpegKit.execute(
  //       '-i "$mp3Path" -i "$coverPath" '
  //       '-map 0:a -map 1 '
  //       '-metadata artist="$artist" '
  //       '-metadata:s:v title="Album cover" '
  //       '-metadata:s:v comment="Cover (front)" '
  //       '-id3v2_version 3 -write_id3v1 1 '
  //       '-codec copy "$metaPath"',
  //     );

  //     if ((await metaSession.getReturnCode())?.isValueSuccess() != true) {
  //       throw Exception('Error al escribir metadata.');
  //     }

  //     await File(mp3Path).delete();
  //     await File(metaPath).rename(mp3Path);
  //     await File(coverPath).delete();

  //     // Indexar en Android
  //     MediaScanner.loadMedia(path: mp3Path);
  //     setState(() => _progress = 1.0);

  //     await Future.delayed(const Duration(seconds: 2));
  //     foldersShouldReload.value = !foldersShouldReload.value;

  //     if (mounted) {
  //       _urlController.clear();
  //       _focusNode.unfocus();
  //     }
  //   } catch (e) {
  //     if (mounted) {
  //       showDialog(
  //         context: context,
  //         builder: (context) => AlertDialog(
  //           title: const Text('Descarga fallida'),
  //           content: Text(
  //             'Ocurrió un error, intentalo de nuevo.\n\n'
  //             'Detalles: ${e.toString()}',
  //           ),
  //           actions: [
  //             TextButton(
  //               onPressed: () => Navigator.of(context).pop(),
  //               child: const Text('OK'),
  //             ),
  //           ],
  //         ),
  //       );
  //     }
  //   } finally {
  //     yt.close();
  //     if (mounted) setState(() => _isDownloading = false);
  //   }
  // }

  Future<Video> _intentarObtenerVideo(YoutubeExplode yt, String url) async {
    for (int intento = 0; intento < 10; intento++) {
      try {
        return await yt.videos.get(url);
      } on VideoUnavailableException {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
    throw VideoUnavailableException(
      'El video no está disponible después de varios intentos.',
    );
  }

  Future<void> _downloadAudioOnly() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    if (!await _ensurePermissions()) return;

    if (Platform.isAndroid && _directoryPath == null) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Carpeta no seleccionada'),
            content: const Text(
              'Debes seleccionar una carpeta antes de descargar el audio.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );
      }
      return;
    }

    setState(() {
      _isDownloading = true;
      _isProcessing = false;
      _progress = 0.0;
    });

    final yt = YoutubeExplode();
    try {
      final video = await _intentarObtenerVideo(yt, url);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();
      final safeTitle = video.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();

      final saveDir = Platform.isAndroid
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;
      final filePath = '$saveDir/$safeTitle.m4a';

      final file = File(filePath);
      if (file.existsSync()) await file.delete();

      final stream = yt.videos.streamsClient.get(audioStreamInfo);
      final sink = file.openWrite();
      final totalBytes = audioStreamInfo.size.totalBytes;
      var received = 0;

      await for (final chunk in stream) {
        received += chunk.length;
        sink.add(chunk);
        setState(() => _progress = received / totalBytes * 0.6); // 0-60%
      }

      await sink.flush();
      await sink.close();

      if (!await file.exists()) throw Exception('La descarga falló.');

      await _procesarAudio(
        filePath,
        video.title,
        video.author,
        video.thumbnails.highResUrl,
      );
    } on VideoUnavailableException {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Video no disponible'),
            content: const Text(
              'El video no está disponible. Puede haber sido eliminado, '
              'es privado o está restringido por YouTube.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _urlController.clear();
                  _focusNode.unfocus();
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }

      // Ya no es necesario el resto del código aquí, pues _procesarAudio se encarga del resto
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Descarga fallida'),
            content: Text(
              'Ocurrió un error, intentalo de nuevo.\n\n'
              'Detalles: ${e.toString()}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      yt.close();
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _procesarAudio(
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
  ) async {
    setState(() {
      _isProcessing = true;
    });
    final saveDir = File(inputPath).parent.path;
    final tempDir = await getTemporaryDirectory();
    final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final mp3Path = '$saveDir/$baseName.mp3';
    final metaPath = '$saveDir/${baseName}_meta.mp3';
    final coverPath = '${tempDir.path}/${baseName}_cover.jpg';

    for (final path in [mp3Path, metaPath, coverPath]) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    }

    try {
      setState(() => _progress = 0.65);

      // Conversión a MP3 (sin video)
      final convertSession = await FFmpegKit.execute(
        '-i "$inputPath" -vn -acodec libmp3lame "$mp3Path"',
      );

      if (!(await convertSession.getReturnCode())!.isValueSuccess()) {
        throw Exception('Error al convertir a MP3');
      }

      // Descargar portada
      setState(() => _progress = 0.75);
      final response = await http.get(Uri.parse(thumbnailUrl));
      await File(coverPath).writeAsBytes(response.bodyBytes);

      // Insertar metadata ID3
      setState(() => _progress = 0.85);

      final cleanedAuthor = author.replaceFirst(
        RegExp(r' - Topic$', caseSensitive: false),
        '',
      );

      final metaSession = await FFmpegKit.execute(
        '-i "$mp3Path" -i "$coverPath" '
        '-map 0:a -map 1 '
        '-metadata title="$baseName" '
        '-metadata artist="$cleanedAuthor" '
        '-metadata:s:v title="Album cover" '
        '-metadata:s:v comment="Cover (front)" '
        '-id3v2_version 3 -write_id3v1 1 '
        '-codec copy "$metaPath"',
      );

      if (!(await metaSession.getReturnCode())!.isValueSuccess()) {
        throw Exception('Error al escribir metadatos');
      }

      // Limpiar archivos temporales
      await File(inputPath).delete();
      await File(mp3Path).delete();
      await File(coverPath).delete();
      await File(metaPath).rename(mp3Path);

      // Indexar en Android
      MediaScanner.loadMedia(path: mp3Path);
      setState(() => _progress = 1.0);

      await Future.delayed(const Duration(seconds: 2));
      foldersShouldReload.value = !foldersShouldReload.value;

      if (mounted) {
        _urlController.clear();
        _focusNode.unfocus();
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Error al procesar audio'),
            content: Text('Detalles: ${e.toString()}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
        }
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (_focusNode.hasFocus && bottomInset == 0) {
      Future.microtask(() => _focusNode.unfocus());
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.ondemand_video, size: 28),
            const SizedBox(width: 8),
            const Text('Descargar'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.downloading),
            tooltip: 'Recomendar Seal',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('¿Quieres más opciones?'),
                  content: const Text(
                    'Te recomendamos la app gratuita Seal para descargar música y videos de muchas fuentes.\n\n¿Quieres el repositorio de GitHub de Seal?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                    TextButton(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        final Uri url = Uri.parse(
                          'https://github.com/JunkFood02/Seal/releases',
                        );
                        try {
                          await launchUrl(
                            url,
                            mode: LaunchMode.externalApplication,
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('No se pudo abrir el navegador'),
                            ),
                          );
                        }
                      },
                      child: const Text('Abrir'),
                    ),
                  ],
                ),
              );
            },
          ),

          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Información',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Información'),
                  content: const Text(
                    'Esta función descarga únicamente el audio de videos individuales de YouTube o YouTube Music.\n\n'
                    'No funciona con playlists, videos privados, ni contenido protegido por derechos de autor.\n\n'
                    'La descargar puede fallar por bloqueos de YouTube.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Entendido'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    focusNode: _focusNode,
                    decoration: const InputDecoration(
                      labelText: 'Enlace de YouTube',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  width: 56,
                  child: Material(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async {
                        final data = await Clipboard.getData('text/plain');
                        if (data != null && data.text != null) {
                          setState(() {
                            _urlController.text = data.text!;
                          });
                        }
                      },
                      child: Tooltip(
                        message: 'Pegar enlace',
                        child: Icon(
                          Icons.paste,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Botón de carpeta (ya existente)
                SizedBox(
                  height: 56,
                  width: 56,
                  child: Material(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _pickDirectory,
                      child: Tooltip(
                        message: _directoryPath == null
                            ? 'Elegir carpeta'
                            : 'Carpeta lista',
                        child: Icon(
                          Icons.folder_open,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 56,
              width: double.infinity,
              child: Material(
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _isDownloading ? null : _downloadAudioOnly,
                  child: Center(
                    child: Text(
                      _isDownloading
                          ? (_isProcessing
                                ? 'Procesando audio...'
                                : 'Descargando... ${((_progress / 0.6).clamp(0, 1) * 100).toStringAsFixed(0)}%')
                          : 'Descargar Audio',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_isDownloading)
              LinearProgressIndicator(value: _progress, minHeight: 8),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.folder,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _directoryPath ??
                        (Platform.isAndroid
                            ? 'No seleccionada'
                            : 'Documentos de la app'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
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
