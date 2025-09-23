import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:music/l10n/locale_provider.dart';

// Instancia global del plugin de notificaciones
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Clase singleton para manejar las notificaciones de descarga
class DownloadNotificationThrottler {
  double _lastProgress = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  String _currentTitle = 'Descargando...';
  
  static final DownloadNotificationThrottler _instance =
      DownloadNotificationThrottler._internal();
  factory DownloadNotificationThrottler() => _instance;
  DownloadNotificationThrottler._internal();

  void setTitle(String title) {
    _currentTitle = title;
  }

  void show(double progress, {int notificationId = 0}) {
    final now = DateTime.now();
    final percentDelta = (progress - _lastProgress).abs();
    final timeDelta = now.difference(_lastUpdate).inMilliseconds;
    if (percentDelta >= 3 || timeDelta >= 400) {
      _lastProgress = progress;
      _lastUpdate = now;
      showDownloadProgressNotification(
        progress,
        _currentTitle,
        notificationId: notificationId,
      );
    }
  }
}

// Función para mostrar la notificación de progreso de descarga
Future<void> showDownloadProgressNotification(
  double progress,
  String title, {
  int notificationId = 0,
}) async {
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'download_channel_no_vibration',
        'Descargas',
        channelDescription: 'Notificaciones de progreso de descarga',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        showProgress: true,
        maxProgress: 100,
        progress: progress.toInt(),
        indeterminate: false,
        onlyAlertOnce: true,
        enableVibration: false,
        vibrationPattern: null,
        ongoing: true,
      );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  await flutterLocalNotificationsPlugin.show(
    notificationId,
    title,
    '${progress.toInt()}%',
    platformChannelSpecifics,
    payload: 'download',
  );
}

// Función para mostrar la notificación de descarga completada
Future<void> showDownloadCompletedNotification(
  String title,
  int notificationId,
) async {
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'download_channel_no_vibration',
        'Descargas',
        channelDescription: 'Notificaciones de progreso de descarga',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        enableVibration: false,
        vibrationPattern: null,
        ongoing: false, // No es persistente
      );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  await flutterLocalNotificationsPlugin.show(
    notificationId,
    title,
    LocaleProvider.tr('download_complete'),
    platformChannelSpecifics,
    payload: 'download_completed',
  );
}

// Función para mostrar la notificación de descarga fallida
Future<void> showDownloadFailedNotification(
  String title,
  int notificationId,
) async {
  final AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
        'download_channel_no_vibration',
        'Descargas',
        channelDescription: 'Notificaciones de progreso de descarga',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        enableVibration: false,
        vibrationPattern: null,
        ongoing: true,
        autoCancel: false,
      );
  final NotificationDetails platformChannelSpecifics = NotificationDetails(
    android: androidPlatformChannelSpecifics,
  );

  await flutterLocalNotificationsPlugin.show(
    notificationId,
    title,
    LocaleProvider.tr('download_failed_title'),
    platformChannelSpecifics,
    payload: 'download_failed',
  );
}

// Función para cancelar la notificación de descarga
Future<void> cancelDownloadNotification({int notificationId = 0}) async {
  await flutterLocalNotificationsPlugin.cancel(notificationId);
}

// Servicio global de notificaciones
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  // Inicializar el servicio de notificaciones
  static Future<void> initialize() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_stat_music_note');
    
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    
    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Crear canal de notificaciones para descargas
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'download_channel_no_vibration',
      'Descargas',
      description: 'Notificaciones de progreso de descarga',
      importance: Importance.defaultImportance,
      enableVibration: false,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    // Solicitar permisos de notificación en Android 13+
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  // Manejar cuando se toca una notificación
  static void _onNotificationTapped(NotificationResponse response) {
    // Aquí puedes agregar lógica para manejar el toque de notificaciones
    // Por ejemplo, abrir la pantalla de descargas o mostrar más detalles
  }
}
