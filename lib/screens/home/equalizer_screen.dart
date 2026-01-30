import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music/main.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

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
      try {
        _equalizer = (handler as dynamic).equalizer as AndroidEqualizer?;
      } catch (e) {
        _equalizer = null;
      }

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
        // Obtener el valor actual del notifier del handler
        _volumeBoostNotifier =
            (handler as dynamic).volumeBoostNotifier as ValueNotifier<double>;

        // Establecer el valor inicial
        if (mounted) {
          setState(() {
            _volumeBoost = _volumeBoostNotifier!.value;
          });
        }

        // Crear y agregar listener para cambios futuros
        _volumeBoostListener = () {
          if (mounted) {
            setState(() {
              _volumeBoost = _volumeBoostNotifier!.value;
            });
          }
        };
        _volumeBoostNotifier!.addListener(_volumeBoostListener!);
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

    await (handler as dynamic).setVolumeBoost(value);
  }

  Future<void> _resetEqualizer() async {
    // Mostrar diálogo de confirmación
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Row(
          children: [
            Icon(Icons.refresh, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                LocaleProvider.tr('reset_equalizer'),
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        content: Text(LocaleProvider.tr('reset_equalizer_confirm')),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(LocaleProvider.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(LocaleProvider.tr('reset')),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: isAmoled && isDark
              ? const BorderSide(color: Colors.white, width: 1)
              : BorderSide.none,
        ),
        title: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                LocaleProvider.tr('important_information'),
                style: TextStyle(
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: SizedBox(
            width: MediaQuery.of(context).size.width * 0.8,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                LocaleProvider.tr('volume_boost_info'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.3,
                ),
              ),
            ),
          ),
        ),
        actions: [
          SizedBox(height: 16),
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isAmoled && isDark
                    ? Colors.white.withValues(alpha: 0.2)
                    : Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isAmoled && isDark
                      ? Colors.white.withValues(alpha: 0.4)
                      : Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: isAmoled && isDark
                          ? Colors.white.withValues(alpha: 0.2)
                          : Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.1),
                    ),
                    child: Icon(
                      Icons.check_circle,
                      size: 30,
                      color: isAmoled && isDark
                          ? Colors.white
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          LocaleProvider.tr('ok'),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: isAmoled && isDark
                                ? Colors.white
                                : Theme.of(context).colorScheme.primary,
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
                  ? theme.colorScheme.onSecondary.withValues(alpha: 0.5)
                  : theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
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
    final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    final isAmoled = colorSchemeNotifier.value == AppColorScheme.amoled;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!Platform.isAndroid) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.equalizer,
                size: 64,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 16),
              Text(
                LocaleProvider.tr('equalizer_not_available'),
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                LocaleProvider.tr('equalizer_not_available_desc'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
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
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
              const SizedBox(height: 16),
              Text(
                LocaleProvider.tr('equalizer_not_prossessing'),
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                LocaleProvider.tr('equalizer_not_prossessing_desc'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
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
            color: (isSystem || isAmoled) && isDark
                ? Theme.of(context).colorScheme.onSecondaryFixed
                : Theme.of(context).colorScheme.secondaryContainer,
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: isAmoled && isDark
                  ? const BorderSide(color: Colors.white, width: 1)
                  : BorderSide.none,
            ),
            child: SwitchListTile(
              title: Text(
                LocaleProvider.tr('equalizer'),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              value: _isEnabled,
              onChanged: _toggleEqualizer,
              thumbIcon: WidgetStateProperty.resolveWith<Icon?>((
                Set<WidgetState> states,
              ) {
                final iconColor = isAmoled && isDark ? Colors.white : null;
                if (states.contains(WidgetState.selected)) {
                  return Icon(Icons.check, size: 20, color: iconColor);
                } else {
                  return const Icon(Icons.close, size: 20);
                }
              }),
            ),
          ),

          // Bandas del ecualizador
          if (_parameters!.bands.isNotEmpty) ...[
            const SizedBox(height: 24),

            Card(
              color: (isSystem || isAmoled) && isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.onSecondary.withValues(alpha: 0.5)
                  : theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    Text(
                      LocaleProvider.tr('equalizer_bands'),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Sliders verticales en horizontal
                    SizedBox(
                      height: 280,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                // Valor actual en dB
                                Text(
                                  currentGain.toStringAsFixed(1),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Slider vertical
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: -1,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 3,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 8,
                                        ),
                                      ),
                                      child: Slider(
                                        activeColor: theme.colorScheme.primary,
                                        inactiveColor:
                                            theme.colorScheme.surface,
                                        value: currentGain,
                                        min: _parameters!.minDecibels,
                                        max: _parameters!.maxDecibels,
                                        divisions:
                                            ((_parameters!.maxDecibels -
                                                        _parameters!
                                                            .minDecibels) *
                                                    10)
                                                .toInt(),
                                        onChanged: _isEnabled
                                            ? (value) =>
                                                  _updateBandGain(index, value)
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),

                                const SizedBox(height: 8),

                                // Frecuencia
                                Text(
                                  _formatFrequency(band.centerFrequency),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
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

            // Volume Boost
            const SizedBox(height: 16),
            Card(
              color: (isSystem || isAmoled) && isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.onSecondary.withValues(alpha: 0.5)
                  : theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
              margin: EdgeInsets.zero,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleProvider.tr('volume_boost'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      LocaleProvider.tr('volume_boost_desc'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
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
                          ),
                        ),
                        Text(
                          '${_volumeBoost.toStringAsFixed(1)}x',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Slider
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 10,
                        ),
                      ),
                      child: Slider(
                        value: _volumeBoost,
                        min: 1.0,
                        max: 3.0,
                        divisions: 20,
                        label: '${_volumeBoost.toStringAsFixed(1)}x',
                        onChanged: (value) => _updateVolumeBoost(value),
                      ),
                    ),

                    // Indicadores de rango
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '1.0x',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                          Text(
                            '2.0x',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '3.0x',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
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
        ],
      ),
    );
  }
}
