import 'package:flutter/material.dart';
import 'package:music/utils/theme_preferences.dart';

final foldersShouldReload = ValueNotifier<bool>(false);

final favoritesShouldReload = ValueNotifier<bool>(false);

final playlistsShouldReload = ValueNotifier<bool>(false);

final downloadDirectoryNotifier = ValueNotifier<String?>(null);
final downloadTypeNotifier = ValueNotifier<bool>(false); // true: Explode, false: Directo
final audioProcessorNotifier = ValueNotifier<bool>(false); // true: FFmpeg, false: AudioTags

final colorSchemeNotifier = ValueNotifier<AppColorScheme>(AppColorScheme.deepPurple);

final ValueNotifier<bool> shortcutsShouldReload = ValueNotifier(false);

final ValueNotifier<bool> audioQualityNotifier = ValueNotifier<bool>(true); // true: alta, false: baja

final ValueNotifier<bool> heroAnimationNotifier = ValueNotifier(false);
