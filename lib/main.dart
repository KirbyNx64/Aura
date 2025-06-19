import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:music/utils/audio/background_audio_handler.dart';
import 'package:music/utils/permission/permission_handler.dart';
import 'widgets/bottom_nav.dart';
import 'screens/home/home_screen.dart';
import 'screens/likes/favorites_screen.dart';
import 'screens/folders/folders_screen.dart';
import 'screens/download/download_screen.dart';

late final AudioHandler audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pedirPermisosMedia();
  audioHandler = await initAudioService();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mi App de Música',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: Material3BottomNav(
        pageBuilders: [
          (context) => HomeScreen(),
          (context) => FavoritesScreen(),
          (context) => FoldersScreen(),
          (context) => DownloadScreen(),
        ],
      ),
    );
  }
}
