import 'package:flutter/material.dart';
import 'package:flutter_audio_toolkit/flutter_audio_toolkit.dart';
import 'package:audio_service/audio_service.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../l10n/locale_provider.dart';
import '../utils/theme_preferences.dart';

class SongInfoDialog {
  static Future<void> show(
    BuildContext context,
    MediaItem mediaItem,
    ValueNotifier<AppColorScheme> colorSchemeNotifier,
  ) async {
    final FlutterAudioToolkit audioToolkit = FlutterAudioToolkit();
    AudioInfo? audioInfo;
    bool isLoading = true;
    String? errorMessage;

    // Obtener la ruta del archivo
    final filePath = mediaItem.extras?['data'] as String?;
    if (filePath == null || filePath.isEmpty) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: TranslatedText('song_info'),
          actions: [],
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${LocaleProvider.tr('title')}: ${mediaItem.title}\n',
              ),
              Text(
                '${LocaleProvider.tr('artist')}: ${mediaItem.artist ?? LocaleProvider.tr('unknown_artist')}\n',
              ),
              Text(
                '${LocaleProvider.tr('album')}: ${mediaItem.album ?? LocaleProvider.tr('unknown_artist')}\n',
              ),
              Text(
                '${LocaleProvider.tr('duration')}: ${mediaItem.duration != null ? _formatDuration(mediaItem.duration!.inMilliseconds) : "?"}',
              ),
            ],
          ),
        ),
      );
      return;
    }

    // Cargar información de audio
    try {
      audioInfo = await audioToolkit.getAudioInfo(filePath);
      isLoading = false;
    } catch (e) {
      errorMessage = e.toString();
      isLoading = false;
    }

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              title: Center(
                child: TranslatedText(
                  'song_info',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              actions: [],
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    if (isLoading) ...[
                      Center(
                        child: Column(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            TranslatedText('loading'),
                          ],
                        ),
                      ),
                    ] else if (errorMessage != null) ...[
                      Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 48,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Error: $errorMessage',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ] else if (audioInfo != null) ...[
                      // Información básica de la canción
                      _buildSongInfoCard(
                        context,
                        mediaItem,
                        audioInfo,
                        isAmoled,
                        isDark,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildSongInfoCard(
    BuildContext context,
    MediaItem mediaItem,
    AudioInfo audioInfo,
    bool isAmoled,
    bool isDark,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Información básica
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.music_note,
                    label: LocaleProvider.tr('song_title'),
                    value: mediaItem.title,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.person,
                    label: LocaleProvider.tr('song_artist'),
                    value: mediaItem.artist ?? LocaleProvider.tr('unknown_artist'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.album,
                    label: LocaleProvider.tr('song_album'),
                    value: mediaItem.album ?? LocaleProvider.tr('unknown_album'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.timer,
                    label: LocaleProvider.tr('duration'),
                    value: audioInfo.durationMs != null 
                        ? _formatDuration(audioInfo.durationMs!) 
                        : (mediaItem.duration != null 
                            ? _formatDuration(mediaItem.duration!.inMilliseconds)
                            : 'N/A'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.storage,
                    label: LocaleProvider.tr('file_size'),
                    value: audioInfo.fileSize != null 
                        ? _formatFileSize(audioInfo.fileSize!) 
                        : 'N/A',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.volume_up,
                    label: LocaleProvider.tr('channels'),
                    value: audioInfo.channels != null 
                        ? '${audioInfo.channels}' 
                        : 'N/A',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.speed,
                    label: LocaleProvider.tr('original_bitrate'),
                    value: audioInfo.bitRate != null 
                        ? '${audioInfo.bitRate} ${LocaleProvider.tr('kbps')}' 
                        : 'N/A',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.graphic_eq,
                    label: LocaleProvider.tr('original_sample_rate'),
                    value: audioInfo.sampleRate != null 
                        ? '${audioInfo.sampleRate} ${LocaleProvider.tr('hz')}' 
                        : 'N/A',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Información del archivo y formato
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.audiotrack,
                    label: LocaleProvider.tr('audio_format'),
                    value: _getAudioFormat(mediaItem.extras?['data'] ?? ''),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.folder,
                    label: LocaleProvider.tr('file_path'),
                    value: mediaItem.extras?['data'] ?? 'N/A',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  static String _formatDuration(int milliseconds) {
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

  static String _getAudioFormat(String filePath) {
    if (filePath.isEmpty) return 'N/A';
    
    final extension = filePath.split('.').last.toLowerCase();
    
    switch (extension) {
      case 'mp3':
        return 'MP3';
      case 'm4a':
        return 'M4A';
      case 'aac':
        return 'AAC';
      case 'flac':
        return 'FLAC';
      case 'wav':
        return 'WAV';
      case 'ogg':
        return 'OGG';
      case 'opus':
        return 'OPUS';
      case 'wma':
        return 'WMA';
      case 'aiff':
      case 'aif':
        return 'AIFF';
      case 'alac':
        return 'ALAC';
      case 'ape':
        return 'APE';
      case 'dsd':
        return 'DSD';
      case 'dff':
        return 'DFF';
      case 'dsf':
        return 'DSF';
      default:
        return extension.toUpperCase();
    }
  }

  // Función sobrecargada para SongModel
  static Future<void> showFromSong(
    BuildContext context,
    SongModel song,
    ValueNotifier<AppColorScheme> colorSchemeNotifier,
  ) async {
    final FlutterAudioToolkit audioToolkit = FlutterAudioToolkit();
    AudioInfo? audioInfo;
    bool isLoading = true;
    String? errorMessage;

    // Cargar información de audio
    try {
      audioInfo = await audioToolkit.getAudioInfo(song.data);
      isLoading = false;
    } catch (e) {
      errorMessage = e.toString();
      isLoading = false;
    }

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            
            return AlertDialog(
              title: Center(
                child: TranslatedText(
                  'song_info',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              actions: [],
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    if (isLoading) ...[
                      Center(
                        child: Column(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            TranslatedText('loading'),
                          ],
                        ),
                      ),
                    ] else if (errorMessage != null) ...[
                      Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 48,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Error: $errorMessage',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ] else if (audioInfo != null) ...[
                      // Información básica de la canción
                      _buildSongInfoCardFromSong(
                        context,
                        song,
                        audioInfo,
                        isAmoled,
                        isDark,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildSongInfoCardFromSong(
    BuildContext context,
    SongModel song,
    AudioInfo audioInfo,
    bool isAmoled,
    bool isDark,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Información básica
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.music_note,
                    label: LocaleProvider.tr('song_title'),
                    value: song.title,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.person,
                    label: LocaleProvider.tr('song_artist'),
                    value: song.artist ?? LocaleProvider.tr('unknown_artist'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.album,
                    label: LocaleProvider.tr('song_album'),
                    value: song.album ?? LocaleProvider.tr('unknown_album'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.timer,
                    label: LocaleProvider.tr('duration'),
                    value: audioInfo.durationMs != null 
                        ? _formatDuration(audioInfo.durationMs!) 
                        : 'N/A',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.storage,
                    label: LocaleProvider.tr('file_size'),
                    value: audioInfo.fileSize != null 
                        ? _formatFileSize(audioInfo.fileSize!) 
                        : 'N/A',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.volume_up,
                    label: LocaleProvider.tr('channels'),
                    value: audioInfo.channels != null 
                        ? '${audioInfo.channels}' 
                        : 'N/A',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.speed,
                    label: LocaleProvider.tr('original_bitrate'),
                    value: audioInfo.bitRate != null 
                        ? '${audioInfo.bitRate} ${LocaleProvider.tr('kbps')}' 
                        : 'N/A',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.graphic_eq,
                    label: LocaleProvider.tr('original_sample_rate'),
                    value: audioInfo.sampleRate != null 
                        ? '${audioInfo.sampleRate} ${LocaleProvider.tr('hz')}' 
                        : 'N/A',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Información del archivo y formato
            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    icon: Icons.audiotrack,
                    label: LocaleProvider.tr('audio_format'),
                    value: _getAudioFormat(song.data),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _InfoItem(
                    icon: Icons.folder,
                    label: LocaleProvider.tr('file_path'),
                    value: song.data,
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

class _InfoItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
