import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:music/utils/ota_update_helper.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:music/l10n/locale_provider.dart';

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

  Future<void> _checkUpdate() async {
    setState(() {
      _status = LocaleProvider.tr('checking_update');
      _hasChecked = true;
      _version = '';
      _changelog = '';
      _apkUrl = null;
    });

    final updateInfo = await OtaUpdateHelper.checkForUpdate();

    if (updateInfo == null) {
      if (mounted) {
        setState(() {
          _status = LocaleProvider.tr('no_updates_available');
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _version = updateInfo.version;
          _changelog = updateInfo.changelog;
          _apkUrl = updateInfo.apkUrl;
          _status = LocaleProvider.tr('ready_to_download');
        });
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
        .listen((event) {
      if (!mounted) return;
      setState(() {
        _status = event.status.toString().split('.').last;
        if (event.value != null && event.value!.isNotEmpty) {
          final val = event.value!.replaceAll('%', '');
          _progress = double.tryParse(val) != null ? double.parse(val) / 100 : 0.0;
        }
      });
    }, onError: (error) {
      if (!mounted) return;
      setState(() {
        _status = '${LocaleProvider.tr('error')}: $error';
        _isDownloading = false;
      });
    });
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
    final sizeScreen = MediaQuery.of(context).size;
    final aspectRatio = sizeScreen.height / sizeScreen.width;

    // Para 16:9 (≈1.77)
    final is16by9 = (aspectRatio < 1.85);
    return Scaffold(
      appBar: AppBar(
        title: Text(LocaleProvider.tr('update')),
        leading: _isDownloading
            ? Container()
            : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _isDownloading
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      LocaleProvider.tr('downloading_update'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${LocaleProvider.tr('version')}: $_version',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 42),
                    Text(
                      LocaleProvider.tr('changes'),
                      style: Theme.of(context).textTheme.titleMedium ??
                          const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: is16by9 ? 240 : 360,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.light
                              ? Theme.of(context).colorScheme.surfaceContainer
                              : Colors.white10,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Theme.of(context).brightness == Brightness.light
                                ? Theme.of(context).colorScheme.surfaceContainer
                                : Colors.white24,
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: Text(_changelog),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(LocaleProvider.tr('dont_exit_app')),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
          ],
            )
            : _version.isEmpty && !_hasChecked
                ? Stack(
                    children: [
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.update,
                              size: 100,
                              color: Theme.of(context).brightness == Brightness.light
                              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)
                              : Theme.of(context).colorScheme.onSurface,
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
                        bottom: 16,
                        right: 16,
                        child: TextButton(
                          onPressed: _checkUpdate,
                          child: Text(LocaleProvider.tr('check_for_update')),
                        ),
                      ),
                    ],
                  )
                : _version.isEmpty && _hasChecked
                    ? Center(child: Text(_status))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            LocaleProvider.tr('new_update_available'),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${LocaleProvider.tr('version')}: $_version',
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 42),
                          Text(
                            LocaleProvider.tr('changes'),
                            style: Theme.of(context).textTheme.titleMedium ??
                                const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: is16by9 ? 240 : 360,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness == Brightness.light
                                    ? Theme.of(context).colorScheme.surfaceContainer
                                    : Colors.white10,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Theme.of(context).brightness == Brightness.light
                                      ? Theme.of(context).colorScheme.surfaceContainer
                                      : Colors.white24,
                                ),
                              ),
                              child: SingleChildScrollView(
                                child: Text(_changelog),
                              ),
                            ),
                          ),       
                          const Spacer(),
                          Text('${LocaleProvider.tr('status')}: $_status'),
                          const SizedBox(height: 16),
                          LinearProgressIndicator(value: _progress),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text(LocaleProvider.tr('cancel')),
                              ),
                              TextButton(
                                onPressed: _startDownload,
                                child: Text(LocaleProvider.tr('update')),
                              ),
                            ],
                          ),
                        ],
                      ),
      ),
    );
  }
}