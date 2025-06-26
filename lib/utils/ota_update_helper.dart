import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ota_update/ota_update.dart';

class OtaUpdateHelper {
  static const String _urlJson = 'https://raw.githubusercontent.com/KirbyNx64/Aura/update/version.json';

  static Future<void> verificarYActualizar(BuildContext context) async {
    try {
      final response = await http.get(Uri.parse(_urlJson));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String remoteVersion = data['version'];
        final String apkUrl = data['apk_url'];
        final String changelog = data['changelog'] ?? '';

        final info = await PackageInfo.fromPlatform();
        final String localVersion = info.version;

        if (_esNuevaVersion(localVersion, remoteVersion)) {
          if (context.mounted) {
            _mostrarDialogo(context, remoteVersion, apkUrl, changelog);
          }
        } else {
          if (context.mounted) {
            _mostrarSnackbar(context, 'Ya tienes la última versión ($localVersion).');
          }
        }
      } else {
        if (context.mounted) {
          _mostrarSnackbar(context, 'Error al obtener la versión remota');
        }
      }
    } catch (e) {
      if (context.mounted) {
        _mostrarSnackbar(context, 'Error: $e');
      }
    }
  }

  static bool _esNuevaVersion(String local, String remota) {
    final lv = local.split('.').map(int.parse).toList();
    final rv = remota.split('.').map(int.parse).toList();

    for (int i = 0; i < lv.length; i++) {
      if (rv[i] > lv[i]) return true;
      if (rv[i] < lv[i]) return false;
    }
    return false;
  }

  static void _mostrarDialogo(
    BuildContext context,
    String version,
    String apkUrl,
    String changelog,
  ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Nueva versión disponible ($version)'),
        content: Text('Cambios:\n$changelog'),
        actions: [
          TextButton(
            child: const Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          ElevatedButton(
            child: const Text('Actualizar'),
            onPressed: () {
              Navigator.pop(context);
              _iniciarDescarga(context, apkUrl);
            },
          ),
        ],
      ),
    );
  }

  static void _iniciarDescarga(BuildContext context, String apkUrl) {
    try {
      OtaUpdate()
          .execute(apkUrl, destinationFilename: 'aura_update.apk')
          .listen((event) {
        debugPrint('OTA Estado: ${event.status}, Valor: ${event.value}');
      });
    } catch (e) {
      if (context.mounted) {
        _mostrarSnackbar(context, 'Error al descargar: $e');
      }
    }
  }

  static void _mostrarSnackbar(BuildContext context, String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensaje)));
  }
}
