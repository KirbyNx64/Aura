import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ota_update/ota_update.dart';

class OtaUpdateHelper {
  static const String _urlJson = 'https://raw.githubusercontent.com/KirbyNx64/Aura/main/update/version.json';

  // Consulta la versión remota y compara con local. Devuelve info o null si no hay nueva versión.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(Uri.parse(_urlJson));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final remoteVersion = data['version'] as String;
      final apkUrl = data['apk_url'] as String;
      final changelog = data['changelog'] ?? '';

      final info = await PackageInfo.fromPlatform();
      final localVersion = info.version;

      if (_isNewVersion(localVersion, remoteVersion)) {
        return UpdateInfo(version: remoteVersion, apkUrl: apkUrl, changelog: changelog);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  // Método para iniciar la descarga y retornar stream de eventos
  static Stream<OtaEvent> startDownload(String apkUrl) {
    return OtaUpdate().execute(apkUrl, destinationFilename: 'aura_update.apk');
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
