import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../config/library_config.dart';
import '../../shared/app_motion.dart';

/// Opens the source catalogue as a responsive, keyboard-accessible Material
/// dialog. Categories are derived only from the real source contract; the
/// shell does not invent or persist a parallel classification model.
Future<LibrarySource?> showLibrarySourcePicker({
  required BuildContext context,
  required List<LibrarySource> sources,
  LibrarySource? selectedSource,
}) {
  return showDialog<LibrarySource>(
    context: context,
    useSafeArea: true,
    animationStyle: AnimationStyle(
      duration: AppMotion.duration(context, AppMotion.emphasized),
      reverseDuration: AppMotion.duration(context, AppMotion.standard),
      curve: AppMotion.emphasizedCurve,
      reverseCurve: AppMotion.exitCurve,
    ),
    builder: (context) => _LibrarySourcePickerDialog(
      sources: sources,
      selectedSourceId: selectedSource?.sourceId,
    ),
  );
}

enum _SourceCategory { all, recommended, searchable, directoryOnly }

class _LibrarySourcePickerDialog extends StatefulWidget {
  const _LibrarySourcePickerDialog({
    required this.sources,
    required this.selectedSourceId,
  });

  final List<LibrarySource> sources;
  final String? selectedSourceId;

  @override
  State<_LibrarySourcePickerDialog> createState() =>
      _LibrarySourcePickerDialogState();
}

class _LibrarySourcePickerDialogState
    extends State<_LibrarySourcePickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  _SourceCategory _category = _SourceCategory.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableWidth = math.max(
      0.0,
      media.size.width - media.padding.horizontal - 32,
    );
    final availableHeight = math.max(
      0.0,
      media.size.height - media.padding.vertical - 32,
    );
    final dialogWidth = math.min(560.0, availableWidth);
    final dialogHeight = math.min(680.0, availableHeight);
    final filtered = _filteredSources();
    final colors = Theme.of(context).colorScheme;

    return Dialog(
      key: const Key('library-source-picker-dialog'),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.source_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '选择来源',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: SearchBar(
                key: const Key('source-picker-search'),
                controller: _searchController,
                hintText: '搜索来源',
                leading: const Icon(Icons.search_rounded),
                trailing: [
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _searchController,
                    builder: (context, value, _) => value.text.isEmpty
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: '清除来源搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ],
                onChanged: (_) => setState(() {}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
              child: Text(
                '分类',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _categoryChip(
                    _SourceCategory.all,
                    key: const Key('source-filter-all'),
                    label: '全部',
                  ),
                  _categoryChip(
                    _SourceCategory.recommended,
                    key: const Key('source-filter-recommended'),
                    label: '推荐',
                  ),
                  _categoryChip(
                    _SourceCategory.searchable,
                    key: const Key('source-filter-searchable'),
                    label: '可搜索',
                  ),
                  _categoryChip(
                    _SourceCategory.directoryOnly,
                    key: const Key('source-filter-directory'),
                    label: '仅目录',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '找到 ${filtered.length} 个来源',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Expanded(
              child: AppMotionEntrance(
                key: ValueKey(
                  'source-results-${_category.name}-${_searchController.text.trim().toLowerCase()}',
                ),
                duration: AppMotion.fast,
                offset: const Offset(0, 0.015),
                child: filtered.isEmpty
                    ? const _EmptySourceResults()
                    : Scrollbar(
                        child: ListView.separated(
                          key: const Key('source-picker-results'),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              const Divider(indent: 56, height: 1),
                          itemBuilder: (context, index) {
                            final source = filtered[index];
                            return _SourcePickerRow(
                              key: Key('source-picker-${source.sourceId}'),
                              source: source,
                              selected:
                                  source.sourceId == widget.selectedSourceId,
                              onTap: () => Navigator.of(context).pop(source),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _categoryChip(
    _SourceCategory category, {
    required Key key,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        key: key,
        label: Text(label),
        selected: _category == category,
        showCheckmark: true,
        onSelected: (_) => setState(() => _category = category),
      ),
    );
  }

  List<LibrarySource> _filteredSources() {
    final query = _searchController.text.trim().toLowerCase();
    return widget.sources
        .where((source) {
          final categoryMatches = switch (_category) {
            _SourceCategory.all => true,
            _SourceCategory.recommended => source.recommended,
            _SourceCategory.searchable => source.searchable,
            _SourceCategory.directoryOnly => !source.searchable,
          };
          if (!categoryMatches) return false;
          if (query.isEmpty) return true;
          return source.title.toLowerCase().contains(query) ||
              source.sourceId.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }
}

class _SourcePickerRow extends StatefulWidget {
  const _SourcePickerRow({
    super.key,
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final LibrarySource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SourcePickerRow> createState() => _SourcePickerRowState();
}

class _SourcePickerRowState extends State<_SourcePickerRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = widget.selected
        ? colors.secondaryContainer
        : _focused
        ? colors.secondaryContainer.withValues(alpha: 0.6)
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    final states = <String>[
      if (widget.source.recommended) '推荐',
      widget.source.searchable ? '可搜索' : '仅目录',
    ];
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.source.title}，${states.join('，')}',
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppMotion.fast),
          curve: AppMotion.enterCurve,
          color: background,
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              minTileHeight: 60,
              leading: Icon(
                widget.source.recommended
                    ? Icons.star_rounded
                    : Icons.folder_outlined,
                color: widget.selected
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
              title: Text(widget.source.title),
              subtitle: Text(states.join(' · ')),
              trailing: widget.selected
                  ? Icon(Icons.check_rounded, color: colors.primary)
                  : const Icon(Icons.chevron_right_rounded),
              onTap: widget.onTap,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySourceResults extends StatelessWidget {
  const _EmptySourceResults();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.source_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          const Text('没有匹配的来源'),
        ],
      ),
    ),
  );
}
