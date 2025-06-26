import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:music/utils/ota_update_helper.dart';

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
      _status = 'Buscando actualización...';
      _hasChecked = true;
      _version = '';
      _changelog = '';
      _apkUrl = null;
    });

    final updateInfo = await OtaUpdateHelper.checkForUpdate();

    if (updateInfo == null) {
      if (mounted) {
        setState(() {
          _status = 'No hay actualizaciones disponibles.';
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _version = updateInfo.version;
          _changelog = updateInfo.changelog;
          _apkUrl = updateInfo.apkUrl;
          _status = 'Lista para descargar';
        });
      }
    }
  }

  void _startDownload() {
    if (_apkUrl == null) return;

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _status = 'Descargando...';
    });

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
        _status = 'Error: $error';
        _isDownloading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Actualización'),
        leading: _isDownloading
            ? Container() // Sin botón back mientras descarga
            : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _isDownloading
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 8),
                  Text('Estado: $_status'),
                ],
              )
            : _version.isEmpty && !_hasChecked
                ? Stack(
                    children: [
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.update,
                              size: 100,
                              color: Colors.white70,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Presiona el botón para buscar actualización',
                              style: TextStyle(fontSize: 18),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: ElevatedButton(
                          onPressed: _checkUpdate,
                          child: const Text('Buscar actualización'),
                        ),
                      ),
                    ],
                  )
                : _version.isEmpty && _hasChecked
                    ? Center(child: Text(_status))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 40),
                          const Text(
                            'Nueva actualización disponible',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Versión: $_version',
                            style:
                                const TextStyle(
                                    fontSize: 16),
                          ),
                          const SizedBox(height: 42),
                          Text(
                            'Cambios:',
                            style: Theme.of(context).textTheme.titleMedium ??
                                const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                              child: SingleChildScrollView(child: Text(_changelog))),
                          const SizedBox(height: 60),
                          LinearProgressIndicator(value: _progress),
                          const SizedBox(height: 16),
                          Text('Estado: $_status'),
                          const Spacer(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Cancelar'),
                              ),
                              ElevatedButton(
                                onPressed: _startDownload,
                                child: const Text('Actualizar'),
                              ),
                            ],
                          ),
                        ],
                      ),
      ),
    );
  }
}
