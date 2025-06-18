// permisos.dart
import 'package:permission_handler/permission_handler.dart';

Future<void> pedirPermisoAudio() async {
  if (await Permission.audio.isGranted) return;

  await Permission.audio.request();
}

Future<bool> requestMusicPermission() async {
  // Para Android 13+ (API 33)
  if (await Permission.audio.isGranted) return true;
  if (await Permission.audio.request().isGranted) return true;

  // Para Android <= 12
  if (await Permission.storage.isGranted) return true;
  if (await Permission.storage.request().isGranted) return true;

  return false;
}
