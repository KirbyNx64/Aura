import 'package:flutter/material.dart';
import 'package:music/l10n/locale_provider.dart';
import 'package:music/utils/yt_search/service.dart';
import 'package:music/utils/yt_search/search_history.dart';
import 'dart:async';

class SearchSuggestionsWidget extends StatefulWidget {
  final String query;
  final Function(String) onSuggestionSelected;
  final VoidCallback? onClearHistory;

  const SearchSuggestionsWidget({
    super.key,
    required this.query,
    required this.onSuggestionSelected,
    this.onClearHistory,
  });

  @override
  State<SearchSuggestionsWidget> createState() => _SearchSuggestionsWidgetState();
}

class _SearchSuggestionsWidgetState extends State<SearchSuggestionsWidget> {
  List<String> _suggestions = [];
  List<String> _historySuggestions = [];
  // Eliminado el spinner y timer

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  @override
  void didUpdateWidget(SearchSuggestionsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      _loadSuggestions();
    }
  }

  Future<void> _loadSuggestions() async {
    if (widget.query.trim().isEmpty) {
      setState(() {
        _suggestions = [];
      });
      _loadHistorySuggestions();
      return;
    }

    // Ya no se requiere _loading

    try {
      // Solo cargar sugerencias de YouTube Music cuando hay texto
      final ytSuggestions = await getSearchSuggestion(widget.query);
      
      if (mounted) {
        setState(() {
          _suggestions = ytSuggestions;
          _historySuggestions = []; // No mostrar historial cuando hay sugerencias
        });
      }
    } catch (e) {
      // No es necesario setState para _loading
    }
  }

  Future<void> _loadHistorySuggestions() async {
    try {
      final history = await SearchHistory.getHistory();
      setState(() {
        _historySuggestions = history;
      });
    } catch (e) {
      // Error silencioso
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) {
      return _buildHistorySection(context);
    }

    // Ya no hay spinner ni indicador de carga

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sugerencias de YouTube Music
        if (_suggestions.isNotEmpty) ...[
          _buildSectionHeader(
            context,
            LocaleProvider.tr('suggestions'),
            Icons.search,
          ),
          ..._suggestions.take(5).map((suggestion) => _buildSuggestionTile(
            context,
            suggestion,
            false, // No es del historial
          )),
        ],
        // Si no hay sugerencias, no mostrar nada
      ],
    );
  }

  Widget _buildHistorySection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_historySuggestions.isNotEmpty) ...[
          Row(
            children: [
              _buildSectionHeader(
                context,
                LocaleProvider.tr('recent_searches'),
                Icons.history,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await SearchHistory.clearHistory();
                  _loadHistorySuggestions();
                  widget.onClearHistory?.call();
                },
                icon: const Icon(Icons.clear_all, size: 16),
                label: Text(
                  LocaleProvider.tr('clear_history'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          ..._historySuggestions.take(7).map((suggestion) => _buildSuggestionTile(
            context,
            suggestion,
            true, // Es del historial
          )),
        ] else ...[
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    LocaleProvider.tr('no_recent_searches'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionTile(BuildContext context, String suggestion, bool isFromHistory) {
    return ListTile(
      dense: true,
      leading: Icon(
        isFromHistory ? Icons.history : Icons.search,
        size: 20,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      ),
      title: Text(
        suggestion,
        style: const TextStyle(fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        widget.onSuggestionSelected(suggestion);
      },
      trailing: isFromHistory
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: LocaleProvider.tr('remove'),
              onPressed: () async {
                await SearchHistory.removeFromHistory(suggestion);
                _loadHistorySuggestions();
                setState(() {});
              },
            )
          : null,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
} 