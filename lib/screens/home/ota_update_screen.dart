import 'package:flutter/material.dart';
import 'package:music/utils/connectivity_helper.dart';
import 'package:ota_update/ota_update.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:material_loading_indicator/loading_indicator.dart';
import 'package:open_settings_plus/open_settings_plus.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  String _status = '';
  double _progress = 0.0;
  bool _isDownloading = false;

  // Variables para info de versión y changelog
  String _version = '';
  String _changelog = '';
  String? _apkUrl;

  // Estado para saber si ya buscó actualización
  bool _hasChecked = false;
  // Estado para saber si está buscando actualizaciones
  bool _isChecking = false;
  // Estado para saber si no hay internet
  bool _noInternet = false;

  Future<void> _checkUpdate() async {
    setState(() {
      _status = LocaleProvider.tr('checking_update');
      _hasChecked = true;
      _isChecking = true;
      _noInternet = false;
      _version = '';
      _changelog = '';
      _apkUrl = null;
    });

    final hasConnection = await ConnectivityHelper.hasInternetConnection();

    if (!hasConnection) {
      if (mounted) {
        setState(() {
          _noInternet = true;
          _status = LocaleProvider.tr('no_internet_connection');
          _isChecking = false;
        });
      }
      return;
    }

    final updateInfo = await OtaUpdateHelper.checkForUpdate();

    if (updateInfo == null) {
      if (mounted) {
        setState(() {
          _status = LocaleProvider.tr('no_updates_available');
          _isChecking = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _version = updateInfo.version;
          _changelog = updateInfo.changelog;
          _apkUrl = updateInfo.apkUrl;
          _status = LocaleProvider.tr('ready_to_download');
          _isChecking = false;
        });
      }
    }
  }

  void _showDownloadDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              surfaceTintColor: Colors.transparent,
              title: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_rounded,
                    size: 32,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    LocaleProvider.tr('download_method'),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        LocaleProvider.tr('select_download_method'),
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildDownloadOption(
                      context: context,
                      title: LocaleProvider.tr('download_in_app'),
                      subtitle: LocaleProvider.tr('download_in_app_desc'),
                      icon: Icons.download_rounded,
                      onTap: () {
                        Navigator.of(context).pop();
                        _startDownload();
                      },
                      isAmoled: isAmoled,
                      isDark: isDark,
                    ),
                    _buildDownloadOption(
                      context: context,
                      title: LocaleProvider.tr('download_in_browser'),
                      subtitle: LocaleProvider.tr('download_in_browser_desc'),
                      icon: Icons.open_in_browser_rounded,
                      onTap: () {
                        Navigator.of(context).pop();
                        _openInBrowser();
                      },
                      isAmoled: isAmoled,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 8),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      LocaleProvider.tr('cancel'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDownloadOption({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    required bool isAmoled,
    required bool isDark,
  }) {
    final onSurfaceColor = Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
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
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isAmoled && isDark
                  ? Colors.white.withAlpha(30)
                  : Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.1),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: onSurfaceColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: onSurfaceColor.withAlpha(150),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openInBrowser() async {
    if (_apkUrl != null) {
      try {
        final Uri url = Uri.parse(_apkUrl!);
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${LocaleProvider.tr('could_not_open')}: $_apkUrl',
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${LocaleProvider.tr('error')}: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _startDownload() async {
    if (_apkUrl == null) return;

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _status = LocaleProvider.tr('downloading');
    });

    await _borrarApkPrevio();

    OtaUpdate()
        .execute(_apkUrl!, destinationFilename: 'aura_update.apk')
        .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              _status = event.status.toString().split('.').last;
              if (event.value != null && event.value!.isNotEmpty) {
                final val = event.value!.replaceAll('%', '');
                _progress = double.tryParse(val) != null
                    ? double.parse(val) / 100
                    : 0.0;
              }
            });
          },
          onError: (error) {
            if (!mounted) return;
            setState(() {
              _status = '${LocaleProvider.tr('error')}: $error';
              _isDownloading = false;
            });
          },
        );
  }

  Future<void> _borrarApkPrevio() async {
    try {
      final dir = await getExternalStorageDirectory();
      final apkFile = File('${dir?.path}/aura_update.apk');
      if (await apkFile.exists()) {
        await apkFile.delete();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Tamaños relativos
    // final sizeScreen = MediaQuery.of(context).size;
    // final aspectRatio = sizeScreen.height / sizeScreen.width;

    // Para 16:9 (≈1.77)
    // final is16by9 = (aspectRatio < 1.85);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: colorSchemeNotifier,
      builder: (context, colorScheme, _) {
        final isAmoled = colorScheme == AppColorScheme.amoled;
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: TranslatedText(
              'update',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            leading: _isDownloading
                ? Container()
                : IconButton(
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
                      alignment: Alignment.center,
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
          ),
          body: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).padding.bottom,
            ),
            child: _isDownloading
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LocaleProvider.tr('downloading_update'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${LocaleProvider.tr('version')}: $_version',
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        LocaleProvider.tr('changes'),
                        style:
                            Theme.of(context).textTheme.titleMedium ??
                            const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: isAmoled
                                ? Colors.white.withAlpha(20)
                                : isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.06)
                                : Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: SingleChildScrollView(
                            child: Text(
                              _changelog,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(LocaleProvider.tr('dont_exit_app')),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _progress,
                        borderRadius: BorderRadius.circular(8),
                        minHeight: 8,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.3),
                      ),
                    ],
                  )
                : _version.isEmpty && !_hasChecked
                ? Stack(
                    children: [
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 120,
                              height: 120,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDark
                                    ? Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.06)
                                    : Theme.of(context).colorScheme.secondary
                                          .withValues(alpha: 0.07),
                              ),
                              child: Icon(
                                Icons.update_rounded,
                                grade: 300,
                                size: 80,
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.light
                                    ? Theme.of(context).colorScheme.onSurface
                                          .withValues(alpha: 0.7)
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              LocaleProvider.tr('press_button_to_check'),
                              style: const TextStyle(fontSize: 18),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 32,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: ElevatedButton.icon(
                            onPressed: _checkUpdate,
                            icon: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                              child: Icon(
                                Icons.search,
                                size: 16,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                            label: Text(LocaleProvider.tr('check_for_update')),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onPrimary,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              elevation: 4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : _version.isEmpty && _hasChecked && _isChecking
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.06)
                                : Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.07),
                          ),
                          child: LoadingIndicator(
                            activeIndicatorColor: isDark
                                ? Theme.of(context).colorScheme.onSurface
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withAlpha(180),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _status,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : _version.isEmpty && _hasChecked && !_isChecking
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 120,
                          height: 120,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.06)
                                : Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.07),
                          ),
                          child: Icon(
                            _noInternet
                                ? Icons.wifi_off_rounded
                                : Icons.check_circle_outline_rounded,
                            grade: 300,
                            size: 80,
                            color:
                                Theme.of(context).brightness == Brightness.light
                                ? Theme.of(
                                    context,
                                  ).colorScheme.onSurface.withValues(alpha: 0.7)
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _status,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 26),
                        ElevatedButton.icon(
                          onPressed: _noInternet
                              ? () {
                                  switch (OpenSettingsPlus.shared) {
                                    case OpenSettingsPlusAndroid settings:
                                      settings.wifi();
                                      break;
                                    case OpenSettingsPlusIOS settings:
                                      settings.wifi();
                                      break;
                                    default:
                                      break;
                                  }
                                }
                              : _checkUpdate,
                          icon: Container(
                            width: 24,
                            height: 24,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                            child: Icon(
                              _noInternet ? Icons.settings : Icons.refresh,
                              size: 16,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          ),
                          label: Text(
                            _noInternet
                                ? LocaleProvider.tr('open_settings')
                                : LocaleProvider.tr('check_again'),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onPrimary,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            elevation: 4,
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        LocaleProvider.tr('new_update_available'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${LocaleProvider.tr('version')}: $_version',
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 42),
                      Text(
                        LocaleProvider.tr('changes'),
                        style:
                            Theme.of(context).textTheme.titleMedium ??
                            const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: isAmoled
                                ? Colors.white.withAlpha(20)
                                : isDark
                                ? Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.06)
                                : Theme.of(context).colorScheme.secondary
                                      .withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: SingleChildScrollView(
                            child: Text(
                              _changelog,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        ),
                      ),
                      Text('${LocaleProvider.tr('status')}: $_status'),
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: _progress,
                        borderRadius: BorderRadius.circular(8),
                        minHeight: 8,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.3),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _showDownloadDialog,
                            icon: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                              child: Icon(
                                Icons.download,
                                size: 16,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                            label: Text(LocaleProvider.tr('update')),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onPrimary,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              elevation: 4,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
