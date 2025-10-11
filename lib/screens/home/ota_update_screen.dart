import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:music/utils/notifiers.dart';
import 'package:material_symbols_icons/symbols.dart';

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

  Future<void> _checkUpdate() async {
    setState(() {
      _status = LocaleProvider.tr('checking_update');
      _hasChecked = true;
      _isChecking = true;
      _version = '';
      _changelog = '';
      _apkUrl = null;
    });

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
                borderRadius: BorderRadius.circular(16),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white, width: 1)
                    : BorderSide.none,
              ),
              title: Center(
                child: Text(
                  LocaleProvider.tr('download_method'),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          LocaleProvider.tr('select_download_method'),
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.left,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    // Tarjeta de Descargar en app
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _startDownload();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(4),
                            bottomRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.transparent,
                              ),
                              child: Icon(
                                Icons.download,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('download_in_app'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white
                                          : Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    LocaleProvider.tr('download_in_app_desc'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isAmoled && isDark
                                          ? Colors.white.withValues(alpha: 0.7)
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 4),
                    // Tarjeta de Descargar en navegador
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _openInBrowser();
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: isAmoled && isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(4),
                          ),
                          border: Border.all(
                            color: isAmoled && isDark
                                ? Colors.white.withValues(alpha: 0.2)
                                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.transparent,
                              ),
                              child: Icon(
                                Symbols.open_in_browser_rounded,
                                grade: 300,
                                size: 30,
                                color: isAmoled && isDark
                                    ? Colors.white
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    LocaleProvider.tr('download_in_browser'),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: isAmoled && isDark
                                          ? Colors.white
                                          : Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    LocaleProvider.tr('download_in_browser_desc'),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isAmoled && isDark
                                          ? Colors.white.withValues(alpha: 0.7)
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
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
              ),
            );
          },
        );
      },
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
                content: Text('${LocaleProvider.tr('could_not_open')}: $_apkUrl'),
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
    // final isSystem = colorSchemeNotifier.value == AppColorScheme.system;
    // final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLight = Theme.of(context).brightness == Brightness.light;
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(LocaleProvider.tr('update')),
        leading: _isDownloading 
            ? Container() 
            : IconButton(
                icon: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  ),
                  child: const Icon(Icons.arrow_back, size: 24),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
      body: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
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
                        color: isLight ? Theme.of(context).colorScheme.secondaryContainer
                              : Theme.of(context).colorScheme.onSecondaryFixed,
                        borderRadius: BorderRadius.circular(12),
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
                    backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                          ),
                          child: Icon(
                            Symbols.update_rounded,
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
                          child: Icon(Icons.search, size: 16, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                        label: Text(LocaleProvider.tr('check_for_update')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                      ),
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.primary,
                        ),
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
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                      ),
                      child: Icon(
                        Symbols.check_circle_outline_rounded,
                        grade: 300,
                        size: 80,
                        color: Theme.of(context).brightness == Brightness.light
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
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 26),
                    ElevatedButton.icon(
                      onPressed: _checkUpdate,
                      icon: Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.2),
                        ),
                        child: Icon(Icons.refresh, size: 16, color: Theme.of(context).colorScheme.onPrimary),
                      ),
                      label: Text(LocaleProvider.tr('check_again')),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
                        color: isLight ? Theme.of(context).colorScheme.secondaryContainer
                              : Theme.of(context).colorScheme.onSecondaryFixed,
                        borderRadius: BorderRadius.circular(12),
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
                    backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
                          child: Icon(Icons.download, size: 16, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                        label: Text(LocaleProvider.tr('update')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
  }
}
