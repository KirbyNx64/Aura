// permisos.dart
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

Future<bool> pedirPermisosMedia() async {
  if (!Platform.isAndroid) return true;

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  final sdkInt = androidInfo.version.sdkInt;

  if (sdkInt >= 33) {
    // Android 13+
    final audio = await Permission.audio.status;

    // print('audio: $audio');

    if (audio.isGranted) {
      return true;
    }

    final result = await [Permission.audio].request();

    return result[Permission.audio]?.isGranted == true;
  } else if (sdkInt >= 30) {
    // Android 11-12
    final storage = await Permission.storage.status;
    final manage = await Permission.manageExternalStorage.status;

    if (storage.isGranted && manage.isGranted) {
      return true;
    }

    final storageReq = await Permission.storage.request();
    final manageReq = await Permission.manageExternalStorage.request();

    return storageReq.isGranted && manageReq.isGranted;
  } else {
    // Android 10 o menor
    final storage = await Permission.storage.status;
    if (storage.isGranted) return true;

    final storageReq = await Permission.storage.request();
    return storageReq.isGranted;
  }
}

/// Verifica si se tienen permisos de acceso a todos los archivos
/// Necesario para Android 11+ para poder descargar archivos
Future<bool> verificarPermisosTodosLosArchivos() async {
  if (!Platform.isAndroid) return true;

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  final sdkInt = androidInfo.version.sdkInt;

  if (sdkInt >= 30) {
    // Android 11+ - necesita MANAGE_EXTERNAL_STORAGE
    final manageStorage = await Permission.manageExternalStorage.status;
    return manageStorage.isGranted;
  } else {
    // Android 10 o menor - solo necesita storage
    final storage = await Permission.storage.status;
    return storage.isGranted;
  }
}