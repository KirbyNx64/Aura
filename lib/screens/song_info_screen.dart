import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_audio_toolkit/flutter_audio_toolkit.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:flutter/services.dart';
import 'package:music/widgets/artwork_list_tile.dart';

import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/encoding_utils.dart';
import 'package:music/utils/db/download_history_hive.dart';
import 'package:music/utils/db/download_history_model.dart';
import 'package:music/utils/db/favorites_db.dart';
import 'package:music/utils/db/playlists_db.dart';
import 'package:music/utils/db/recent_db.dart';

import 'package:share_plus/share_plus.dart';

class _StreamingMetadata {
  final DownloadHistoryModel? history;
  final String? videoId;
  final int? durationMs;
  final String? durationText;

  const _StreamingMetadata({
    this.history,
    this.videoId,
    this.durationMs,
    this.durationText,
  });
}

class SongInfoScreen extends StatefulWidget {
  final MediaItem mediaItem;

  const SongInfoScreen({super.key, required this.mediaItem});

  @override
  State<SongInfoScreen> createState() => _SongInfoScreenState();
}

class _SongInfoScreenState extends State<SongInfoScreen> {
  final FlutterAudioToolkit _audioToolkit = FlutterAudioToolkit();
  AudioInfo? _audioInfo;
  DownloadHistoryModel? _downloadHistory;
  bool _isStreaming = false;
  String? _videoId;
  int? _streamDurationMs;
  String? _streamDurationText;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadAudioInfo();
  }

  Future<void> _shareMedia() async {
    try {
      if (_isStreaming || _isStreamingMediaItem()) {
        final youtubeUrl = _streamingYoutubeUrl();
        if (youtubeUrl == null) return;
        await SharePlus.instance.share(
          ShareParams(
            text: youtubeUrl,
            subject: fixUtf8Mojibake(widget.mediaItem.title),
          ),
        );
        return;
      }

      final filePath = _mediaPath();
      if (filePath.isEmpty || !_isLikelyLocalPath(filePath)) return;
      await SharePlus.instance.share(
        ShareParams(
          text: fixUtf8Mojibake(widget.mediaItem.title),
          files: [XFile(filePath)],
        ),
      );
    } catch (_) {
      // Ignorar errores de compartido.
    }
  }

  Future<void> _loadAudioInfo() async {
    final filePath = _mediaPath();
    final isStreaming = _isStreamingMediaItem();

    try {
      if (isStreaming) {
        final metadata = await _resolveStreamingMetadata(filePath);
        if (!mounted) return;
        setState(() {
          _isStreaming = true;
          _downloadHistory = metadata.history;
          _videoId = metadata.videoId;
          _streamDurationMs = metadata.durationMs;
          _streamDurationText = metadata.durationText;
          _isLoading = false;
        });
        return;
      }

      if (filePath.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      final info = await _audioToolkit.getAudioInfo(filePath);
      final extraVideoId = _normalizeText(widget.mediaItem.extras?['videoId']);
      final historyByPath = await DownloadHistoryHive.getDownloadByPath(
        filePath,
      );
      final historyByVideoId = extraVideoId != null
          ? await DownloadHistoryHive.getDownloadByVideoId(extraVideoId)
          : null;
      final history = historyByPath ?? historyByVideoId;

      if (mounted) {
        setState(() {
          _isStreaming = false;
          _audioInfo = info;
          _downloadHistory = history;
          _videoId = _firstNonEmpty([extraVideoId, history?.videoId]);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<_StreamingMetadata> _resolveStreamingMetadata(String rawPath) async {
    final path = rawPath.trim();
    final extraVideoId = _normalizeText(widget.mediaItem.extras?['videoId']);
    final pathVideoId = _extractVideoIdFromPath(path);
    final mediaIdVideoId = _extractVideoIdFromPath(widget.mediaItem.id);
    final initialVideoId = _firstNonEmpty([
      extraVideoId,
      pathVideoId,
      mediaIdVideoId,
    ]);
    final preferredPlaylistId = _normalizeText(
      widget.mediaItem.extras?['playlistId'],
    );
    final canonicalPath = (initialVideoId != null && initialVideoId.isNotEmpty)
        ? 'yt:$initialVideoId'
        : null;

    final favoritesMetaByPath = path.isNotEmpty
        ? await FavoritesDB().getFavoriteMeta(path)
        : null;
    final recentsMetaByPath = path.isNotEmpty
        ? await RecentsDB().getRecentMeta(path)
        : null;
    final favoritesMetaByCanonical =
        (canonicalPath != null &&
            canonicalPath.isNotEmpty &&
            canonicalPath != path)
        ? await FavoritesDB().getFavoriteMeta(canonicalPath)
        : null;
    final recentsMetaByCanonical =
        (canonicalPath != null &&
            canonicalPath.isNotEmpty &&
            canonicalPath != path)
        ? await RecentsDB().getRecentMeta(canonicalPath)
        : null;
    final playlistMeta = await _findPlaylistMetaForPathOrVideo(
      path: path,
      fallbackPath: canonicalPath,
      videoId: initialVideoId,
      preferredPlaylistId: preferredPlaylistId,
    );

    final resolvedVideoId = _firstNonEmpty([
      initialVideoId,
      favoritesMetaByPath?['videoId']?.toString(),
      recentsMetaByPath?['videoId']?.toString(),
      favoritesMetaByCanonical?['videoId']?.toString(),
      recentsMetaByCanonical?['videoId']?.toString(),
      playlistMeta?['videoId']?.toString(),
    ]);

    final historyByPath = path.isNotEmpty
        ? await DownloadHistoryHive.getDownloadByPath(path)
        : null;
    final historyByVideoId =
        (resolvedVideoId != null && resolvedVideoId.isNotEmpty)
        ? await DownloadHistoryHive.getDownloadByVideoId(resolvedVideoId)
        : null;
    final history = historyByPath ?? historyByVideoId;

    final metas = <Map<String, dynamic>?>[
      playlistMeta,
      favoritesMetaByPath,
      recentsMetaByPath,
      favoritesMetaByCanonical,
      recentsMetaByCanonical,
    ];

    String? durationText;
    int? durationMs;
    for (final meta in metas) {
      if (meta == null) continue;
      durationText ??= _normalizeText(meta['durationText']);
      durationMs ??=
          _parsePositiveInt(meta['durationMs']) ??
          _parseDurationTextToMs(_normalizeText(meta['durationText']));
      if (durationMs != null && durationMs > 0 && durationText != null) {
        break;
      }
    }

    final historyDurationMs = (history != null && history.duration > 0)
        ? history.duration * 1000
        : null;
    durationMs ??= historyDurationMs;
    durationMs ??= _durationMsFromMediaItem(widget.mediaItem);
    durationText ??= _durationTextFromMediaItem(widget.mediaItem);
    if ((durationText == null || durationText.isEmpty) &&
        durationMs != null &&
        durationMs > 0) {
      durationText = _formatDuration(durationMs);
    }

    return _StreamingMetadata(
      history: history,
      videoId: _firstNonEmpty([resolvedVideoId, history?.videoId]),
      durationMs: durationMs,
      durationText: durationText,
    );
  }

  Future<Map<String, dynamic>?> _findPlaylistMetaForPathOrVideo({
    required String path,
    String? fallbackPath,
    String? videoId,
    String? preferredPlaylistId,
  }) async {
    final db = PlaylistsDB();
    final normalizedPath = path.trim();
    final normalizedFallbackPath = fallbackPath?.trim();
    final normalizedVideoId = videoId?.trim();

    final candidatePaths = <String>{
      if (normalizedPath.isNotEmpty) normalizedPath,
      if (normalizedFallbackPath != null && normalizedFallbackPath.isNotEmpty)
        normalizedFallbackPath,
    };

    final preferredId = preferredPlaylistId?.trim();
    if (preferredId != null && preferredId.isNotEmpty) {
      for (final candidatePath in candidatePaths) {
        final direct = await db.getPlaylistSongMeta(preferredId, candidatePath);
        if (direct != null) return direct;
      }
    }

    final mb = await db.metaBox;
    for (final candidatePath in candidatePaths) {
      final suffix = '::$candidatePath';
      for (final key in mb.keys) {
        if (key is! String || !key.endsWith(suffix)) continue;
        final raw = mb.get(key);
        if (raw is Map) {
          return Map<String, dynamic>.from(raw);
        }
      }
    }

    if (normalizedVideoId != null && normalizedVideoId.isNotEmpty) {
      for (final key in mb.keys) {
        final raw = mb.get(key);
        if (raw is! Map) continue;
        final meta = Map<String, dynamic>.from(raw);
        final metaVideoId = _normalizeText(meta['videoId']);
        if (metaVideoId == normalizedVideoId) {
          return meta;
        }
      }
    }

    return null;
  }

  String _displayText(String? value, String fallback) {
    final s = fixUtf8Mojibake(value ?? '');
    return s.trim().isEmpty ? fallback : s;
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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

  String _getAudioFormat(String filePath) {
    if (filePath.isEmpty) return 'N/A';
    final extension = filePath.split('.').last.toLowerCase();
    return extension.toUpperCase();
  }

  String _cleanFilePath(String filePath) {
    if (filePath.isEmpty) return 'N/A';
    return filePath.replaceFirst('/storage/emulated/0', '');
  }

  String _mediaPath() {
    final fromExtras = _normalizeText(widget.mediaItem.extras?['data']);
    if (fromExtras != null) return fromExtras;
    return widget.mediaItem.id.trim();
  }

  bool _isLikelyLocalPath(String path) {
    final normalized = path.trim().toLowerCase();
    if (path.startsWith('/')) return true;
    if (normalized.startsWith('file://')) return true;
    if (normalized.startsWith('content://')) return true;
    if (RegExp(r'^[a-zA-Z]:\\').hasMatch(path)) return true;
    return false;
  }

  bool _isStreamingMediaItem() {
    if (widget.mediaItem.extras?['isStreaming'] == true) return true;

    final mediaId = widget.mediaItem.id.trim();
    if (mediaId.startsWith('yt:') || mediaId.startsWith('yt_stream_')) {
      return true;
    }

    final path = _mediaPath();
    if (path.isEmpty) return false;
    if (path.startsWith('yt:')) return true;
    return !_isLikelyLocalPath(path);
  }

  String? _normalizeText(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text.toLowerCase() == 'null') {
      return null;
    }
    return text;
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  int? _parsePositiveInt(dynamic raw) {
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw > 0) return raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  int? _parseDurationTextToMs(String? durationText) {
    final text = durationText?.trim();
    if (text == null || text.isEmpty) return null;

    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;

    final values = <int>[];
    for (final part in parts) {
      final parsed = int.tryParse(part.trim());
      if (parsed == null || parsed < 0) return null;
      values.add(parsed);
    }

    int totalSeconds = 0;
    if (values.length == 2) {
      totalSeconds = (values[0] * 60) + values[1];
    } else {
      totalSeconds = (values[0] * 3600) + (values[1] * 60) + values[2];
    }

    if (totalSeconds <= 0) return null;
    return totalSeconds * 1000;
  }

  String? _extractVideoIdFromPath(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return null;

    if (path.startsWith('yt:')) {
      final id = path.substring(3).trim();
      return id.isEmpty ? null : id;
    }

    final uri = Uri.tryParse(path);
    if (uri != null) {
      final queryVideoId = uri.queryParameters['v']?.trim();
      if (queryVideoId != null && queryVideoId.isNotEmpty) {
        return queryVideoId;
      }
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        final shortId = uri.pathSegments.first.trim();
        if (shortId.isNotEmpty) {
          return shortId;
        }
      }
    }

    final idLike = RegExp(r'^[a-zA-Z0-9_-]{11}$');
    if (idLike.hasMatch(path)) {
      return path;
    }

    return null;
  }

  String? _streamingYoutubeUrl() {
    final videoId = _firstNonEmpty([
      _normalizeText(_videoId),
      _extractVideoIdFromPath(_mediaPath()),
      _extractVideoIdFromPath(widget.mediaItem.id),
    ]);
    if (videoId == null || videoId.isEmpty) return null;
    return 'https://www.youtube.com/watch?v=$videoId';
  }

  int? _durationMsFromMediaItem(MediaItem mediaItem) {
    final fromDuration = mediaItem.duration?.inMilliseconds;
    if (fromDuration != null && fromDuration > 0) return fromDuration;

    final raw =
        mediaItem.extras?['durationMs'] ?? mediaItem.extras?['duration'];
    return _parsePositiveInt(raw);
  }

  String? _durationTextFromMediaItem(MediaItem mediaItem) {
    final raw = _normalizeText(mediaItem.extras?['durationText']);
    if (raw != null) return raw;

    final durationMs = _durationMsFromMediaItem(mediaItem);
    if (durationMs == null || durationMs <= 0) return null;
    return _formatDuration(durationMs);
  }

  String _streamingDurationValue() {
    final text = _normalizeText(_streamDurationText);
    if (text != null) return text;
    final durationMs = _streamDurationMs;
    if (durationMs != null && durationMs > 0) {
      return _formatDuration(durationMs);
    }
    final mediaDurationMs = _durationMsFromMediaItem(widget.mediaItem);
    if (mediaDurationMs != null && mediaDurationMs > 0) {
      return _formatDuration(mediaDurationMs);
    }
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final mediaPath = _mediaPath();
    final resolvedVideoId = _normalizeText(_videoId);
    final hasVideoId = resolvedVideoId != null && resolvedVideoId.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
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
                    ).colorScheme.secondary.withValues(alpha: 0.06),
            ),
            child: const Icon(Icons.arrow_back, size: 24),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: TranslatedText(
          'song_info',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.share),
            onPressed: _shareMedia,
            tooltip: LocaleProvider.tr('share'),
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 48, color: colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    'Error: $_errorMessage',
                    style: TextStyle(color: colorScheme.error),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header with Artwork and Info
                  Center(
                    child: Column(
                      children: [
                        _buildArtwork(180),
                        const SizedBox(height: 24),
                        Text(
                          fixUtf8Mojibake(widget.mediaItem.title),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _displayText(
                            widget.mediaItem.artist,
                            LocaleProvider.tr('unknown_artist'),
                          ),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.primary),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _displayText(
                            widget.mediaItem.album,
                            LocaleProvider.tr('unknown_album'),
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Audio Properties Label
                  Row(
                    children: [
                      Icon(
                        Icons.analytics_outlined,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        LocaleProvider.tr('information'),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Grid of properties
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final cardWidth = (width - 16) / 2;
                      final iconColor = colorScheme.onSurface;

                      return Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          _buildPropertyCard(
                            context,
                            icon: Icons.timer,
                            label: LocaleProvider.tr('duration'),
                            value: _isStreaming
                                ? _streamingDurationValue()
                                : (_audioInfo?.durationMs != null
                                      ? _formatDuration(_audioInfo!.durationMs!)
                                      : (widget.mediaItem.duration != null
                                            ? _formatDuration(
                                                widget
                                                    .mediaItem
                                                    .duration!
                                                    .inMilliseconds,
                                              )
                                            : "?")),
                            width: cardWidth,
                            color: iconColor,
                          ),
                          if (!_isStreaming)
                            _buildPropertyCard(
                              context,
                              icon: Icons.save,
                              label: LocaleProvider.tr('file_size'),
                              value: _audioInfo?.fileSize != null
                                  ? _formatFileSize(_audioInfo!.fileSize!)
                                  : 'N/A',
                              width: cardWidth,
                              color: iconColor,
                            ),
                          if (!_isStreaming)
                            _buildPropertyCard(
                              context,
                              icon: Icons.speaker,
                              label: LocaleProvider.tr('channels'),
                              value: _audioInfo?.channels != null
                                  ? '${_audioInfo!.channels}'
                                  : 'N/A',
                              width: cardWidth,
                              color: iconColor,
                            ),
                          if (!_isStreaming)
                            _buildPropertyCard(
                              context,
                              icon: Icons.audio_file,
                              label: LocaleProvider.tr('audio_format'),
                              value: _getAudioFormat(mediaPath),
                              width: cardWidth,
                              color: iconColor,
                            ),
                          if (!_isStreaming)
                            _buildPropertyCard(
                              context,
                              icon: Icons.speed,
                              label: LocaleProvider.tr('original_bitrate'),
                              value: _audioInfo?.bitRate != null
                                  ? '${_audioInfo!.bitRate} ${LocaleProvider.tr('kbps')}'
                                  : 'N/A',
                              width: width, // Full width
                              color: iconColor,
                            ),
                          if (!_isStreaming)
                            _buildPropertyCard(
                              context,
                              icon: Icons.graphic_eq,
                              label: LocaleProvider.tr('original_sample_rate'),
                              value: _audioInfo?.sampleRate != null
                                  ? '${_audioInfo!.sampleRate} ${LocaleProvider.tr('hz')}'
                                  : 'N/A',
                              width: width, // Full width
                              color: iconColor,
                            ),
                          if (!_isStreaming && hasVideoId)
                            _buildPropertyCard(
                              context,
                              icon: Icons.link,
                              label: 'Video ID',
                              value: resolvedVideoId,
                              width: width,
                              color: iconColor,
                              trailing: IconButton(
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                icon: Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isAmoled
                                        ? Colors.white.withAlpha(20)
                                        : isDark
                                        ? Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.06)
                                        : Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.07),
                                  ),
                                  child: Icon(
                                    Icons.help_outline,
                                    size: 20,
                                    color: colorScheme.primary,
                                  ),
                                ),
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (context) {
                                      final isAmoled =
                                          colorSchemeNotifier.value ==
                                          AppColorScheme.amoled;
                                      final isDark =
                                          Theme.of(context).brightness ==
                                          Brightness.dark;

                                      return AlertDialog(
                                        backgroundColor: isAmoled && isDark
                                            ? Colors.black
                                            : Theme.of(
                                                context,
                                              ).colorScheme.surface,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            28,
                                          ),
                                          side: isAmoled && isDark
                                              ? const BorderSide(
                                                  color: Colors.white24,
                                                  width: 1,
                                                )
                                              : BorderSide.none,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.fromLTRB(
                                              0,
                                              24,
                                              0,
                                              8,
                                            ),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.help_rounded,
                                              size: 32,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurface,
                                            ),
                                            const SizedBox(height: 16),
                                            Text(
                                              'Video ID',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                            ),
                                            const SizedBox(height: 16),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 24,
                                                  ),
                                              child: Text(
                                                LocaleProvider.tr(
                                                  'video_id_explanation',
                                                ),
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurface
                                                      .withValues(alpha: 0.7),
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            const SizedBox(height: 24),
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                right: 24,
                                                bottom: 8,
                                              ),
                                              child: Align(
                                                alignment:
                                                    Alignment.centerRight,
                                                child: TextButton(
                                                  onPressed: () => Navigator.of(
                                                    context,
                                                  ).pop(),
                                                  child: Text(
                                                    LocaleProvider.tr('close'),
                                                    style: TextStyle(
                                                      color: Theme.of(
                                                        context,
                                                      ).colorScheme.primary,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          if (_downloadHistory != null &&
                              _downloadHistory!.title.isNotEmpty &&
                              fixUtf8Mojibake(_downloadHistory!.title).trim() !=
                                  fixUtf8Mojibake(
                                    widget.mediaItem.title,
                                  ).trim())
                            _buildPropertyCard(
                              context,
                              icon: Icons.history,
                              label: LocaleProvider.tr('original_title'),
                              value: fixUtf8Mojibake(_downloadHistory!.title),
                              width: width,
                              color: iconColor,
                            ),
                          if (_downloadHistory != null &&
                              _downloadHistory!.artist.isNotEmpty &&
                              fixUtf8Mojibake(
                                    _downloadHistory!.artist,
                                  ).trim() !=
                                  fixUtf8Mojibake(
                                    widget.mediaItem.artist ?? '',
                                  ).trim())
                            _buildPropertyCard(
                              context,
                              icon: Icons.person_outline,
                              label: LocaleProvider.tr('original_artist'),
                              value: fixUtf8Mojibake(_downloadHistory!.artist),
                              width: width,
                              color: iconColor,
                            ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(height: 32),

                  // Storage Location
                  Row(
                    children: [
                      Icon(
                        _isStreaming ? Icons.link : Icons.folder_open,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        LocaleProvider.tr('location'),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isAmoled
                          ? Colors.white.withAlpha(20)
                          : isDark
                          ? Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.06)
                          : Theme.of(
                              context,
                            ).colorScheme.secondary.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isStreaming
                              ? 'Video ID'
                              : LocaleProvider.tr('file_path'),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _isStreaming
                                    ? (resolvedVideoId ?? 'N/A')
                                    : _cleanFilePath(mediaPath),
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontFamily: 'monospace'),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 20),
                              onPressed: () {
                                final valueToCopy = _isStreaming
                                    ? (resolvedVideoId ?? '')
                                    : mediaPath;
                                if (valueToCopy.isEmpty) return;
                                Clipboard.setData(
                                  ClipboardData(text: valueToCopy),
                                );
                              },
                              style: IconButton.styleFrom(
                                backgroundColor: colorScheme.primaryContainer,
                                foregroundColor: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildPropertyCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required double width,
    required Color color,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Check for AMOLED theme using the custom notifier
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;

    // Create a subtle version of the accent color for background
    final cardColor = isAmoled
        ? Colors.white.withAlpha(20)
        : isDark
        ? Theme.of(context).colorScheme.secondary.withValues(alpha: 0.06)
        : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.07);

    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
  }

  Widget _buildArtwork(double size) {
    final extraSongId = widget.mediaItem.extras?['songId'];
    int? songId;
    if (extraSongId is int) {
      songId = extraSongId;
    } else if (extraSongId is String) {
      songId = int.tryParse(extraSongId);
    }

    // If songId not in extras, try parsing from MediaItem id
    songId ??= int.tryParse(widget.mediaItem.id);

    final filePath = _mediaPath();

    // If we have valid songId and path, use ArtworkListTile which handles caching/loading
    if (songId != null && filePath.isNotEmpty) {
      return ArtworkListTile(
        songId: songId,
        songPath: filePath,
        artUri: widget.mediaItem.artUri,
        size: size,
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(16),
      );
    }

    // Fallback logic
    final artUri = widget.mediaItem.artUri;
    if (artUri != null) {
      if (artUri.scheme == 'file') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(
            File(artUri.toFilePath()),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildPlaceholder(size),
          ),
        );
      } else if (artUri.scheme == 'http' || artUri.scheme == 'https') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            artUri.toString(),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _buildPlaceholder(size),
          ),
        );
      }
    }
    return _buildPlaceholder(size);
  }

  Widget _buildPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
