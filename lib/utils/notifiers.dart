import 'package:flutter/material.dart';
import 'package:music/utils/theme_preferences.dart';

final foldersShouldReload = ValueNotifier<bool>(false);

final favoritesShouldReload = ValueNotifier<bool>(false);

final playlistsShouldReload = ValueNotifier<bool>(false);

final downloadDirectoryNotifier = ValueNotifier<String?>(null);
final downloadTypeNotifier = ValueNotifier<bool>(false); // true: Explode, false: Directo
final audioProcessorNotifier = ValueNotifier<bool>(false); // true: FFmpeg, false: AudioTags

final colorSchemeNotifier = ValueNotifier<AppColorScheme>(AppColorScheme.deepPurple);
