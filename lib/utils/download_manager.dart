import 'dart:io';
import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:music/screens/download/stream_provider.dart';
import 'package:audiotags/audiotags.dart';
import 'package:path/path.dart' as p;
import 'package:music/main.dart';
import 'package:image/image.dart' as img;
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/foundation.dart';

// Top-level function para usar con compute
Uint8List? decodeAndCropImage(Uint8List bytes) {
  final original = img.decodeImage(bytes);
  if (original != null) {
    final minSide = original.width < original.height ? original.width : original.height;
    final offsetX = (original.width - minSide) ~/ 2;
    final offsetY = (original.height - minSide) ~/ 2;
    final square = img.copyCrop(original, x: offsetX, y: offsetY, width: minSide, height: minSide);
    return Uint8List.fromList(img.encodeJpg(square));
  }
  return null;
}

class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  // Callbacks para actualizar UI
  Function(String? title, String? artist, Uint8List? coverBytes)? onInfoUpdate;
  Function(double progress)? onProgressUpdate;
  Function(bool isDownloading, bool isProcessing)? onStateUpdate;
  Function(String title, String message)? onError;
  Function(String title, String message)? onSuccess;

  // Configuración
  String? _directoryPath;
  bool _usarExplode = false;
  bool _usarFFmpeg = false;

  // Estado
  bool _isDownloading = false;
  bool _isProcessing = false;

  // Inicializar configuración
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _directoryPath = prefs.getString('download_directory');
    _usarExplode = prefs.getBool('download_type_explode') ?? false;
    _usarFFmpeg = prefs.getBool('audio_processor_ffmpeg') ?? false;
  }

  // Configurar callbacks
  void setCallbacks({
    Function(String? title, String? artist, Uint8List? coverBytes)? onInfoUpdate,
    Function(double progress)? onProgressUpdate,
    Function(bool isDownloading, bool isProcessing)? onStateUpdate,
    Function(String title, String message)? onError,
    Function(String title, String message)? onSuccess,
  }) {
    this.onInfoUpdate = onInfoUpdate;
    this.onProgressUpdate = onProgressUpdate;
    this.onStateUpdate = onStateUpdate;
    this.onError = onError;
    this.onSuccess = onSuccess;
  }

  // Método principal de descarga
  Future<void> downloadAudio({
    required String url,
    String? directoryPath,
    bool? usarExplode,
    bool? usarFFmpeg,
  }) async {
    // Usar parámetros proporcionados o valores por defecto
    final dirPath = directoryPath ?? _directoryPath;
    final explode = usarExplode ?? _usarExplode;
    final ffmpeg = usarFFmpeg ?? _usarFFmpeg;

    if (dirPath == null || dirPath.isEmpty) {
      onError?.call(
        LocaleProvider.tr('folder_not_selected'),
        LocaleProvider.tr('folder_not_selected_desc'),
      );
      return;
    }

    _updateState(true, false);
    onProgressUpdate?.call(0.0);

    try {
      if (explode) {
        await _downloadAudioOnlyExplode(url, dirPath, ffmpeg);
      } else {
        await _downloadAudioOnly(url, dirPath, ffmpeg);
      }
    } catch (e) {
      onError?.call(
        LocaleProvider.tr('download_failed_title'),
        '${LocaleProvider.tr('download_failed_desc')}\n\nDetalles: ${e.toString()}',
      );
    } finally {
      _updateState(false, false);
    }
  }

  // Método 1: Descarga usando Explode
  Future<void> _downloadAudioOnlyExplode(
    String url,
    String directoryPath,
    bool usarFFmpeg,
  ) async {
    final yt = YoutubeExplode();
    try {
      final video = await _intentarObtenerVideo(url);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      final audioList = manifest.audioOnly
          .where((s) => s.codec.mimeType == 'audio/mp4' || s.codec.toString().contains('mp4a'))
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final audioStreamInfo = audioList.isNotEmpty ? audioList.first : null;

      if (audioStreamInfo == null) {
        throw Exception(LocaleProvider.tr('no_valid_stream'));
      }

      final safeTitle = video.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();

      final saveDir = Platform.isAndroid
          ? directoryPath
          : (await getApplicationDocumentsDirectory()).path;
      final filePath = '$saveDir/$safeTitle.m4a';

      // Descargar portada
      final coverBytes = await _downloadCover(video.id.toString());

      onInfoUpdate?.call(video.title, video.author, coverBytes);

      final file = File(filePath);
      if (file.existsSync()) await file.delete();

      final stream = yt.videos.streamsClient.get(audioStreamInfo);
      final sink = file.openWrite();
      final totalBytes = audioStreamInfo.size.totalBytes;
      var received = 0;

      await for (final chunk in stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgressUpdate?.call(received / totalBytes * 0.6);
      }

      await sink.flush();
      await sink.close();

      if (!await file.exists()) throw Exception('La descarga falló.');

      // Procesar audio
      if (usarFFmpeg) {
        await _procesarAudio(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          coverBytes ?? Uint8List(0),
        );
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          coverBytes ?? Uint8List(0),
        );
      }

    } finally {
      yt.close();
    }
  }

  // Método 2: Descarga usando Directo
  Future<void> _downloadAudioOnly(
    String url,
    String directoryPath,
    bool usarFFmpeg,
  ) async {
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
      throw Exception(LocaleProvider.tr('no_audio_available_desc'));
    }

    // Elegir mejor stream de audio
    final audio = streamProvider.highestBitrateMp4aAudio;

    if (audio == null) {
      throw Exception('No se encontró stream de audio válido.');
    }

    final ext = 'm4a';
    final safeTitle = video.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .trim();

    final dir = Platform.isAndroid
        ? directoryPath
        : (await getApplicationDocumentsDirectory()).path;

    // Descargar portada
    final coverBytes = await _downloadCover(video.id.toString());

    onInfoUpdate?.call(video.title, video.author, coverBytes);

    final filePath = '$dir/$safeTitle.$ext';

    await _downloadAudioInParallel(
      url: audio.url,
      filePath: filePath,
      totalSize: audio.size,
      onProgress: (progress) {
        onProgressUpdate?.call(progress * 0.6);
      },
    );

    if (!await File(filePath).exists()) throw Exception("La descarga falló.");
    MediaScanner.loadMedia(path: filePath);

    if (usarFFmpeg) {
      await _procesarAudio(
        video.id.toString(),
        filePath,
        video.title,
        video.author,
        video.thumbnails.highResUrl,
        coverBytes ?? Uint8List(0),
      );
    } else {
      await _procesarAudioSinFFmpeg(
        video.id.toString(),
        filePath,
        video.title,
        video.author,
        video.thumbnails.highResUrl,
        coverBytes ?? Uint8List(0),
      );
    }
  }

  // Método 3: Procesamiento con FFmpeg
  Future<void> _procesarAudio(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
    Uint8List coverBytes,
  ) async {
    _updateState(true, true);

    final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final saveDir = File(inputPath).parent.path;
    final mp3Path = '$saveDir/$baseName.mp3';

    if (await File(mp3Path).exists()) {
      try {
        await File(mp3Path).delete();
        await Future.delayed(const Duration(seconds: 1));
      } catch (e) {
        await File(inputPath).delete();
        throw Exception('El archivo MP3 ya existe y no se pudo eliminar.');
      }
    }

    final metaPath = '$saveDir/${baseName}_meta.mp3';
    final tempDir = await getTemporaryDirectory();
    final coverPath = '${tempDir.path}/${baseName}_cover.jpg';
    await File(coverPath).writeAsBytes(coverBytes);

    final metaFolder = Directory(p.dirname(saveDir));
    if (!await metaFolder.exists()) {
      await metaFolder.create(recursive: true);
    }

    try {
      onProgressUpdate?.call(0.65);

      // 1. Convertir a MP3 (sin metadatos) directo en carpeta final
      final convertSession = await FFmpegKit.execute(
        '-y -i "$inputPath" '
        '-vn -acodec libmp3lame -ar 44100 -ac 2 '
        '"$mp3Path"',
      );
      final convertCode = await convertSession.getReturnCode();
      if (convertCode == null || !convertCode.isValueSuccess()) {
        throw Exception(
          'Error al procesar el audio, intenta usar otra carpeta.',
        );
      }

      final coverFile = File(coverPath);
      final bool coverExists = await coverFile.exists();
      final bool coverIsValid = coverExists && await coverFile.length() > 1000;

      final cleanedAuthor = _limpiarMetadato(
        author.replaceFirst(RegExp(r' - Topic$', caseSensitive: false), ''),
      );
      final safeTitle = _limpiarMetadato(baseName);

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
        throw Exception('Error al escribir metadatos en el audio');
      }

      onProgressUpdate?.call(0.9);

      final currentMediaItem = audioHandler?.mediaItem.value;
      final isPlayingCurrent =
          currentMediaItem != null && currentMediaItem.id == mp3Path;

      if (isPlayingCurrent) {
        await File(mp3Path).delete();
        await File(inputPath).delete();
        await File(coverPath).delete();
        onError?.call(
          LocaleProvider.tr('file_in_use'),
          LocaleProvider.tr('file_in_use_desc'),
        );
        return;
      }

      // 3. Limpiar: borrar input y mp3 sin metadata, renombrar meta a mp3 final
      await File(mp3Path).delete();
      await File(inputPath).delete();
      await File(coverPath).delete();
      await File(metaPath).rename(mp3Path);

      // 4. Indexar en Android
      MediaScanner.loadMedia(path: mp3Path);

      onProgressUpdate?.call(1.0);
      await Future.delayed(const Duration(seconds: 2));
      
      foldersShouldReload.value = !foldersShouldReload.value;

      onSuccess?.call(
        LocaleProvider.tr('download_completed'),
        LocaleProvider.tr('download_completed_desc'),
      );

    } catch (e) {
      onError?.call(
        LocaleProvider.tr('audio_processing_error'),
        e.toString(),
      );
    }
  }

  // Método 4: Procesamiento con AudioTags
  Future<void> _procesarAudioSinFFmpeg(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
    Uint8List bytes,
  ) async {
    _updateState(true, true);

    final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final m4aPath = inputPath;

    try {
      // Escribir metadatos con audiotags
      onProgressUpdate?.call(0.75);

      final cleanedAuthor = _limpiarMetadato(
        author.replaceFirst(RegExp(r' - Topic$', caseSensitive: false), ''),
      );
      final safeTitle = _limpiarMetadato(baseName);

      try {
        final tag = Tag(
          title: safeTitle,
          trackArtist: cleanedAuthor,
          pictures: [
            Picture(
              bytes: bytes,
              mimeType: null,
              pictureType: PictureType.other,
            )
          ],
        );
        await AudioTags.write(m4aPath, tag);
      } catch (e) {
        await File(m4aPath).delete();
        throw Exception('Error al escribir metadatos');
      }

      // Indexar en Android
      MediaScanner.loadMedia(path: m4aPath);

      onProgressUpdate?.call(1.0);
      await Future.delayed(const Duration(seconds: 2));
      
      foldersShouldReload.value = !foldersShouldReload.value;

      onSuccess?.call(
        LocaleProvider.tr('download_completed'),
        LocaleProvider.tr('download_completed_desc'),
      );

    } catch (e) {
      onError?.call(
        LocaleProvider.tr('audio_processing_error'),
        e.toString(),
      );
    }
  }

  // Métodos auxiliares
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

  Future<void> _downloadAudioInParallel({
    required String url,
    required String filePath,
    required int totalSize,
    required void Function(double progress) onProgress,
    int parts = 4,
    int maxRetries = 3,
  }) async {
    final dio = Dio();
    final file = File(filePath);
    final raf = file.openSync(mode: FileMode.write);
    final chunkSize = (totalSize / parts).ceil();
    int downloaded = 0;
    final lock = Object();

    Future<void> downloadChunk(int index) async {
      final start = index * chunkSize;
      int end = ((index + 1) * chunkSize) - 1;
      if (end >= totalSize) end = totalSize - 1;

      int attempt = 0;
      while (attempt < maxRetries) {
        attempt++;
        try {
          final response = await dio.get<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Range': 'bytes=$start-$end'},
            ),
          );

          final bytes = <int>[];
          await response.data!.stream.listen(
            (chunk) {
              bytes.addAll(chunk);
              synchronized(lock, () {
                downloaded += chunk.length;
                onProgress(downloaded / totalSize);
              });
            },
            onDone: () {},
            onError: (e) => throw Exception('Error en chunk $index: $e'),
          ).asFuture();

          raf.setPositionSync(start);
          raf.writeFromSync(bytes);
          break; // Éxito, salimos del while
        } catch (e) {
          if (attempt >= maxRetries) {
            throw Exception('Error permanente en el chunk $index después de $attempt intentos: $e');
          } else {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
    }

    await Future.wait(List.generate(parts, (i) => downloadChunk(i)));

    await raf.close();
  }

  Future<T> synchronized<T>(Object lock, FutureOr<T> Function() func) async {
    return await Future.sync(() => func());
  }

  Future<Uint8List?> _downloadCover(String videoId) async {
    final coverUrlMax = 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
    final coverUrlHQ = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

    Uint8List? bytes;
    final client = HttpClient();
    try {
      // 1. Intentar maxresdefault
      final request = await client.getUrl(Uri.parse(coverUrlMax));
      final response = await request.close();
      if (response.statusCode == 200) {
        bytes = Uint8List.fromList(await _consolidateResponseBytes(response));
      } else {
        // 2. Intentar hqdefault
        final requestHQ = await client.getUrl(Uri.parse(coverUrlHQ));
        final responseHQ = await requestHQ.close();
        if (responseHQ.statusCode == 200) {
          bytes = Uint8List.fromList(await _consolidateResponseBytes(responseHQ));
        } else {
          // 3. Fallback: usar thumbnailUrl con http
          final httpResponse = await http.get(Uri.parse('https://img.youtube.com/vi/$videoId/hqdefault.jpg'));
          if (httpResponse.statusCode == 200) {
            bytes = httpResponse.bodyBytes;
          } else {
            throw Exception('No se pudo descargar ninguna portada');
          }
        }
      }
      // Recortar a cuadrado centrado
      final croppedBytes = await compute(decodeAndCropImage, bytes);
      if (croppedBytes != null) {
        bytes = croppedBytes;
      }
    } finally {
      client.close();
    }

    return bytes;
  }

  Future<List<int>> _consolidateResponseBytes(HttpClientResponse response) {
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

  String _limpiarMetadato(String texto) {
    return texto
        .replaceAll('"', '\\"') // Escapar comillas dobles
        .replaceAll(RegExp(r'[\n\r]'), ' ') // Quitar saltos de línea
        .replaceAll(RegExp(r'[&;|<>$]'), '') // Quitar símbolos peligrosos
        .trim(); // Eliminar espacios al inicio y fin
  }

  void _updateState(bool isDownloading, bool isProcessing) {
    _isDownloading = isDownloading;
    _isProcessing = isProcessing;
    onStateUpdate?.call(isDownloading, isProcessing);
  }

  // Getters para el estado actual
  bool get isDownloading => _isDownloading;
  bool get isProcessing => _isProcessing;
  String? get directoryPath => _directoryPath;
  bool get usarExplode => _usarExplode;
  bool get usarFFmpeg => _usarFFmpeg;
} 