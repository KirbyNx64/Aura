import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
// import 'package:android_intent_plus/android_intent.dart';
// import 'package:android_intent_plus/flag.dart';
// import 'package:package_info_plus/package_info_plus.dart';
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
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:music/screens/download/stream_provider.dart';
import 'package:path/path.dart' as p;
import 'package:music/main.dart';

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

  bool _usarExplode = false;

  double _progress = 0.0;
  String? _directoryPath;

  double _lastBottomInset = 0.0;

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

  // Future<bool> _ensurePermissions() async {
  //   if (!Platform.isAndroid) return true;
  //   if (await Permission.storage.isGranted) return true;
  //   if (await Permission.audio.isGranted) return true;
  //   final s = await Permission.storage.request();
  //   if (s.isGranted) return true;
  //   final a = await Permission.audio.request();
  //   return a.isGranted;
  // }

  Future<void> _pickDirectory() async {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    // Si es Android 9 (API 28) o inferior, usar carpeta Música por defecto
    if (sdkInt <= 28) {
      final path = await _getDefaultMusicDir();
      setState(() => _directoryPath = path);
      await _saveDirectory(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'En Android 9 o inferior se usará la carpeta Música por defecto.',
          ),
        ),
      );
      return;
    }

    final String? path = await getDirectoryPath();
    if (path != null) {
      setState(() => _directoryPath = path);
      await _saveDirectory(path);
    }
  }

  Future<String> _getDefaultMusicDir() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Music');
      if (await dir.exists()) return dir.path;
      final downloads = await getExternalStorageDirectory();
      return downloads?.path ?? '/storage/emulated/0/Download';
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
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

  Future<void> _downloadAudioOnlyExplode() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (Platform.isAndroid && _directoryPath == null ||
        _directoryPath!.isEmpty) {
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
      final video = await _intentarObtenerVideo(url);
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
        setState(() => _progress = received / totalBytes * 0.6);
      }

      await sink.flush();
      await sink.close();

      if (!await file.exists()) throw Exception('La descarga falló.');

      await _procesarAudio(
        video.id.toString(),
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
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isProcessing = false;
        });
      }
    }
  }

  Future<Video> _intentarObtenerVideo(
    String url, {
    int maxIntentos = 10,
  }) async {
    for (int intento = 1; intento <= maxIntentos; intento++) {
      final yt = YoutubeExplode(YoutubeHttpClient());

      try {
        final video = await yt.videos.get(url);
        yt.close();
        return video;
      } on VideoUnavailableException {
        yt.close();
        await Future.delayed(const Duration(seconds: 3));
      } catch (e) {
        yt.close();
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    throw VideoUnavailableException(
      '✖️ ERROR: El video no está disponible después de varios intentos.',
    );
  }

  Future<void> _downloadAudioOnly() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (Platform.isAndroid && _directoryPath == null ||
        _directoryPath!.isEmpty) {
      _mostrarAlerta(
        titulo: 'Carpeta no seleccionada',
        mensaje: 'Debes seleccionar una carpeta antes de descargar el audio.',
      );
      return;
    }

    setState(() {
      _isDownloading = true;
      _isProcessing = false;
      _progress = 0.0;
    });

    try {
      // Extraer videoId de la URL
      final videoId = VideoId.parseVideoId(url);
      if (videoId == null) throw Exception('URL inválida');

      // Reintento para obtener video + manifest
      late Video video;
      late StreamManifest manifest;

      for (int intento = 1; intento <= 1; intento++) {
        final yt = YoutubeExplode();
        try {
          video = await yt.videos.get(videoId);
          manifest = await yt.videos.streamsClient.getManifest(videoId);
          yt.close();
          break;
        } on VideoUnavailableException {
          yt.close();
          await Future.delayed(const Duration(seconds: 3));
        } catch (_) {
          yt.close();
          await Future.delayed(const Duration(seconds: 3));
        }

        if (intento == 1) {
          throw VideoUnavailableException('No se pudo obtener el video.');
        }
      }

      // Crear StreamProvider desde el manifest
      final streamProvider = StreamProvider.fromManifest(manifest);

      if (!streamProvider.playable || streamProvider.audioFormats == null) {
        _mostrarAlerta(
          titulo: 'Audio no disponible',
          mensaje: 'No se pudo obtener el stream de audio.',
        );
        return;
      }

      // Elegir mejor stream de audio
      final audio =
          streamProvider.highestBitrateOpusAudio ??
          streamProvider.highestBitrateMp4aAudio;

      if (audio == null) {
        throw Exception('No se encontró stream de audio válido.');
      }

      final ext = audio.audioCodec == Codec.opus ? 'opus' : 'm4a';
      final safeTitle = video.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();

      final dir = Platform.isAndroid
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;

      final filePath = '$dir/$safeTitle.$ext';

      final dio = Dio();
      await dio.download(
        audio.url,
        filePath,
        onReceiveProgress: (count, total) {
          if (total > 0) {
            setState(() => _progress = (count / total) * 0.6);
          }
        },
        options: Options(headers: {"Range": "bytes=0-${audio.size}"}),
      );

      if (!await File(filePath).exists()) throw Exception("La descarga falló.");

      await _procesarAudio(
        video.id.toString(),
        filePath,
        video.title,
        video.author,
        video.thumbnails.highResUrl,
      );
    } catch (e) {
      _mostrarAlerta(titulo: 'Error', mensaje: e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _verificarPermisoArchivos() async {
    // Solo mostrar en Android 11+ (SDK 30+)
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = androidInfo.version.sdkInt;
      if (sdkInt < 30) {
        _mostrarAlerta(
          titulo: 'No necesario',
          mensaje:
              'No necesitas otorgar este permiso en tu versión de Android.',
        );
        return;
      }
    } else {
      _mostrarAlerta(
        titulo: 'Solo Android',
        mensaje: 'Esta función solo aplica para Android.',
      );
      return;
    }

    // Mostrar advertencia antes de solicitar el permiso
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Otorgar permisos de archivos?'),
        content: const Text(
          'Esta función NO es necesaria para la mayoría de usuarios.\n\n'
          'Úsala solo si tienes problemas al procesar el audio o guardar archivos.\n\n'
          '¿Quieres continuar y otorgar permisos de acceso a todos los archivos?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              // Ahora sí solicita el permiso
              if (await Permission.manageExternalStorage.isGranted) {
                _mostrarAlerta(
                  titulo: 'Permiso concedido',
                  mensaje: 'Ya tienes acceso a todos los archivos.',
                );
              } else {
                final status = await Permission.manageExternalStorage.request();
                if (status.isGranted) {
                  _mostrarAlerta(
                    titulo: 'Permiso concedido',
                    mensaje: 'Ahora tienes acceso a todos los archivos.',
                  );
                } else {
                  _mostrarAlerta(
                    titulo: 'Permiso denegado',
                    mensaje:
                        'No se concedió el permiso. Ve a ajustes para otorgarlo manualmente.',
                  );
                }
              }
            },
            child: const Text('Otorgar permisos'),
          ),
        ],
      ),
    );
  }

  // Future<void> _abrirPermisoArchivos() async {
  //   // Intento abrir la pantalla de "Acceso a todos los archivos"
  //   const url = 'package:com.android.settings/files_access_permission';
  //   if (await canLaunchUrl(Uri.parse(url))) {
  //     await launchUrl(Uri.parse(url));
  //   } else {
  //     // Fallback: abrir la configuración de la app
  //     final intent = AndroidIntent(
  //       action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
  //       data: 'package:${await _getPackageName()}',
  //       flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
  //     );
  //     await intent.launch();
  //   }
  // }

  // Future<String> _getPackageName() async {
  //   final packageInfo = await PackageInfo.fromPlatform();
  //   return packageInfo.packageName;
  // }

  void _mostrarAlerta({required String titulo, required String mensaje}) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(titulo),
        content: Text(mensaje),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _procesarAudio(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
  ) async {
    setState(() {
      _isProcessing = true;
    });

    final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final saveDir = File(inputPath).parent.path;
    final mp3Path = '$saveDir/$baseName.mp3';

    if (await File(mp3Path).exists()) {
      try {
        await File(mp3Path).delete();
        await Future.delayed(const Duration(seconds: 1));
        // print('🗑️ Archivo MP3 existente eliminado: $mp3Path');
      } catch (e) {
        await File(inputPath).delete();
        // print('⚠️ Error al eliminar archivo MP3 existente: $mp3Path');
        // print('Detalles del error: $e');
        throw Exception('El archivo MP3 ya existe y no se pudo eliminar.');
      }
    }

    final metaPath = '$saveDir/${baseName}_meta.mp3';
    final tempDir = await getTemporaryDirectory();
    final coverPath = '${tempDir.path}/${baseName}_cover.jpg';

    final metaFolder = Directory(p.dirname(saveDir));
    if (!await metaFolder.exists()) {
      await metaFolder.create(recursive: true);
    }

    try {
      setState(() => _progress = 0.65);

      // 1. Convertir a MP3 (sin metadatos) directo en carpeta final
      final convertSession = await FFmpegKit.execute(
        '-y -i "$inputPath" '
        '-vn -acodec libmp3lame -ar 44100 -ac 2 '
        '"$mp3Path"',
      );
      final convertCode = await convertSession.getReturnCode();
      if (convertCode == null || !convertCode.isValueSuccess()) {
        // Obtener logs estándar
        // final logs = await convertSession.getAllLogs();
        // final allMessages = logs.map((e) => e.getMessage()).join('\n');

        // Solo las últimas 20 líneas del log
        // final lastLines = allMessages
        //     .split('\n')
        //     .where((line) => line.trim().isNotEmpty)
        //     .toList()
        //     .reversed
        //     .take(20)
        //     .toList()
        //     .reversed
        //     .join('\n');

        // print('👻 Error al convertir a MP3 (últimas líneas):\n$lastLines');
        throw Exception(
          'Error al procesar el audio, intenta usar otra carpeta.',
        );
      }
      // Descargar portada
      setState(() => _progress = 0.75);
      final coverUrlMax =
          'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
      final client = HttpClient();

      Uint8List? bytes;

      // print('🌐 Descargando portada de: $coverUrlMax');

      try {
        // 1. Intentar maxresdefault
        final request = await client.getUrl(Uri.parse(coverUrlMax));
        final response = await request.close();
        if (response.statusCode == 200) {
          bytes = Uint8List.fromList(await consolidateResponseBytes(response));
        } else {
          // 2. Intentar hqdefault
          final requestHQ = await client.getUrl(Uri.parse(coverUrlHQ));
          final responseHQ = await requestHQ.close();
          if (responseHQ.statusCode == 200) {
            bytes = Uint8List.fromList(
              await consolidateResponseBytes(responseHQ),
            );
          } else {
            // 3. Fallback: usar thumbnailUrl con http
            final httpResponse = await http.get(Uri.parse(thumbnailUrl));
            if (httpResponse.statusCode == 200) {
              bytes = httpResponse.bodyBytes;
            } else {
              throw Exception('No se pudo descargar ninguna portada');
            }
          }
        }
        await File(coverPath).writeAsBytes(bytes);
      } finally {
        client.close();
      }

      final coverFile = File(coverPath);
      final bool coverExists = await coverFile.exists();
      final bool coverIsValid = coverExists && await coverFile.length() > 1000;

      final cleanedAuthor = limpiarMetadato(
        author.replaceFirst(RegExp(r' - Topic$', caseSensitive: false), ''),
      );
      final safeTitle = limpiarMetadato(baseName);

      final ffmpegCmd = coverIsValid
          ? '-y -i "$mp3Path" -i "$coverPath" '
                '-map 0:a -map 1 '
                '-metadata title="${safeTitle.replaceAll('"', '\\"')}" '
                '-metadata artist="${cleanedAuthor.replaceAll('"', '\\"')}" '
                '-metadata:s:v title="Album cover" '
                '-metadata:s:v comment="Cover (front)" '
                '-id3v2_version 3 -write_id3v1 1 '
                '-codec copy "$metaPath"'
          : '-y -i "$mp3Path" '
                '-metadata title="${safeTitle.replaceAll('"', '\\"')}" '
                '-metadata artist="${cleanedAuthor.replaceAll('"', '\\"')}" '
                '-id3v2_version 3 -write_id3v1 1 '
                '-codec copy "$metaPath"';

      final metaSession = await FFmpegKit.execute(ffmpegCmd);

      final metaCode = await metaSession.getReturnCode();
      if (metaCode == null || !metaCode.isValueSuccess()) {
        await File(mp3Path).delete();
        await File(inputPath).delete();
        await File(coverPath).delete();
        // final logs = await metaSession.getAllLogs();
        // final lastLines = logs
        //     .map((e) => e.getMessage())
        //     .where((line) => line.trim().isNotEmpty)
        //     .toList()
        //     .reversed
        //     .take(30)
        //     .toList()
        //     .reversed
        //     .join('\n');

        // print('🧨 Error al agregar metadatos (últimas líneas):\n$lastLines');
        throw Exception('Error al escribir metadatos en el auido');
      }

      setState(() => _progress = 0.9);

      final currentMediaItem =
          audioHandler.mediaItem.value; // O usa handler.mediaItem.value
      final isPlayingCurrent =
          currentMediaItem != null && currentMediaItem.id == mp3Path;

      if (isPlayingCurrent) {
        await File(mp3Path).delete();
        await File(inputPath).delete();
        await File(coverPath).delete();
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Archivo en reproducción'),
              content: const Text(
                'No se puede sobrescribir el archivo porque está en reproducción. Por favor, detén la reproducción antes de descargar de nuevo.',
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
        setState(() {
          _isProcessing = false;
          _isDownloading = false;
        });
        return;
      }

      // 3. Limpiar: borrar input y mp3 sin metadata, renombrar meta a mp3 final
      await File(mp3Path).delete();
      await File(inputPath).delete();
      await File(coverPath).delete();
      await File(metaPath).rename(mp3Path);

      // 4. Indexar en Android
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
            content: Text(e.toString()),
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
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isDownloading = false;
        });
      }
    }
  }

  String limpiarMetadato(String texto) {
    return texto
        .replaceAll('"', '\\"') // Escapar comillas dobles
        .replaceAll(RegExp(r'[\n\r]'), ' ') // Quitar saltos de línea
        .replaceAll(RegExp(r'[&;|<>$]'), '') // Quitar símbolos peligrosos
        .trim(); // Eliminar espacios al inicio y fin
  }

  Future<List<int>> consolidateResponseBytes(HttpClientResponse response) {
    final completer = Completer<List<int>>();
    final contents = <int>[];
    response.listen(
      (data) => contents.addAll(data),
      onDone: () => completer.complete(contents),
      onError: (e) => completer.completeError(e),
      cancelOnError: true,
    );
    return completer.future;
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
            icon: const Icon(Icons.downloading, size: 28),
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
            icon: const Icon(Icons.info_outline, size: 28),
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
              ],
            ),

            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    width: double.infinity,
                    child: Material(
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: _isDownloading
                            ? null
                            : () {
                                if (_usarExplode) {
                                  _downloadAudioOnlyExplode();
                                } else {
                                  _downloadAudioOnly();
                                }
                              },
                        child: Center(
                          child: Text(
                            _isDownloading
                                ? (_isProcessing
                                      ? 'Procesando audio...'
                                      : 'Descargando... ${((_progress / 0.6).clamp(0, 1) * 100).toStringAsFixed(0)}%')
                                : 'Descargar Audio',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Botón de carpeta a la derecha del botón de descarga
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
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  width: 56,
                  child: Material(
                    borderRadius: BorderRadius.circular(8),
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _verificarPermisoArchivos,
                      child: Tooltip(
                        message: 'Permisos de archivos',
                        child: Icon(
                          Icons.security,
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
            // NUEVO: Selector de método de descarga
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Icon(
                  Icons.download,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Text('Método:'),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Explode'),
                  selected: _usarExplode,
                  onSelected: (v) {
                    setState(() => _usarExplode = true);
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Directo'),

                  selected: !_usarExplode,
                  onSelected: (v) {
                    setState(() => _usarExplode = false);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
