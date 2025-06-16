// permisos.dart
import 'package:permission_handler/permission_handler.dart';

Future<void> pedirPermisoAudio() async {
  if (await Permission.audio.isGranted) return;

  await Permission.audio.request();
}

Future<bool> requestStoragePermission() async {
  if (await Permission.storage.request().isGranted) {
    return true;
  }
  return false;
}
