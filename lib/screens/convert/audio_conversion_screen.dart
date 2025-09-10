import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_audio_toolkit/flutter_audio_toolkit.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:media_scanner/media_scanner.dart';

class AudioConversionScreen extends StatefulWidget {
  final MediaItem song;

  const AudioConversionScreen({super.key, required this.song});

  @override
  State<AudioConversionScreen> createState() => _AudioConversionScreenState();
}

class _AudioConversionScreenState extends State<AudioConversionScreen> {
  final FlutterAudioToolkit _audioToolkit = FlutterAudioToolkit();
  
  // Estado de la conversión
  bool _isConverting = false;
  double _conversionProgress = 0.0;
  String _statusMessage = '';
  
  // Información del archivo original
  AudioInfo? _audioInfo;
  
  // Configuración de conversión
  AudioFormat _selectedFormat = AudioFormat.m4a;
  int _selectedBitrate = 128;
  int _selectedSampleRate = 44100;
  QualityPreset _selectedQualityPreset = QualityPreset.medium;
  bool _useCustomQuality = false;
  
  // Formatos disponibles
  final List<AudioFormat> _availableFormats = [
    AudioFormat.m4a,
  ];
  
  // Presets de calidad
  final Map<QualityPreset, Map<String, int>> _qualityPresets = {
    QualityPreset.low: {'bitrate': 64, 'sampleRate': 22050},
    QualityPreset.medium: {'bitrate': 128, 'sampleRate': 44100},
    QualityPreset.high: {'bitrate': 192, 'sampleRate': 44100},
    QualityPreset.veryHigh: {'bitrate': 320, 'sampleRate': 48000},
    QualityPreset.lossless: {'bitrate': 320, 'sampleRate': 48000},
  };
  
  // Bitrates disponibles
  final List<int> _availableBitrates = [32, 64, 96, 128, 160, 192, 256, 320];
  
  // Sample rates disponibles
  final List<int> _availableSampleRates = [22050, 44100, 48000, 96000];

  @override
  void initState() {
    super.initState();
    _loadAudioInfo();
  }

