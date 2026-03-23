import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';

const String _ytMusicMainUrl = 'https://music.youtube.com/';

class YtCookieLoginScreen extends StatefulWidget {
  const YtCookieLoginScreen({super.key});

  @override
  State<YtCookieLoginScreen> createState() => _YtCookieLoginScreenState();
}

class _YtCookieLoginScreenState extends State<YtCookieLoginScreen> {
  bool _capturingCookies = false;
  bool _showProgress = true;
  int _progress = 0;

  String _resolveWebLang() {
    final current = languageNotifier.value.toLowerCase();
    return current.startsWith('en') ? 'en' : 'es';
  }

  WebUri _buildYtLoginUri() {
    final lang = _resolveWebLang();
    final continueUri = Uri.https('music.youtube.com', '/', {'hl': lang});
    final loginUri = Uri.https('accounts.google.com', '/ServiceLogin', {
      'service': 'youtube',
      'continue': continueUri.toString(),
      'hl': lang,
    });
    return WebUri(loginUri.toString());
  }

  Map<String, String> _buildInitialWebHeaders() {
    final lang = _resolveWebLang();
    return {
      'Accept-Language': lang == 'en'
          ? 'en-US,en;q=0.9'
          : 'es-419,es;q=0.9,en;q=0.8',
    };
  }

  Future<void> _showStyledDialog({
    required String title,
    required String message,
    IconData? icon,
    Color? iconColor,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          surfaceTintColor: Colors.transparent,
          title: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  color: iconColor ?? Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Text(message, style: const TextStyle(fontSize: 16)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(LocaleProvider.tr('ok')),
            ),
          ],
        );
      },
    );
  }

  void _showLoginInfoDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return ValueListenableBuilder<AppColorScheme>(
          valueListenable: colorSchemeNotifier,
          builder: (context, colorScheme, child) {
            final isAmoled = colorScheme == AppColorScheme.amoled;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final primaryColor = Theme.of(context).colorScheme.primary;

            return AlertDialog(
              backgroundColor: isAmoled && isDark
                  ? Colors.black
                  : Theme.of(context).colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: isAmoled && isDark
                    ? const BorderSide(color: Colors.white24, width: 1)
                    : BorderSide.none,
              ),
              contentPadding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 400,
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.info_rounded,
                      size: 32,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      LocaleProvider.tr('yt_music_login_info_title'),
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        LocaleProvider.tr('yt_music_login_info_desc'),
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(180),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(right: 24, bottom: 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            LocaleProvider.tr('ok'),
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  bool _isYtMusicMainPage(Uri? uri) {
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final isMusicHost =
        host == 'music.youtube.com' || host.endsWith('.music.youtube.com');
    return isMusicHost;
  }

  /*
  Future<void> _clearAllCookies() async {
    try {
      await clearYtWebViewSessionData();
      await _showStyledDialog(
        title: 'Sesión limpiada',
        message: 'Las cookies y datos del WebView se eliminaron correctamente.',
        icon: Icons.check_circle_outline_rounded,
      );
    } catch (_) {
      await _showStyledDialog(
        title: 'No se pudo limpiar',
        message: 'No se pudieron eliminar las cookies del WebView.',
        icon: Icons.error_outline_rounded,
      );
    }
  }
  */

  Future<String?> _extractCookieHeader() async {
    final manager = CookieManager.instance();
    final targets = <WebUri>[
      WebUri(_ytMusicMainUrl),
      WebUri('https://www.youtube.com/'),
      WebUri('https://youtube.com/'),
    ];

    final mergedByName = <String, String>{};
    for (final target in targets) {
      try {
        final cookies = await manager.getCookies(url: target);
        for (final cookie in cookies) {
          final name = cookie.name.trim();
          final value = cookie.value.trim();
          if (name.isEmpty || value.isEmpty) continue;
          mergedByName[name] = value;
        }
      } catch (_) {
        // Continuar con otros dominios.
      }
    }

    if (mergedByName.isEmpty) return null;
    return mergedByName.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  Future<void> _tryFinishWithCookies(Uri? uri) async {
    if (_capturingCookies) return;
    if (!_isYtMusicMainPage(uri)) return;

    _capturingCookies = true;
    final cookieHeader = await _extractCookieHeader();
    if (!mounted) return;

    if (cookieHeader == null || cookieHeader.trim().isEmpty) {
      _capturingCookies = false;
      await _showStyledDialog(
        title: LocaleProvider.tr('yt_music_login_cookie_extract_error_title'),
        message: LocaleProvider.tr('yt_music_login_cookie_extract_error_desc'),
        icon: Icons.error_outline_rounded,
      );
      return;
    }

    Navigator.of(context).pop(cookieHeader);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(LocaleProvider.tr('yt_music_login_screen_title')),
        leading: IconButton(
          constraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
            maxWidth: 40,
            maxHeight: 40,
          ),
          padding: EdgeInsets.zero,
          icon: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark
                  ? Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.06)
                  : Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.06),
            ),
            child: const Icon(Icons.arrow_back, size: 24),
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: LocaleProvider.tr('information'),
            onPressed: _showLoginInfoDialog,
            icon: const Icon(Icons.info_outline_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _showProgress
                ? LinearProgressIndicator(
                    key: const ValueKey('yt_cookie_login_progress'),
                    value: _progress >= 100 ? null : _progress / 100,
                  )
                : const SizedBox.shrink(
                    key: ValueKey('yt_cookie_login_progress_hidden'),
                  ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: _buildYtLoginUri(),
                headers: _buildInitialWebHeaders(),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                clearCache: false,
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
              ),
              onLoadStart: (controller, url) {
                setState(() {
                  _showProgress = true;
                });
                unawaited(_tryFinishWithCookies(url?.uriValue));
              },
              onLoadStop: (controller, url) async {
                if (!mounted) return;
                setState(() {
                  _showProgress = false;
                  _progress = 100;
                });
                await _tryFinishWithCookies(url?.uriValue);
              },
              onProgressChanged: (controller, progress) {
                if (!mounted) return;
                setState(() {
                  _showProgress = progress < 100;
                  _progress = progress;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> clearYtWebViewSessionData() async {
  try {
    await CookieManager.instance().deleteAllCookies();
  } catch (_) {
    // Ignorar; intentaremos limpiar otros almacenamientos.
  }

  try {
    final webStorage = WebStorageManager.instance();
    await webStorage.deleteAllData();
  } catch (_) {
    // Algunos entornos no soportan esta limpieza completa.
  }
}
