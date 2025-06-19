// permisos.dart
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

Future<void> pedirPermisosMedia() async {
  if (!Platform.isAndroid) return;

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  final sdkInt = androidInfo.version.sdkInt;

  if (sdkInt >= 33) {
    // Android 13+
    await Permission.audio.request();
    await Permission.photos.request();
  } else if (sdkInt >= 30) {
    // Android 11-12
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();
  } else {
    // Android 10 o menor (incluye Android 9)
    await Permission.storage.request();
  }
}
