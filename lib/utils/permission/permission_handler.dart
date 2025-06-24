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
    final photos = await Permission.photos.status;

    // print('audio: $audio, photos: $photos');

    if (audio.isGranted && photos.isGranted) {
      return true;
    }

    final result = await [Permission.audio, Permission.photos].request();

    return result[Permission.audio]?.isGranted == true &&
        result[Permission.photos]?.isGranted == true;
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
