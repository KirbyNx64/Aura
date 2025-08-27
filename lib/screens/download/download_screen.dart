import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
// import 'package:android_intent_plus/android_intent.dart';
// import 'package:android_intent_plus/flag.dart';
// import 'package:package_info_plus/package_info_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
// import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:music/screens/download/stream_provider.dart';
import 'package:audiotags/audiotags.dart';
// import 'package:path/path.dart' as p;
// import 'package:music/main.dart';
import 'package:image/image.dart' as img;
import 'package:music/l10n/locale_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:music/utils/yt_search/youtube_music_service.dart';

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

  bool _usarExplode = false; // true: Explode, false: Directo
  bool _usarFFmpeg = false; // true: FFmpeg, false: AudioTags

  double _progress = 0.0;
  String? _directoryPath;

  String? _currentTitle;
  String? _currentArtist;
  Uint8List? _currentCoverBytes;

  double _lastBottomInset = 0.0;

  // Nuevas variables para playlists
  bool _isPlaylist = false;
  List<Video> _playlistVideos = [];
  int _currentVideoIndex = 0;
  int _totalVideos = 0;
  int _downloadedVideos = 0;
  String? _playlistTitle;
  bool _isPlaylistDownloading = false;
  
  // Servicio de YouTube Music para manejar playlists grandes
  final YouTubeMusicService _youtubeMusicService = YouTubeMusicService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedDirectory();
    
    // Escuchar cambios en el controlador de URL
    _urlController.addListener(_onUrlChanged);
    // Escuchar cambios en la ruta de descargas
    downloadDirectoryNotifier.addListener(_onDownloadDirectoryChanged);
    downloadTypeNotifier.addListener(_onDownloadTypeChanged);
    // Inicializar valores desde notifiers
    _loadDownloadPrefs();
  }

  void _onUrlChanged() {
    final url = _urlController.text.trim();
    if (url.isEmpty && _isPlaylist) {
      setState(() {
        _isPlaylist = false;
        _playlistVideos = [];
        _currentVideoIndex = 0;
        _totalVideos = 0;
        _downloadedVideos = 0;
        _playlistTitle = null;
        _isPlaylistDownloading = false;
      });
    }
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _focusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    downloadDirectoryNotifier.removeListener(_onDownloadDirectoryChanged);
    downloadTypeNotifier.removeListener(_onDownloadTypeChanged);
    super.dispose();
  }

  void _onDownloadDirectoryChanged() {
    setState(() {
      _directoryPath = downloadDirectoryNotifier.value;
    });
  }
  void _onDownloadTypeChanged() {
    setState(() {
      _usarExplode = downloadTypeNotifier.value;
    });
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
      downloadDirectoryNotifier.value = savedPath;
    }
  }

  Future<void> _loadDownloadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final explode = prefs.getBool('download_type_explode') ?? true;
    _usarExplode = explode;
    _usarFFmpeg = false; // Always use AudioTags (more efficient)
    downloadTypeNotifier.value = explode;
    audioProcessorNotifier.value = false; // Always use AudioTags
    setState(() {});
  }

  // Nuevo método para detectar si es playlist
  bool _isPlaylistUrl(String url) {
    return url.contains('playlist?list=') || 
           url.contains('&list=') ||
           url.contains('youtube.com/playlist');
  }

  // Nuevo método para obtener información de playlist con continuaciones
  Future<void> _fetchPlaylistInfo(String url) async {
    setState(() {
      _isDownloading = true;
      _isPlaylist = true;
      _playlistVideos = [];
      _currentVideoIndex = 0;
      _downloadedVideos = 0;
    });

    final yt = YoutubeExplode();
    try {
      // Extraer playlist ID de la URL
      final playlistId = _extractPlaylistId(url);
      if (playlistId == null) {
        throw Exception('No se pudo extraer el ID de la playlist');
      }

      final playlist = await yt.playlists.get(playlistId);
      setState(() {
        _playlistTitle = playlist.title;
        _totalVideos = playlist.videoCount ?? 0;
      });

      // Obtener videos usando el servicio de YouTube Music (maneja continuaciones)
      List<Video> videos = [];
      
      try {
        // Intentar primero con YouTube Music API
        videos = await _youtubeMusicService.getPlaylistVideosWithContinuations(playlistId, onVideoFound: (video, totalFound) {
          // Actualizar UI en tiempo real cuando se encuentra un video
          if (mounted) {
            setState(() {
              _currentVideoIndex = totalFound;
              _currentTitle = video.title;
              _currentArtist = video.author;
            });
          }
        });
        
        // Actualizar progreso final
        if (mounted) {
          setState(() {
            _currentVideoIndex = videos.length;
          });
        }
        
        // Si no obtuvimos suficientes videos, intentar con YouTube Explode como fallback
        if (videos.length < _totalVideos && _totalVideos > 0) {
          // print('YouTube Music API obtuvo ${videos.length} videos, intentando con YouTube Explode...');
          
          final ytVideos = <Video>[];
          await for (final video in yt.playlists.getVideos(playlistId)) {
            // Evitar duplicados
            if (!videos.any((v) => v.id == video.id)) {
              ytVideos.add(video);
            }
          }
          
          // Combinar videos únicos
          videos.addAll(ytVideos);
          
          if (mounted) {
            setState(() {
              _currentVideoIndex = videos.length;
            });
          }
        }
        
      } catch (e) {
        // print(' 👻 Error con YouTube Music API, usando solo YouTube Explode: $e');
        
        // Fallback completo a YouTube Explode
        await for (final video in yt.playlists.getVideos(playlistId)) {
          videos.add(video);
          
          if (mounted) {
            setState(() {
              _currentVideoIndex = videos.length;
            });
          }
        }
      }
      
      setState(() {
        _playlistVideos = videos;
        _currentVideoIndex = 0; // Reset para descarga
      });

      if (videos.isEmpty) {
        throw Exception('No se encontraron videos en la playlist');
      }

      // Mostrar información sobre el resultado
      if (mounted) {
        if (_totalVideos > 0 && videos.length < _totalVideos) {
          // Si no se obtuvieron todos los videos, mostrar advertencia
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(LocaleProvider.tr('playlist_partial_fetch')),
              content: Text(
                '${LocaleProvider.tr('playlist_partial_fetch_desc')}\n\n'
                '${LocaleProvider.tr('videos_found')}: ${videos.length}\n'
                '${LocaleProvider.tr('total_videos')}: $_totalVideos\n\n'
                '${LocaleProvider.tr('will_download_available')}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(LocaleProvider.tr('continue_anyway')),
                ),
              ],
            ),
          );
        } else if (videos.length > 100) {
          // Mostrar confirmación para playlists grandes
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(LocaleProvider.tr('large_playlist_confirmation')),
              content: Text(
                '${LocaleProvider.tr('large_playlist_confirmation_desc')}\n\n'
                '${LocaleProvider.tr('videos_found')}: ${videos.length}\n'
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(LocaleProvider.tr('continue_anyway')),
                ),
              ],
            ),
          );
        }
      }

    } catch (e) {
      setState(() {
        _isDownloading = false;
        _isPlaylist = false;
      });
      _mostrarAlerta(
        titulo: 'Error al obtener playlist',
        mensaje: '${LocaleProvider.tr('playlist_error_desc')}: ${e.toString()}',
      );
    } finally {
      yt.close();
    }
  }

  // Método para extraer playlist ID
  String? _extractPlaylistId(String url) {
    final uri = Uri.parse(url);
    return uri.queryParameters['list'];
  }

  // Nuevo método para descargar playlist completa
  Future<void> _downloadPlaylist() async {
    if (_playlistVideos.isEmpty) return;

    setState(() {
      _isPlaylistDownloading = true;
      _downloadedVideos = 0;
    });

    try {
      for (int i = 0; i < _playlistVideos.length; i++) {
        final video = _playlistVideos[i];
        
        setState(() {
          _currentVideoIndex = i + 1;
          _currentTitle = video.title;
          _currentArtist = video.author;
          _progress = 0.0;
        });

        try {
          // Descargar video individual usando el método seleccionado
          if (_usarExplode) {
            await _downloadSingleVideoFromPlaylistExplode(video);
          } else {
            await _downloadSingleVideoFromPlaylistDirect(video);
          }
          
          setState(() {
            _downloadedVideos++;
          });

          // Pequeña pausa entre descargas
          await Future.delayed(const Duration(seconds: 1));
          
        } catch (e) {
          // Continuar con el siguiente video si falla uno
          // print('Error descargando video ${video.title}: $e');
          continue;
        }
      }

      // Playlist completada
      setState(() {
        _progress = 1.0;
      });

      await Future.delayed(const Duration(seconds: 1));
      foldersShouldReload.value = !foldersShouldReload.value;

      // Guardar valores antes de resetear
      final downloadedCount = _downloadedVideos;
      final totalCount = _totalVideos;

      if (mounted) {
        _urlController.clear();
        _focusNode.unfocus();
        _mostrarAlerta(
          titulo: LocaleProvider.tr('playlist_completed'),
          mensaje: '${LocaleProvider.tr('playlist_completed_desc')} $downloadedCount ${LocaleProvider.tr('of')} $totalCount ${LocaleProvider.tr('videos_found')}.',
        );
      }

    } catch (e) {
      _mostrarAlerta(
        titulo: LocaleProvider.tr('playlist_error_download'),
        mensaje: '${LocaleProvider.tr('playlist_error_download_desc')}: ${e.toString()}',
      );
    } finally {
      setState(() {
        _isPlaylistDownloading = false;
        _isDownloading = false;
        _isPlaylist = false;
        _playlistVideos = [];
        _currentCoverBytes = null;
      });
    }
  }

  // Método para descargar un video individual de la playlist usando Explode
  Future<void> _downloadSingleVideoFromPlaylistExplode(Video video) async {
    final yt = YoutubeExplode();
    try {
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
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;
      final filePath = '$saveDir/$safeTitle.m4a';

      // Descargar portada
      final coverUrlMax = 'https://img.youtube.com/vi/${video.id}/maxresdefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/${video.id}/hqdefault.jpg';

      Uint8List? bytes;
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(coverUrlMax));
        final response = await request.close();
        if (response.statusCode == 200) {
          bytes = Uint8List.fromList(await consolidateResponseBytes(response));
        } else {
          final requestHQ = await client.getUrl(Uri.parse(coverUrlHQ));
          final responseHQ = await requestHQ.close();
          if (responseHQ.statusCode == 200) {
            bytes = Uint8List.fromList(await consolidateResponseBytes(responseHQ));
          } else {
            final httpResponse = await http.get(Uri.parse(video.thumbnails.highResUrl));
            if (httpResponse.statusCode == 200) {
              bytes = httpResponse.bodyBytes;
            }
          }
        }
        
        if (bytes != null) {
          final original = img.decodeImage(bytes);
          if (original != null) {
            final minSide = original.width < original.height ? original.width : original.height;
            final offsetX = (original.width - minSide) ~/ 2;
            final offsetY = (original.height - minSide) ~/ 2;
            final square = img.copyCrop(original, x: offsetX, y: offsetY, width: minSide, height: minSide);
            bytes = img.encodeJpg(square);
          }
        }
      } finally {
        client.close();
      }

      setState(() {
        _currentCoverBytes = bytes;
      });

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

      // Procesar audio
      if (_usarFFmpeg) {
        /*
        await _procesarAudio(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes ?? Uint8List(0),
          isPlaylistDownload: true,
        );
        */
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes ?? Uint8List(0),
          isPlaylistDownload: true,
        );
      }

    } catch (e) {
      throw Exception('Error descargando ${video.title}: $e');
    } finally {
      yt.close();
    }
  }

  // Método para descargar un video individual de la playlist usando Directo
  Future<void> _downloadSingleVideoFromPlaylistDirect(Video video) async {
    try {
      // Extraer videoId
      final videoId = video.id.toString();

      // Reintento para obtener video + manifest
      late StreamManifest manifest;

      for (int intento = 1; intento <= 1; intento++) {
        final yt = YoutubeExplode();
        try {
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
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;

      final coverUrlMax = 'https://img.youtube.com/vi/${video.id}/maxresdefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/${video.id}/hqdefault.jpg';

      Uint8List? bytes;
      final client = HttpClient();
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
            bytes = Uint8List.fromList(await consolidateResponseBytes(responseHQ));
          } else {
            // 3. Fallback: usar thumbnailUrl con http
            final httpResponse = await http.get(Uri.parse(video.thumbnails.highResUrl));
            if (httpResponse.statusCode == 200) {
              bytes = httpResponse.bodyBytes;
            } else {
              throw Exception('No se pudo descargar ninguna portada');
            }
          }
        }
        // Recortar a cuadrado centrado
        final original = img.decodeImage(bytes);
        if (original != null) {
          final minSide = original.width < original.height ? original.width : original.height;
          final offsetX = (original.width - minSide) ~/ 2;
          final offsetY = (original.height - minSide) ~/ 2;
          final square = img.copyCrop(original, x: offsetX, y: offsetY, width: minSide, height: minSide);
          bytes = img.encodeJpg(square);
        }
      } finally {
        client.close();
      }

      setState(() {
        _currentCoverBytes = bytes;
      });

      final filePath = '$dir/$safeTitle.$ext';

      await downloadAudioInParallel(
        url: audio.url,
        filePath: filePath,
        totalSize: audio.size,
        onProgress: (progress) {
          setState(() => _progress = progress * 0.6);
        },
      );

      if (!await File(filePath).exists()) throw Exception("La descarga falló.");
      MediaScanner.loadMedia(path: filePath);

      if (_usarFFmpeg) {
        /*
        await _procesarAudio(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
          isPlaylistDownload: true,
        );
        */
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
          isPlaylistDownload: true,
        );
      }
    } catch (e) {
      throw Exception('Error descargando ${video.title}: $e');
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
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: TranslatedText('info'),
          content: Text(LocaleProvider.tr('android_9_or_lower')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: TranslatedText('ok'),
            ),
          ],
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
            title: Text(LocaleProvider.tr('folder_not_selected')),
            content: Text(LocaleProvider.tr('folder_not_selected_desc')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('download_accept')),
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
      _currentTitle = null;
      _currentArtist = null;
    });

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
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;
      final filePath = '$saveDir/$safeTitle.m4a';

      final coverUrlMax = 'https://img.youtube.com/vi/${video.id}/maxresdefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/${video.id}/hqdefault.jpg';

      Uint8List? bytes;
      final client = HttpClient();
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
            bytes = Uint8List.fromList(await consolidateResponseBytes(responseHQ));
          } else {
            // 3. Fallback: usar thumbnailUrl con http
            final httpResponse = await http.get(Uri.parse(video.thumbnails.highResUrl));
            if (httpResponse.statusCode == 200) {
              bytes = httpResponse.bodyBytes;
            } else {
              throw Exception('No se pudo descargar ninguna portada');
            }
          }
        }
        // Recortar a cuadrado centrado
        final original = img.decodeImage(bytes);
        if (original != null) {
          final minSide = original.width < original.height ? original.width : original.height;
          final offsetX = (original.width - minSide) ~/ 2;
          final offsetY = (original.height - minSide) ~/ 2;
          final square = img.copyCrop(original, x: offsetX, y: offsetY, width: minSide, height: minSide);
          bytes = img.encodeJpg(square);
        }
      } finally {
        client.close();
      }

      setState(() {
        _currentTitle = video.title;
        _currentArtist = video.author;
        _currentCoverBytes = bytes;
      });

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

      if (_usarFFmpeg) {
        /*
        await _procesarAudio(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
        );
        */
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
        );
      }
    } on VideoUnavailableException {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('video_unavailable')),
            content: Text(LocaleProvider.tr('video_unavailable_desc')),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _urlController.clear();
                  _focusNode.unfocus();
                },
                child: Text(LocaleProvider.tr('ok')),
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
            title: Text(LocaleProvider.tr('download_failed_title')),
            content: Text(
              '${LocaleProvider.tr('download_failed_desc')}\n\n'
              'Detalles: ${e.toString()}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('ok')),
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
          _currentCoverBytes = null;
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

    Future<void> downloadAudioInParallel({
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
      _currentTitle = null;
      _currentArtist = null;
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
      final audio = streamProvider.highestBitrateMp4aAudio;

      if (audio == null) {
        throw Exception('No se encontró stream de audio válido.');
      }

      final ext = 'm4a';
      final safeTitle = video.title
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
          .trim();

      final dir = Platform.isAndroid
          ? _directoryPath!
          : (await getApplicationDocumentsDirectory()).path;

      final coverUrlMax = 'https://img.youtube.com/vi/${video.id}/maxresdefault.jpg';
      final coverUrlHQ = 'https://img.youtube.com/vi/${video.id}/hqdefault.jpg';

      Uint8List? bytes;
      final client = HttpClient();
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
            bytes = Uint8List.fromList(await consolidateResponseBytes(responseHQ));
          } else {
            // 3. Fallback: usar thumbnailUrl con http
            final httpResponse = await http.get(Uri.parse(video.thumbnails.highResUrl));
            if (httpResponse.statusCode == 200) {
              bytes = httpResponse.bodyBytes;
            } else {
              throw Exception('No se pudo descargar ninguna portada');
            }
          }
        }
        // Recortar a cuadrado centrado
        final original = img.decodeImage(bytes);
        if (original != null) {
          final minSide = original.width < original.height ? original.width : original.height;
          final offsetX = (original.width - minSide) ~/ 2;
          final offsetY = (original.height - minSide) ~/ 2;
          final square = img.copyCrop(original, x: offsetX, y: offsetY, width: minSide, height: minSide);
          bytes = img.encodeJpg(square);
        }
      } finally {
        client.close();
      }

      setState(() {
        _currentTitle = video.title;
        _currentArtist = video.author;
        _currentCoverBytes = bytes;
      });

      final filePath = '$dir/$safeTitle.$ext';

      await downloadAudioInParallel(
        url: audio.url,
        filePath: filePath,
        totalSize: audio.size,
        onProgress: (progress) {
          setState(() => _progress = progress * 0.6);
        },
      );

      if (!await File(filePath).exists()) throw Exception("La descarga falló.");
      MediaScanner.loadMedia(path: filePath);

      if (_usarFFmpeg) {
        /*
        await _procesarAudio(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
        );
        */
      } else {
        await _procesarAudioSinFFmpeg(
          video.id.toString(),
          filePath,
          video.title,
          video.author,
          video.thumbnails.highResUrl,
          bytes,
        );
      }
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
            child: Text(LocaleProvider.tr('ok')),
          ),
        ],
      ),
    );
  }

  /*
  Future<void> _procesarAudio(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
    Uint8List coverBytes, {
    bool isPlaylistDownload = false,
  }) async {
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
    await File(coverPath).writeAsBytes(coverBytes);

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
          audioHandler?.mediaItem.value; // O usa handler.mediaItem.value
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
              title: Text(LocaleProvider.tr('file_in_use')),
              content: Text(LocaleProvider.tr('file_in_use_desc')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(LocaleProvider.tr('ok')),
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
      await Future.delayed(const Duration(seconds: 1));
      
      // Solo actualizar folders si no es descarga de playlist
      if (!isPlaylistDownload) {
        foldersShouldReload.value = !foldersShouldReload.value;
      }

      if (mounted && !_isPlaylistDownloading) {
        _urlController.clear();
        _focusNode.unfocus();
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('audio_processing_error')),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('ok')),
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
          _currentCoverBytes = null;
        });
      }
    }
  }
  */

  Future<void> _procesarAudioSinFFmpeg(
    String videoId,
    String inputPath,
    String title,
    String author,
    String thumbnailUrl,
    Uint8List bytes, {
    bool isPlaylistDownload = false,
  }) async {
    setState(() {
      _isProcessing = true;
    });

    final baseName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final m4aPath = inputPath;

    try {
      // Escribir metadatos con audiotags
      setState(() => _progress = 0.75);

      final cleanedAuthor = limpiarMetadato(
        author.replaceFirst(RegExp(r' - Topic$', caseSensitive: false), ''),
      );
      final safeTitle = limpiarMetadato(baseName);

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

      setState(() => _progress = 1.0);
      await Future.delayed(const Duration(seconds: 1));
      // Solo actualizar folders si no es descarga de playlist
      if (!isPlaylistDownload) {
        foldersShouldReload.value = !foldersShouldReload.value;
      }

      if (mounted && !_isPlaylistDownloading) {
        _urlController.clear();
        _focusNode.unfocus();
      }
    } catch (e) {
      // print('👻 Error al procesar audio sin FFmpeg: $e');
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(LocaleProvider.tr('audio_processing_error')),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(LocaleProvider.tr('ok')),
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
          _currentCoverBytes = null;
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
            Icon(Icons.download_outlined, size: 28),
            const SizedBox(width: 8),
            TranslatedText('download'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.downloading, size: 28),
            tooltip: LocaleProvider.tr('recommend_seal'),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(LocaleProvider.tr('want_more_options')),
                  content: Text(LocaleProvider.tr('seal_recommendation')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(LocaleProvider.tr('cancel')),
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
                            SnackBar(
                              content: Text(LocaleProvider.tr('browser_open_error')),
                            ),
                          );
                        }
                      },
                      child: Text(LocaleProvider.tr('open')),
                    ),
                  ],
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.help_outline, size: 28),
            tooltip: LocaleProvider.tr('what_means_each_option'),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(LocaleProvider.tr('what_means_each_option')),
                  content: SizedBox(
                    width: double.maxFinite,
                    // Limita el alto para que el scroll funcione
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            LocaleProvider.tr('download_method_title'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(LocaleProvider.tr('download_method_desc')),
                          /*
                          const SizedBox(height: 16),
                          Text(
                            LocaleProvider.tr('audio_processing_title'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(LocaleProvider.tr('audio_processing_desc')),
                          */
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(LocaleProvider.tr('download_understood_2')),
                    ),
                  ],
                ),
              );
            },
          ),

          IconButton(
            icon: const Icon(Icons.info_outline, size: 28),
            tooltip: LocaleProvider.tr('download_info_title'),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(LocaleProvider.tr('download_info_title')),
                  content: Text(
                    '${LocaleProvider.tr('download_info_desc')}\n\n'
                    '${LocaleProvider.tr('download_works_with')}\n\n'
                    '${LocaleProvider.tr('download_not_works_with')}\n\n'
                    '${LocaleProvider.tr('download_may_fail')}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(LocaleProvider.tr('download_understood_2')),
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
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _focusNode,
                      decoration: InputDecoration(
                        labelText: LocaleProvider.tr('youtube_link'),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(
                            Radius.circular(8),
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
                      color: (_isDownloading || _isPlaylistDownloading)
                          ? Theme.of(context).colorScheme.surfaceContainer
                          : Theme.of(context).colorScheme.secondaryContainer,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: (_isDownloading || _isPlaylistDownloading) 
                            ? null 
                            : () async {
                                final data = await Clipboard.getData('text/plain');
                                if (data != null && data.text != null) {
                                  setState(() {
                                    _urlController.text = data.text!;
                                  });
                                }
                              },
                        child: Tooltip(
                          message: LocaleProvider.tr('paste_link'),
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
                                                  onTap: (_isDownloading || _isPlaylistDownloading)
                            ? null
                            : () async {
                                // Verificar conexión a internet antes de descargar
                                final List<ConnectivityResult> connectivityResult = await Connectivity().checkConnectivity();
                                if (connectivityResult.contains(ConnectivityResult.none)) {
                                  if (context.mounted) {
                                    showDialog(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(LocaleProvider.tr('error')),
                                        content: Text(LocaleProvider.tr('no_internet_connection')),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(context).pop(),
                                            child: Text(LocaleProvider.tr('ok')),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return;
                                }
                                final url = _urlController.text.trim();
                                if (url.isEmpty) return;

                                if (Platform.isAndroid && _directoryPath == null ||
                                    _directoryPath!.isEmpty) {
                                  _mostrarAlerta(
                                    titulo: LocaleProvider.tr('folder_not_selected'),
                                    mensaje: LocaleProvider.tr('folder_not_selected_desc'),
                                  );
                                  return;
                                }

                                // Detectar si es playlist
                                if (_isPlaylistUrl(url)) {
                                  await _fetchPlaylistInfo(url);
                                } else {
                                  // Descarga de video individual
                                  if (_usarExplode) {
                                    _downloadAudioOnlyExplode();
                                  } else {
                                    _downloadAudioOnly();
                                  }
                                }
                              },
                                                  child: Center(
                          child: DefaultTextStyle(
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            child: (_isDownloading || _isPlaylistDownloading)
                                ? (_isProcessing
                                      ? TranslatedText('processing_audio')
                                      : (_isPlaylist 
                                          ? TranslatedText('downloading_playlist')
                                          : Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                TranslatedText('downloading'),
                                                Text(' ${((_progress / 0.6).clamp(0, 1) * 100).toStringAsFixed(0)}%'),
                                              ],
                                            )))
                                : TranslatedText('download_audio'),
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
                      color: (_isDownloading || _isPlaylistDownloading)
                          ? Theme.of(context).colorScheme.surfaceContainer
                          : Theme.of(context).colorScheme.secondaryContainer,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: (_isDownloading || _isPlaylistDownloading) ? null : _pickDirectory,
                        child: Tooltip(
                          message: _directoryPath == null
                              ? LocaleProvider.tr('choose_folder')
                              : LocaleProvider.tr('folder_ready'),
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
              if (_isDownloading && !_isPlaylist)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha((0.05 * 255).toInt()),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Carátula a la izquierda
                        if (_currentCoverBytes != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              _currentCoverBytes!,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                            ),
                          ),
                        if (_currentCoverBytes != null)
                          const SizedBox(width: 16),
                        // Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_currentTitle != null && _currentArtist != null) ...[
                                Text(
                                  _currentTitle!,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _currentArtist!.replaceFirst(RegExp(r' - Topic$'), ''),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 14,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ] else ...[
                                TranslatedText(
                                  'getting_info',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      year2023: false,
                      value: _progress,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ),
              // Nuevo: UI para obtención de información de playlist
              if (_isPlaylist && _isDownloading && _playlistVideos.isEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha((0.05 * 255).toInt()),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.playlist_play,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TranslatedText(
                            'fetching_playlist_info',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TranslatedText(
                          'videos_found_so_far',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          ': $_currentVideoIndex',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        if (_totalVideos > 0) ...[
                          Text(
                            ' / $_totalVideos',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_currentTitle != null) ...[
                      Text(
                        _currentTitle!,
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_currentArtist != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _currentArtist!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 8),
                    ],
                    LinearProgressIndicator(
                      year2023: false,
                      value: _totalVideos > 0 ? (_currentVideoIndex / _totalVideos).clamp(0.0, 1.0) : null,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ),
              // Nuevo: UI para playlist detectada
              if (_isPlaylist && _playlistVideos.isNotEmpty && !_isPlaylistDownloading)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withAlpha(25),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withAlpha(76),
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.playlist_play,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _playlistTitle != null
                              ? Text(
                                  _playlistTitle!,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                )
                              : TranslatedText(
                                  'playlist_detected',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          '$_totalVideos ',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        TranslatedText(
                          'videos_found',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              setState(() {
                                _isPlaylist = false;
                                _playlistVideos = [];
                                _currentVideoIndex = 0;
                                _totalVideos = 0;
                                _downloadedVideos = 0;
                                _playlistTitle = null;
                                _isPlaylistDownloading = false;
                                _isDownloading = false;
                              });
                            },
                            icon: const Icon(Icons.cancel),
                            label: TranslatedText('cancel'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade400,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _downloadPlaylist,
                            icon: const Icon(Icons.download),
                            label: TranslatedText('download_complete_playlist'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Nuevo: UI para progreso de playlist
              if (_isPlaylistDownloading)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha((0.05 * 255).toInt()),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.playlist_play,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _playlistTitle != null
                              ? Text(
                                  _playlistTitle!,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                  overflow: TextOverflow.ellipsis,
                                )
                              : TranslatedText(
                                  'playlist_detected',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TranslatedText(
                          'video_of',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          ' $_currentVideoIndex ',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        TranslatedText(
                          'of',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          ' $_totalVideos',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        TranslatedText(
                          'downloaded',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          ': $_downloadedVideos',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_currentTitle != null) ...[
                      Text(
                        _currentTitle!,
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                    ],
                    LinearProgressIndicator(
                      year2023: false,
                      value: _progress,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.folder,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _directoryPath != null
                        ? Text(
                            _directoryPath!.replaceFirst('/storage/emulated/0', ''),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          )
                        : (Platform.isAndroid
                            ? TranslatedText(
                                'not_selected_folder',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              )
                            : TranslatedText(
                                'app_documents',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              )),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
