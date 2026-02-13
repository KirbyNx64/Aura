import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/notifiers.dart';
import 'package:music/utils/theme_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:music/screens/home/dependencies_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _launchUrl(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
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
                    TranslatedText(
                      'info',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TranslatedText(
                        'app_description',
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
                          child: TranslatedText(
                            'ok',
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: colorSchemeNotifier,
      builder: (context, colorScheme, child) {
        final isAmoled = colorScheme == AppColorScheme.amoled;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
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
            title: Text(
              LocaleProvider.tr('about'),
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            actions: [
              IconButton(
                icon: Icon(Icons.info_outline_rounded, size: 26),
                onPressed: () => _showInfoDialog(context),
                tooltip: LocaleProvider.tr('info'),
              ),
            ],
          ),
          body: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // App Icon with premium glow/shadow
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(shape: BoxShape.circle),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        'assets/icon.png',
                        width: 80,
                        height: 80,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // App Name
                const Text(
                  'Aura Music',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                // Version
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final version = snapshot.data?.version ?? '...';
                    final buildNumber = snapshot.data?.buildNumber ?? '';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isAmoled
                            ? Colors.white
                            : Theme.of(context).colorScheme.tertiary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${LocaleProvider.tr('version')}: $version ($buildNumber)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isAmoled
                              ? Colors.black
                              : Theme.of(context).colorScheme.onTertiary,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 32),

                // Information
                Row(
                  children: [
                    const SizedBox(width: 14),
                    TranslatedText(
                      'information',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Developer Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20),
                      topRight: Radius.circular(20),
                      bottomLeft: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: ListTile(
                    leading: Icon(
                      Icons.person_outline_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('developer'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      'KirbyNx64',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Telegram Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                  child: ListTile(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () => _launchUrl('https://t.me/kirby_limon'),
                    leading: Icon(
                      Icons.telegram,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: const Text(
                      'Telegram',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('contact_telegram'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  ),
                ),
                const SizedBox(height: 4),
                // GitHub Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                  child: ListTile(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () =>
                        _launchUrl('https://github.com/KirbyNx64/Aura'),
                    leading: Icon(
                      Icons.code_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      'GitHub',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('view_on_github'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  ),
                ),
                const SizedBox(height: 4),
                // Issues Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                  child: ListTile(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    onTap: () =>
                        _launchUrl('https://github.com/KirbyNx64/Aura/issues'),
                    leading: Icon(
                      Icons.bug_report_outlined,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('issues'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('report_issues'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  ),
                ),
                const SizedBox(height: 4),
                // Flutter Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(4)),
                  ),
                  child: ListTile(
                    leading: Icon(
                      Symbols.flutter,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('flutter_version'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      '3.41.0 • stable • Dart 3.11.0',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Dependencies Card
                Card(
                  color: isAmoled && isDark
                      ? Colors.white.withAlpha(20)
                      : isDark
                      ? Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.06)
                      : Theme.of(
                          context,
                        ).colorScheme.secondary.withValues(alpha: 0.07),
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(4),
                      topRight: Radius.circular(4),
                      bottomLeft: Radius.circular(20),
                      bottomRight: Radius.circular(20),
                    ),
                  ),
                  child: ListTile(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        PageRouteBuilder(
                          pageBuilder:
                              (context, animation, secondaryAnimation) =>
                                  const DependenciesScreen(),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                const begin = Offset(1.0, 0.0);
                                const end = Offset.zero;
                                const curve = Curves.ease;
                                final tween = Tween(
                                  begin: begin,
                                  end: end,
                                ).chain(CurveTween(curve: curve));
                                return SlideTransition(
                                  position: animation.drive(tween),
                                  child: child,
                                );
                              },
                        ),
                      );
                    },
                    leading: Icon(
                      Icons.extension_rounded,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    title: Text(
                      LocaleProvider.tr('dependencies'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      LocaleProvider.tr('view_dependencies'),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 24),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