  Future<void> _loadAudioInfo() async {
    try {
      setState(() {
        _statusMessage = '${LocaleProvider.tr('loading')}...';
      });
      
      final audioInfo = await _audioToolkit.getAudioInfo(widget.song.id);
      
      if (mounted) {
        setState(() {
          _audioInfo = audioInfo;
          _statusMessage = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  Future<void> _startConversion() async {
    if (_isConverting) return;
    
    setState(() {
      _isConverting = true;
      _conversionProgress = 0.0;
      _statusMessage = LocaleProvider.tr('converting_audio');
    });
    
    try {
      // Generar nombre del archivo de salida
      final originalFile = File(widget.song.id);
      final originalName = originalFile.path.split('/').last.split('.').first;
      final extension = _selectedFormat == AudioFormat.m4a ? 'm4a' : 'aac';
      
      // Crear directorio de salida
      final downloadsDir = Directory('/storage/emulated/0/Download/Converted');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      
      final outputPath = '${downloadsDir.path}/$originalName.$extension';
      
      // Configurar parámetros de conversión
      final bitrate = _useCustomQuality ? _selectedBitrate : _qualityPresets[_selectedQualityPreset]!['bitrate']!;
      final sampleRate = _useCustomQuality ? _selectedSampleRate : _qualityPresets[_selectedQualityPreset]!['sampleRate']!;
      
      // Realizar conversión
      await _audioToolkit.convertAudio(
        inputPath: widget.song.id,
        outputPath: outputPath,
        format: _selectedFormat,
        bitRate: bitrate,
        sampleRate: sampleRate,
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _conversionProgress = progress;
            });
          }
        },
      );
      
      // Indexar el archivo convertido
      if (Platform.isAndroid) {
        try {
          await MediaScanner.loadMedia(path: outputPath);
        } catch (e) {
          // Ignorar errores de indexación
        }
      }
      
      // Actualizar notifiers para refrescar la UI
      foldersShouldReload.value = !foldersShouldReload.value;
      
      if (mounted) {
        setState(() {
          _isConverting = false;
          _statusMessage = LocaleProvider.tr('conversion_complete');
        });
        
        _showSuccessDialog(outputPath);
      }
      
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConverting = false;
          _statusMessage = 'Error: $e';
        });
        
        _showErrorDialog(e.toString());
      }
    }
  }

  void _showSuccessDialog(String outputPath) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: TranslatedText('conversion_complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TranslatedText('conversion_complete_desc'),
            const SizedBox(height: 16),
            Text(
              'Archivo guardado en:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              outputPath,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: TranslatedText('ok'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: TranslatedText('conversion_error'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TranslatedText('conversion_error_desc'),
            const SizedBox(height: 16),
            Text(
              'Error: $error',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: TranslatedText('ok'),
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TranslatedText('audio_conversion'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Información del archivo original
            if (_audioInfo != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LocaleProvider.tr('input_format'),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _InfoItem(
                              icon: Icons.music_note,
                              label: LocaleProvider.tr('song_title'),
                              value: widget.song.title,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              icon: Icons.person,
                              label: LocaleProvider.tr('song_artist'),
                              value: widget.song.artist ?? LocaleProvider.tr('unknown_artist'),
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
                              value: widget.song.album ?? LocaleProvider.tr('unknown_album'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              icon: Icons.timer,
                              label: LocaleProvider.tr('duration'),
                              value: _formatDuration(_audioInfo!.durationMs ?? 0),
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
                              value: _formatFileSize(_audioInfo!.fileSize ?? 0),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              icon: Icons.volume_up,
                              label: LocaleProvider.tr('channels'),
                              value: '${_audioInfo!.channels}',
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
                              value: '${_audioInfo!.bitRate} ${LocaleProvider.tr('kbps')}',
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _InfoItem(
                              icon: Icons.graphic_eq,
                              label: LocaleProvider.tr('original_sample_rate'),
                              value: '${_audioInfo!.sampleRate} ${LocaleProvider.tr('hz')}',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            
            // Configuración de conversión
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleProvider.tr('output_format'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Selección de formato
                    DropdownButtonFormField<AudioFormat>(
                      value: _selectedFormat,
                      decoration: InputDecoration(
                        labelText: LocaleProvider.tr('select_format'),
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.audio_file),
                      ),
                      items: _availableFormats.map((format) {
                        return DropdownMenuItem(
                          value: format,
                          child: Text(format.name.toUpperCase()),
                        );
                      }).toList(),
                      onChanged: _isConverting ? null : (value) {
                        if (value != null) {
                          setState(() {
                            _selectedFormat = value;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    
                    // Presets de calidad
                    Text(
                      LocaleProvider.tr('quality_preset'),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: QualityPreset.values.map((preset) {
                        final isSelected = _selectedQualityPreset == preset && !_useCustomQuality;
                        return FilterChip(
                          label: Text(_getQualityPresetName(preset)),
                          selected: isSelected,
                          onSelected: _isConverting ? null : (selected) {
                            if (selected) {
                              setState(() {
                                _selectedQualityPreset = preset;
                                _useCustomQuality = false;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    
                    // Calidad personalizada
                    Row(
                      children: [
                        Checkbox(
                          value: _useCustomQuality,
                          onChanged: _isConverting ? null : (value) {
                            setState(() {
                              _useCustomQuality = value ?? false;
                            });
                          },
                        ),
                        Text(LocaleProvider.tr('custom_quality')),
                      ],
                    ),
                    
                    if (_useCustomQuality) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _selectedBitrate,
                              decoration: InputDecoration(
                                labelText: LocaleProvider.tr('bitrate'),
                                border: const OutlineInputBorder(),
                                suffixText: LocaleProvider.tr('kbps'),
                              ),
                              items: _availableBitrates.map((bitrate) {
                                return DropdownMenuItem(
                                  value: bitrate,
                                  child: Text('$bitrate'),
                                );
                              }).toList(),
                              onChanged: _isConverting ? null : (value) {
                                if (value != null) {
                                  setState(() {
                                    _selectedBitrate = value;
                                  });
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _selectedSampleRate,
                              decoration: InputDecoration(
                                labelText: LocaleProvider.tr('sample_rate'),
                                border: const OutlineInputBorder(),
                                suffixText: LocaleProvider.tr('hz'),
                              ),
                              items: _availableSampleRates.map((sampleRate) {
                                return DropdownMenuItem(
                                  value: sampleRate,
                                  child: Text('$sampleRate'),
                                );
                              }).toList(),
                              onChanged: _isConverting ? null : (value) {
                                if (value != null) {
                                  setState(() {
                                    _selectedSampleRate = value;
                                  });
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Progreso de conversión
            if (_isConverting) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LocaleProvider.tr('conversion_progress'),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: _conversionProgress,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${(_conversionProgress * 100).toStringAsFixed(1)}%',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_statusMessage.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _statusMessage,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            
            // Botón de conversión
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isConverting ? null : _startConversion,
                icon: _isConverting 
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.transform),
                label: Text(_isConverting 
                    ? LocaleProvider.tr('converting_audio')
                    : LocaleProvider.tr('start_conversion')
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getQualityPresetName(QualityPreset preset) {
    switch (preset) {
      case QualityPreset.low:
        return LocaleProvider.tr('low_quality');
      case QualityPreset.medium:
        return LocaleProvider.tr('medium_quality');
      case QualityPreset.high:
        return LocaleProvider.tr('high_quality');
      case QualityPreset.veryHigh:
        return LocaleProvider.tr('very_high_quality');
      case QualityPreset.lossless:
        return LocaleProvider.tr('lossless');
    }
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

enum QualityPreset {
  low,
  medium,
  high,
  veryHigh,
  lossless,
}
