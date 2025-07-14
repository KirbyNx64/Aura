import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

final languageNotifier = ValueNotifier<String>('es');

class LocaleProvider {
  static Map<String, String> _currentMap = appLocalizationsEs;

  static Future<void> loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final lang = prefs.getString('app_language') ?? 'es';
    _currentMap = lang == 'en' ? appLocalizationsEn : appLocalizationsEs;
    languageNotifier.value = lang; // Notifica a toda la app
  }

  static void setLanguage(String lang) {
    _currentMap = lang == 'en' ? appLocalizationsEn : appLocalizationsEs;
    languageNotifier.value = lang;
  }

  static String tr(String key) {
    return _currentMap[key] ?? key;
  }
}

class TranslatedText extends StatelessWidget {
  final String translationKey;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const TranslatedText(
    this.translationKey, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: languageNotifier,
      builder: (context, lang, child) {
        return Text(
          LocaleProvider.tr(translationKey),
          style: style,
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: overflow,
        );
      },
    );
  }
} 