import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ota_update/ota_update.dart';
import 'connectivity_helper.dart';

class OtaUpdateHelper {
  static const String _urlJson =
      'https://raw.githubusercontent.com/KirbyNx64/Aura/main/update/version.json';

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      // Verificar conectividad antes de hacer la petición
      final hasConnection =
          await ConnectivityHelper.hasInternetConnectionWithTimeout(
            timeout: const Duration(seconds: 5),
          );

      if (!hasConnection) {
        return null;
      }

      final response = await http.get(Uri.parse(_urlJson));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final String remoteVersion = data['version'];
      final Map<String, dynamic>? apkUrls = data['apk_urls'];
      if (apkUrls == null) return null;
      final String changelog = data['changelog'] ?? '';

      final info = await PackageInfo.fromPlatform();
      final String localVersion = info.version;

      if (!_isNewVersion(localVersion, remoteVersion)) return null;

      final String? arch = await _getArch();
      // ('Arquitectura detectada: $arch');
      // print('URLs disponibles: $apkUrls');

      if (arch == null || !apkUrls.containsKey(arch)) {
        // print('Error: Arquitectura no soportada o no encontrada en las URLs');
        return null;
      }

      final String apkUrl = apkUrls[arch];
      // print('URL seleccionada para $arch: $apkUrl');

      return UpdateInfo(
        version: remoteVersion,
        apkUrl: apkUrl,
        changelog: changelog,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<String?> _getArch() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      final List<String> abis = androidInfo.supportedAbis;

      // print('ABIs soportadas por el dispositivo: $abis');

      if (abis.isEmpty) {
        // print('No se encontraron ABIs soportadas');
        return 'unknown';
      }

      // Priorizar la primera ABI (la nativa del dispositivo/emulador)
      final String primaryAbi = abis.first;
      // print('ABI principal (primera en la lista): $primaryAbi');

      // Mapear la ABI principal a nuestro formato
      if (primaryAbi == 'arm64-v8a') {
        // print('Seleccionada arquitectura: arm64-v8a');
        return 'arm64-v8a';
      } else if (primaryAbi == 'armeabi-v7a') {
        // print('Seleccionada arquitectura: armeabi-v7a');
        return 'armeabi-v7a';
      } else if (primaryAbi == 'x86_64') {
        // print('Seleccionada arquitectura: x86_64');
        return 'x86_64';
      } else if (primaryAbi == 'x86') {
        // print('Seleccionada arquitectura: x86 (fallback a x86_64)');
        return 'x86_64'; // Fallback para x86
      }

      // print('ABI no reconocida: $primaryAbi');
    }
    return null; // No compatible ABI detectada
  }

  static Stream<OtaEvent> startDownload(String apkUrl) {
    return OtaUpdate().execute(
      apkUrl,
      destinationFilename: 'aura_update.apk',
      usePackageInstaller:
          true, // Habilitar PackageInstaller para mejor control
    );
  }

  static bool _isNewVersion(String local, String remote) {
    final lv = local.split('.').map(int.parse).toList();
    final rv = remote.split('.').map(int.parse).toList();

    for (int i = 0; i < lv.length; i++) {
      if (rv[i] > lv[i]) return true;
      if (rv[i] < lv[i]) return false;
    }
    return false;
  }
}

class UpdateInfo {
  final String version;
  final String apkUrl;
  final String changelog;

  UpdateInfo({
    required this.version,
    required this.apkUrl,
    required this.changelog,
  });
}
