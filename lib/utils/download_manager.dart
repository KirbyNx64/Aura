import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:music/screens/download/stream_provider.dart';
import 'package:audiotags/audiotags.dart';
// import 'package:path/path.dart' as p;
// import 'package:music/main.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:flutter/material.dart';
import 'package:music/services/download_history_service.dart';
import 'package:music/models/download_record.dart';
import 'package:path/path.dart' as path;
import 'package:music/utils/db/songs_index_db.dart';
import 'package:music/utils/db/download_history_hive.dart';

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
  String _audioQuality = 'high';

  // Estado
  bool _isDownloading = false;
  bool _isProcessing = false;

  // Control de throttling para actualizaciones de progreso
  DateTime? _lastProgressUpdate;
  static const _progressUpdateInterval = Duration(
    milliseconds: 100,
  ); // Actualizar máximo cada 100ms

  // Contexto opcional para mostrar diálogos directamente desde el manager
  BuildContext? _dialogContext;

  // Instancia única de YoutubeExplode para reutilizar entre descargas
  YoutubeExplode? _ytInstance;

  // Obtener o crear la instancia única de YoutubeExplode (no se cierra aquí, solo cuando la cola esté vacía)
  YoutubeExplode _getYoutubeExplode() {
    if (_ytInstance == null) {
      _ytInstance = YoutubeExplode();
      // print('🟩 YoutubeExplode: nueva instancia creada');
    } else {
      // print('🟩 YoutubeExplode: reutilizando instancia existente');
    }
    return _ytInstance!;
  }

  // Cerrar la instancia (solo lo llama DownloadQueue cuando la cola está vacía, o al cerrar la app)
  void closeYoutubeExplode() {
    if (_ytInstance != null) {
      // print('🔴 YoutubeExplode: cerrando instancia (cola vacía o app cerrada)');
      _ytInstance!.close();
      _ytInstance = null;
    }
  }

  // Inicializar configuración
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _directoryPath =
        prefs.getString('download_directory') ?? '/storage/emulated/0/Music';
    _usarExplode = prefs.getBool('download_type_explode') ?? true;
    _usarFFmpeg = prefs.getBool('audio_processor_ffmpeg') ?? false;
    _audioQuality = prefs.getString('audio_quality') ?? 'high';

    // Guardar el directorio por defecto si no existe
    if (!prefs.containsKey('download_directory')) {
      await prefs.setString('download_directory', '/storage/emulated/0/Music');
    }
  }

  // Configurar callbacks
  void setCallbacks({
    Function(String? title, String? artist, Uint8List? coverBytes)?
    onInfoUpdate,
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

  // Permite inyectar un contexto para mostrar diálogos de error directamente desde el manager
  void setDialogContext(BuildContext? context) {
    _dialogContext = context;
  }

  // Método principal de descarga
  Future<void> downloadAudio({
    required String url,
    String? directoryPath,
    bool? usarExplode,
    bool? usarFFmpeg,
    String? songTitle,
    String? preferredThumbUrl,
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
      if (onError == null) {
        _showErrorDialog(
          LocaleProvider.tr('folder_not_selected'),
          LocaleProvider.tr('folder_not_selected_desc'),
        );
      }
      return;
    }

    _updateState(true, false);
    _updateProgress(0.0);

    try {
      if (explode) {
        await _downloadAudioOnlyExplode(
          url,
          dirPath,
          ffmpeg,
          songTitle,
          preferredThumbUrl,
        );
      } else {
        await _downloadAudioOnly(
          url,
          dirPath,
          ffmpeg,
          songTitle,
          preferredThumbUrl,
        );
      }
    } catch (e) {
      if (e is VideoUnplayableException) {
        onError?.call(
          (songTitle != null && songTitle.trim().isNotEmpty)
              ? songTitle.trim()
              : LocaleProvider.tr('download_failed_title'),
          LocaleProvider.tr('download_failed_desc_2'),
        );
      }
    } finally {
      _updateState(false, false);
    }
  }

  // Método 1: Descarga usando Explode
  Future<void> _downloadAudioOnlyExplode(
    String url,
    String directoryPath,
    bool usarFFmpeg,
    String? songTitle,
    String? preferredThumbUrl,
  ) async {
    final yt = _getYoutubeExplode();
    try {
      final video = await _intentarObtenerVideo(url, ytInstance: yt);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);

      final audioList = manifest.audioOnly
          .where(
            (s) =>
                s.codec.mimeType == 'audio/mp4' ||
                s.codec.toString().contains('mp4a'),
          )
          .toList();
      final audioStreamInfo = _selectAudioStream(audioList);

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

      // Descargar portada con estrategia fija por videoId.
      final coverBytes = await _downloadCover(
        video.id.toString(),
        preferredThumbUrl: preferredThumbUrl,
      );

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
        _updateProgress(received / totalBytes * 0.99);
      }

      await sink.flush();
      await sink.close();

      if (!await file.exists()) throw Exception('La descarga falló.');

      // Procesar audio
      if (usarFFmpeg) {
        // ...
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          coverBytes ?? Uint8List(0),
          songTitle,
          video.duration ?? Duration.zero,
          url,
        );
      }
    } finally {
      // No cerramos la instancia: se reutiliza para la siguiente descarga en cola
      // Se cierra solo cuando DownloadQueue detecta que la cola está vacía
    }
  }

  // Método 2: Descarga usando Directo
  Future<void> _downloadAudioOnly(
    String url,
    String directoryPath,
    bool usarFFmpeg,
    String? songTitle,
    String? preferredThumbUrl,
  ) async {
    // Extraer videoId de la URL
    final videoId = VideoId.parseVideoId(url);
    if (videoId == null) throw Exception('URL inválida');

    // Reintento para obtener video + manifest
    late Video video;
    late StreamManifest manifest;

    for (int intento = 1; intento <= 1; intento++) {
      final yt = _getYoutubeExplode();
      try {
        video = await yt.videos.get(videoId);
        manifest = await yt.videos.streamsClient.getManifest(videoId);
        break;
      } on VideoUnavailableException {
        await Future.delayed(const Duration(seconds: 3));
      } catch (_) {
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

    // Elegir stream de audio según calidad configurada, filtrando por MP4A para asegurar compatibilidad
    final audioFormats = streamProvider.audioFormats;
    if (audioFormats == null || audioFormats.isEmpty) {
      throw Exception('No se encontró stream de audio válido.');
    }

    // Filtrar por MP4A para asegurar compatibilidad con el contenedor .m4a
    final mp4aFormats = audioFormats
        .where((a) => a.audioCodec == Codec.mp4a)
        .toList();

    if (mp4aFormats.isEmpty) {
      throw Exception('No se encontró stream de audio MP4 compatible.');
    }

    // Ordenar por bitrate (mayor a menor)
    final sortedFormats = mp4aFormats
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    Audio audio;
    switch (_audioQuality) {
      case 'high':
        // Mejor calidad disponible
        audio = sortedFormats.first;
        break;
      case 'medium':
        // Calidad media - tomar el stream del medio
        final middleIndex = (sortedFormats.length / 2).floor();
        audio = sortedFormats[middleIndex];
        break;
      case 'low':
        // Calidad baja - tomar el stream de menor calidad
        audio = sortedFormats.last;
        break;
      default:
        audio = sortedFormats.first;
    }

    final ext = 'm4a';
    final safeTitle = video.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .trim();

    final dir = Platform.isAndroid
        ? directoryPath
        : (await getApplicationDocumentsDirectory()).path;

    // Descargar portada con estrategia fija por videoId.
    final coverBytes = await _downloadCover(
      video.id.toString(),
      preferredThumbUrl: preferredThumbUrl,
    );

    onInfoUpdate?.call(video.title, video.author, coverBytes);

    final filePath = '$dir/$safeTitle.$ext';

    await _downloadAudioInParallel(
      url: audio.url,
      filePath: filePath,
      totalSize: audio.size,
      onProgress: (progress) {
        _updateProgress(progress * 0.99);
      },
    );

    if (!await File(filePath).exists()) throw Exception("La descarga falló.");
    await OnAudioQuery().scanMedia(filePath);

    if (usarFFmpeg) {
      // ...
    } else {
      await _procesarAudioSinFFmpeg(
        video.id.toString(),
        filePath,
        video.title,
        video.author,
        video.thumbnails.highResUrl,
        coverBytes ?? Uint8List(0),
        songTitle,
        video.duration ?? Duration.zero,
        url,
      );
    }
  }

  // Método 3: Procesamiento con FFmpeg
  /*
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
      await Future.delayed(const Duration(seconds: 1));
      
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
      _showErrorDialog(
        LocaleProvider.tr('audio_processing_error'),
        e.toString(),
      );
    }
  }
  */

  // Método 4: Procesamiento con AudioTags
  Future<void> _procesarAudioSinFFmpeg(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
    Uint8List bytes,
    String? songTitle,
    Duration duration,
    String downloadUrl,
  ) async {
    _updateState(true, true);

    // final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final m4aPath = inputPath;

    try {
      // Escribir metadatos con audiotags
      final cleanedAuthor = author.replaceFirst(
        RegExp(r' - Topic$', caseSensitive: false),
        '',
      );

      try {
        final tag = Tag(
          title: songTitle,
          trackArtist: cleanedAuthor,
          duration: duration.inSeconds,
          pictures: [
            Picture(
              bytes: bytes,
              mimeType: null,
              pictureType: PictureType.other,
            ),
          ],
        );
        await AudioTags.write(m4aPath, tag);
      } catch (e) {
        await File(m4aPath).delete();
        throw Exception('Error al escribir metadatos');
      }

      // Indexar en Android
      await OnAudioQuery().scanMedia(m4aPath);

      // Guardar en la base de datos de historial en segundo plano
      // usando Future.microtask para no bloquear la UI
      Future.microtask(() async {
        try {
          final file = File(m4aPath);
          final fileSize = await file.length();
          final downloadRecord = DownloadRecord(
            title: songTitle ?? '',
            artist: cleanedAuthor,
            filePath: m4aPath,
            fileName: path.basename(m4aPath),
            fileSize: fileSize,
            downloadUrl: downloadUrl, // URL original de YouTube
            thumbnailUrl: thumbnailUrl,
            downloadDate: DateTime.now(),
            status: 'completed',
          );
          await DownloadHistoryService().insertDownload(downloadRecord);

          // Guardar también en Hive
          await DownloadHistoryHive.addDownload(
            path: m4aPath,
            artist: cleanedAuthor,
            title: songTitle ?? '',
            duration: duration.inSeconds,
            videoId: videoId,
          );

          // Actualizar el notifier para mostrar el badge
          hasNewDownloadsNotifier.value = true;
        } catch (e) {
          // No fallar la descarga si hay error al guardar en DB
          // print('Error al guardar en historial: $e');
        }
      });

      _updateProgress(1.0);
      await Future.delayed(const Duration(seconds: 1));

      await SongsIndexDB().addSong(m4aPath);
      folderUpdatedNotifier.value = path.dirname(m4aPath);
      // foldersShouldReload.value = !foldersShouldReload.value;

      onSuccess?.call(
        songTitle ?? LocaleProvider.tr('download_completed'),
        LocaleProvider.tr('download_completed_desc'),
      );
    } catch (e) {
      onError?.call(LocaleProvider.tr('audio_processing_error'), e.toString());
    }
  }

  // Métodos auxiliares
  Future<Video> _intentarObtenerVideo(
    String url, {
    int maxIntentos = 10,
    YoutubeExplode? ytInstance,
  }) async {
    final yt = ytInstance ?? _getYoutubeExplode();

    for (int intento = 1; intento <= maxIntentos; intento++) {
      try {
        return await yt.videos.get(url);
      } on VideoUnavailableException {
        await Future.delayed(const Duration(seconds: 3));
      } catch (e) {
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
          await response.data!.stream
              .listen(
                (chunk) {
                  bytes.addAll(chunk);
                  synchronized(lock, () {
                    downloaded += chunk.length;
                    onProgress(downloaded / totalSize);
                  });
                },
                onDone: () {},
                onError: (e) => throw Exception('Error en chunk $index: $e'),
              )
              .asFuture();

          raf.setPositionSync(start);
          raf.writeFromSync(bytes);
          break; // Éxito, salimos del while
        } catch (e) {
          if (attempt >= maxRetries) {
            throw Exception(
              'Error permanente en el chunk $index después de $attempt intentos: $e',
            );
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

  Future<Uint8List?> _downloadCover(
    String videoId, {
    String? preferredThumbUrl,
  }) async {
    final coverUrlMax = 'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
    final coverUrlSD = 'https://img.youtube.com/vi/$videoId/sddefault.jpg';
    final coverUrlHQ = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';

    Uint8List? bytes;
    final client = HttpClient();
    try {
      final preferred = preferredThumbUrl?.trim();
      if (preferred != null && preferred.isNotEmpty) {
        try {
          final preferredUri = Uri.tryParse(preferred);
          File? preferredFile;

          if (preferredUri != null && preferredUri.scheme == 'file') {
            preferredFile = File(preferredUri.toFilePath());
          } else if (preferredUri == null || preferredUri.scheme.isEmpty) {
            preferredFile = File(preferred);
          }

          if (preferredFile != null && await preferredFile.exists()) {
            final localBytes = await preferredFile.readAsBytes();
            if (localBytes.isNotEmpty) {
              return localBytes;
            }
          }
        } catch (_) {
          // Si falla lectura local, continuar con descarga remota.
        }
      }

      final urlsToTry = <String>[];
      void addCandidate(String? url) {
        final value = url?.trim();
        if (value == null || value.isEmpty) return;
        if (!urlsToTry.contains(value)) {
          urlsToTry.add(value);
        }
      }

      // Igual que streaming: priorizar miniatura preferida si existe.
      addCandidate(preferredThumbUrl);
      addCandidate(coverUrlMax);
      addCandidate(coverUrlSD);
      addCandidate(coverUrlHQ);

      // Intento principal con HttpClient (más rápido / streaming)
      try {
        for (final url in urlsToTry) {
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close();
          if (response.statusCode == 200) {
            bytes = Uint8List.fromList(
              await _consolidateResponseBytes(response),
            );
            break;
          }
        }
      } catch (_) {
        // Ignorar y pasar a fallback http
      }

      // Fallback con package:http si HttpClient falló
      if (bytes == null) {
        for (final url in urlsToTry) {
          final httpResponse = await http.get(Uri.parse(url));
          if (httpResponse.statusCode == 200) {
            bytes = httpResponse.bodyBytes;
            break;
          }
        }
      }

      if (bytes == null) {
        throw Exception('No se pudo descargar ninguna portada');
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

  /*
  String _limpiarMetadato(String texto) {
    return texto
        .replaceAll('"', '\\"') // Escapar comillas dobles
        .replaceAll(RegExp(r'[\n\r]'), ' ') // Quitar saltos de línea
        .replaceAll(RegExp(r'[&;|<>$]'), '') // Quitar símbolos peligrosos
        .trim(); // Eliminar espacios al inicio y fin
  }
  */

  void _updateState(bool isDownloading, bool isProcessing) {
    _isDownloading = isDownloading;
    _isProcessing = isProcessing;
    onStateUpdate?.call(isDownloading, isProcessing);
  }

  // Actualizar progreso con throttling para no saturar la UI
  void _updateProgress(double progress) {
    final now = DateTime.now();
    if (_lastProgressUpdate == null ||
        now.difference(_lastProgressUpdate!) >= _progressUpdateInterval ||
        progress >= 1.0) {
      _lastProgressUpdate = now;
      onProgressUpdate?.call(progress);
    }
  }

  void _showErrorDialog(String title, String message) async {
    final ctx = _dialogContext;
    if (ctx == null) return;
    try {
      // Evitar mostrar diálogo de completado aquí, solo errores
      await showDialog(
        context: ctx,
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
    } catch (_) {
      // Ignorar si el contexto no es válido
    }
  }

  // Método para seleccionar stream de audio según calidad
  AudioStreamInfo? _selectAudioStream(List<AudioStreamInfo> audioStreams) {
    if (audioStreams.isEmpty) return null;

    // Ordenar por bitrate (mayor a menor)
    final sortedStreams = List<AudioStreamInfo>.from(audioStreams)
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    switch (_audioQuality) {
      case 'high':
        // Mejor calidad disponible
        return sortedStreams.first;
      case 'medium':
        // Calidad media - tomar el stream del medio
        final middleIndex = (sortedStreams.length / 2).floor();
        return sortedStreams[middleIndex];
      case 'low':
        // Calidad baja - tomar el stream de menor calidad
        return sortedStreams.last;
      default:
        return sortedStreams.first;
    }
  }

  // Getters para el estado actual
  bool get isDownloading => _isDownloading;
  bool get isProcessing => _isProcessing;
  String? get directoryPath => _directoryPath;
  bool get usarExplode => _usarExplode;
  bool get usarFFmpeg => _usarFFmpeg;
  String get audioQuality => _audioQuality;
}
