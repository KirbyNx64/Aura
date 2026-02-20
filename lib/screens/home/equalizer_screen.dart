import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music/main.dart' show AudioHandlerSafeCast, audioHandler;
import 'package:music/l10n/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:material_loading_indicator/loading_indicator.dart';

class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  AndroidEqualizer? _equalizer;
  AndroidEqualizerParameters? _parameters;
  bool _isLoading = true;
  bool _isEnabled = false;
  List<double> _bandGains = [];
  StreamSubscription<bool>? _enabledStreamSubscription;

  // Volume Boost
  double _volumeBoost = 1.0;
  StreamSubscription<double>? _volumeBoostSubscription;
  ValueNotifier<double>? _volumeBoostNotifier;
  VoidCallback? _volumeBoostListener;

  @override
  void initState() {
    super.initState();
    _initializeEqualizer();
  }

  @override
  void dispose() {
    _enabledStreamSubscription?.cancel();
    _volumeBoostSubscription?.cancel();
    if (_volumeBoostNotifier != null && _volumeBoostListener != null) {
      _volumeBoostNotifier!.removeListener(_volumeBoostListener!);
    }
    super.dispose();
  }

  Future<void> _initializeEqualizer() async {
    if (!Platform.isAndroid) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    try {
      // Obtener el equalizer del AudioHandler
      final handler = audioHandler;
      if (handler == null) {
        return;
      }

      // Acceder al equalizer del handler con timeout
      _equalizer = handler.myHandler?.equalizer;

      if (_equalizer != null) {
        try {
          // Agregar timeout para evitar bloqueos indefinidos
          _parameters = await _equalizer!.parameters.timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw TimeoutException(
              'Timeout obteniendo parámetros del equalizer',
            ),
          );
          _isEnabled = _equalizer!.enabled;

          // Cargar los valores guardados o inicializar con ceros
          await _loadEqualizerSettings();

          // Escuchar cambios en el estado enabled
          _enabledStreamSubscription = _equalizer!.enabledStream.listen((
            enabled,
          ) {
            if (mounted) {
              setState(() {
                _isEnabled = enabled;
              });
            }
          });
        } catch (e) {
          // Si hay error al obtener parámetros, marcar el equalizer como no disponible
          _equalizer = null;
          _parameters = null;
        }
      }

      // Cargar volume boost desde el handler (que ya lo cargó de SharedPreferences)
      try {
        final h = handler.myHandler;
        if (h != null) {
          _volumeBoostNotifier = h.volumeBoostNotifier;
          _volumeBoost = _volumeBoostNotifier!.value;
          _volumeBoostListener = () {
            if (mounted) {
              setState(() {
                _volumeBoost = _volumeBoostNotifier!.value;
              });
            }
          };
          _volumeBoostNotifier!.addListener(_volumeBoostListener!);
        }
      } catch (e) {
        // Si hay error al cargar volume boost, intentar obtener directamente de SharedPreferences
        try {
          final prefs = await SharedPreferences.getInstance();
          final savedBoost = prefs.getDouble('volume_boost') ?? 1.0;
          if (mounted) {
            setState(() {
              _volumeBoost = savedBoost;
            });
          }
        } catch (e2) {
          // Usar valor por defecto
          if (mounted) {
            setState(() {
              _volumeBoost = 1.0;
            });
          }
        }
      }
    } catch (e) {
      // Ignorar errores de inicialización
    } finally {
      // Siempre establecer _isLoading en false, sin importar si hubo error o no
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadEqualizerSettings() async {
    if (_parameters == null) return;

    final prefs = await SharedPreferences.getInstance();
    _bandGains = [];

    for (int i = 0; i < _parameters!.bands.length; i++) {
      final savedGain = prefs.getDouble('equalizer_band_$i') ?? 0.0;
      _bandGains.add(savedGain);

      // Aplicar el valor guardado a la banda
      try {
        await _parameters!.bands[i].setGain(savedGain);
      } catch (e) {
        // Ignorar errores al cargar
      }
    }

    // Cargar el estado enabled
    final enabled = prefs.getBool('equalizer_enabled') ?? false;
    _isEnabled = enabled;
    if (_equalizer != null) {
      await _equalizer!.setEnabled(enabled);
    }
  }

  Future<void> _saveEqualizerSettings() async {
    final prefs = await SharedPreferences.getInstance();

    for (int i = 0; i < _bandGains.length; i++) {
      await prefs.setDouble('equalizer_band_$i', _bandGains[i]);
    }

    await prefs.setBool('equalizer_enabled', _isEnabled);
  }

  Future<void> _toggleEqualizer(bool value) async {
    if (_equalizer == null) return;

    setState(() {
      _isEnabled = value;
    });

    await _equalizer!.setEnabled(value);

    // Si se desactiva, bajar volume boost a 1.0x
    if (!value) {
      await _updateVolumeBoost(1.0);
    }

    await _saveEqualizerSettings();
  }

  Future<void> _updateBandGain(int index, double value) async {
    if (_parameters == null) return;

    setState(() {
      _bandGains[index] = value;
    });

    await _parameters!.bands[index].setGain(value);
    await _saveEqualizerSettings();
  }

  Future<void> _updateVolumeBoost(double value) async {
    final handler = audioHandler;
    if (handler == null) return;

    setState(() {
      _volumeBoost = value;
    });

    await handler.myHandler?.setVolumeBoost(value);
  }

  Future<void> _resetEqualizer() async {
    // Mostrar diálogo de confirmación
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isAmoled && isDark
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white24, width: 1)
              : BorderSide.none,
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        icon: Icon(
          Icons.refresh_rounded,
          size: 32,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        title: Text(
          LocaleProvider.tr('reset_equalizer'),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          LocaleProvider.tr('reset_equalizer_confirm'),
          style: TextStyle(
            fontSize: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        actionsPadding: const EdgeInsets.all(16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              LocaleProvider.tr('cancel'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isAmoled && isDark
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: isAmoled ? Colors.white : null,
            ),
            child: Text(
              LocaleProvider.tr('reset'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isAmoled ? Colors.black : null,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Restablecer todas las bandas a 0.0
    if (_parameters != null && _bandGains.isNotEmpty) {
      for (int i = 0; i < _parameters!.bands.length; i++) {
        setState(() {
          _bandGains[i] = 0.0;
        });
        await _parameters!.bands[i].setGain(0.0);
      }
      await _saveEqualizerSettings();
    }

    // Restablecer volumen boost a 1.0
    await _updateVolumeBoost(1.0);
  }

  String _formatFrequency(double frequency) {
    if (frequency >= 1000) {
      final kHz = frequency / 1000;
      if (kHz % 1 == 0) {
        return '${kHz.toInt()} ${LocaleProvider.tr('khz_short')}';
      }
      return '${kHz.toStringAsFixed(1)} ${LocaleProvider.tr('khz_short')}';
    }
    return '${frequency.toInt()} ${LocaleProvider.tr('hz_short')}';
  }

  void _showEqualizerInfo() {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isAmoled && isDark
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white24, width: 1)
              : BorderSide.none,
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        icon: Icon(
          Icons.info_rounded,
          size: 32,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        title: Text(
          LocaleProvider.tr('important_information'),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        content: SingleChildScrollView(
          child: Text(
            LocaleProvider.tr('volume_boost_info'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
              fontSize: 16,
            ),
            textAlign: TextAlign.start,
          ),
        ),
        actionsPadding: const EdgeInsets.all(16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              LocaleProvider.tr('ok'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isAmoled && isDark
                    ? Colors.white
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TranslatedText(
          'equalizer',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
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
                    ).colorScheme.secondary.withValues(alpha: 0.07),
            ),
            child: const Icon(Icons.arrow_back, size: 24),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 26),
            onPressed: _resetEqualizer,
            tooltip: LocaleProvider.tr('reset_equalizer'),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 26),
            onPressed: _showEqualizerInfo,
            tooltip: LocaleProvider.tr('important_information'),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    if (_isLoading) {
      return Center(child: LoadingIndicator());
    }

    if (!Platform.isAndroid) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.equalizer_rounded,
                size: 64,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(height: 16),
              Text(
                LocaleProvider.tr('equalizer_not_available'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                LocaleProvider.tr('equalizer_not_available_desc'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_equalizer == null || _parameters == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.equalizer_rounded,
                size: 64,
                color: theme.colorScheme.onSurface,
              ),
              const SizedBox(height: 16),
              Text(
                LocaleProvider.tr('equalizer_not_prossessing'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                LocaleProvider.tr('equalizer_not_prossessing_desc'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Switch para habilitar/deshabilitar
          Card(
            color: isAmoled && isDark
                ? Colors.white.withAlpha(20)
                : colorScheme.primary.withValues(alpha: 0.3),
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide.none,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: SwitchListTile(
                tileColor: Colors.transparent,
                title: Text(
                  LocaleProvider.tr('equalizer'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                value: _isEnabled,
                onChanged: _toggleEqualizer,
                thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                  Set<WidgetState> states,
                ) {
                  final isAmoled =
                      colorSchemeNotifier.value == AppColorScheme.amoled;
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final iconColor = isAmoled && isDark ? Colors.white : null;
                  if (states.contains(WidgetState.selected)) {
                    return Icon(Icons.check, size: 20, color: iconColor);
                  } else {
                    return const Icon(Icons.close, size: 20);
                  }
                }),
              ),
            ),
          ),

          // Bandas del ecualizador
          if (_parameters!.bands.isNotEmpty) ...[
            const SizedBox(height: 16),

            Card(
              color: isAmoled && isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.06)
                  : Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.07),
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 24.0,
                  horizontal: 16.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          LocaleProvider.tr('equalizer_bands'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            "${_parameters!.bands.length} Bandas",
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // Sliders verticales en horizontal
                    SizedBox(
                      height: 300,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment
                            .spaceEvenly, // Changed to spaceBetween for better distribution if needed
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: _parameters!.bands.asMap().entries.map((
                          entry,
                        ) {
                          final index = entry.key;
                          final band = entry.value;
                          final currentGain = _bandGains.length > index
                              ? _bandGains[index]
                              : 0.0;

                          return Expanded(
                            // Ensure equal width distribution
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // Valor actual en dB
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surface,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: colorScheme.outline.withValues(
                                        alpha: 0.2,
                                      ),
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    "${currentGain > 0 ? '+' : ''}${currentGain.toStringAsFixed(1)}",
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 10,
                                      color: currentGain != 0
                                          ? colorScheme.primary
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),

                                // Slider vertical
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: -1,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 6, // Thicker track
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius:
                                              0, // Hidden thumb for cleaner look or keep it small
                                          elevation: 0,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 10,
                                            ),
                                        activeTrackColor: colorScheme.primary,
                                        inactiveTrackColor:
                                            colorScheme.surfaceContainerHighest,
                                        disabledActiveTrackColor: colorScheme
                                            .primary
                                            .withValues(alpha: 0.4),
                                        disabledInactiveTrackColor: colorScheme
                                            .surfaceContainerHighest
                                            .withValues(alpha: 0.4),
                                        trackShape:
                                            _RoundedRectSliderTrackShape(),
                                      ),
                                      child: Slider(
                                        value: currentGain,
                                        min: _parameters!.minDecibels,
                                        max: _parameters!.maxDecibels,
                                        onChanged: _isEnabled
                                            ? (value) =>
                                                  _updateBandGain(index, value)
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 12),

                                // Frecuencia
                                Text(
                                  _formatFrequency(band.centerFrequency),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Volume Boost
          const SizedBox(height: 16),
          Card(
            color: isAmoled && isDark
                ? Colors.white.withAlpha(15)
                : Theme.of(
                    context,
                  ).colorScheme.secondary.withValues(alpha: 0.06),
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
              side: BorderSide.none,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isAmoled
                              ? Colors.white
                              : colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.volume_up_rounded,
                          color: isAmoled
                              ? Colors.black
                              : colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              LocaleProvider.tr('volume_boost'),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              LocaleProvider.tr('volume_boost_desc'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Indicador de valor actual
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        LocaleProvider.tr('multiplier'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_volumeBoost.toStringAsFixed(1)}x',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Slider
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 12,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 12,
                        elevation: 2,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 24,
                      ),
                      activeTrackColor: colorScheme.primary,
                      inactiveTrackColor: colorScheme.surfaceContainerHighest,
                      disabledActiveTrackColor: colorScheme.primary.withValues(
                        alpha: 0.4,
                      ),
                      disabledInactiveTrackColor: colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      trackShape: _RoundedRectSliderTrackShape(),
                    ),
                    child: Slider(
                      value: _volumeBoost,
                      min: 1.0,
                      max: 3.0,
                      divisions: 20,
                      label: '${_volumeBoost.toStringAsFixed(1)}x',
                      onChanged: _isEnabled
                          ? (value) => _updateVolumeBoost(value)
                          : null,
                    ),
                  ),

                  // Indicadores de rango
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '1.0x',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          '2.0x',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '3.0x',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundedRectSliderTrackShape extends SliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    if (sliderTheme.trackHeight == null) {
      return;
    }

    final ColorTween activeTrackColorTween = ColorTween(
      begin: sliderTheme.disabledActiveTrackColor,
      end: sliderTheme.activeTrackColor,
    );
    final ColorTween inactiveTrackColorTween = ColorTween(
      begin: sliderTheme.disabledInactiveTrackColor,
      end: sliderTheme.inactiveTrackColor,
    );
    final Paint activePaint = Paint()
      ..color = activeTrackColorTween.evaluate(enableAnimation)!;
    final Paint inactivePaint = Paint()
      ..color = inactiveTrackColorTween.evaluate(enableAnimation)!;
    final Paint leftTrackPaint;
    final Paint rightTrackPaint;
    switch (textDirection) {
      case TextDirection.ltr:
        leftTrackPaint = activePaint;
        rightTrackPaint = inactivePaint;
        break;
      case TextDirection.rtl:
        leftTrackPaint = inactivePaint;
        rightTrackPaint = activePaint;
        break;
    }

    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final Radius trackRadius = Radius.circular(trackRect.height / 2);

    context.canvas.drawRRect(
      RRect.fromLTRBAndCorners(
        trackRect.left,
        trackRect.top,
        thumbCenter.dx,
        trackRect.bottom,
        topLeft: trackRadius,
        bottomLeft: trackRadius,
      ),
      leftTrackPaint,
    );
    context.canvas.drawRRect(
      RRect.fromLTRBAndCorners(
        thumbCenter.dx,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
        topRight: trackRadius,
        bottomRight: trackRadius,
      ),
      rightTrackPaint,
    );
  }

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight!;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
