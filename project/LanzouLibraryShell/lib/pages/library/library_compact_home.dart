import 'package:flutter/material.dart';

import '../../config/library_config.dart';
import '../../controllers/library_controller.dart';
import '../../shared/app_listenable_selector.dart';
import 'library_navigation.dart';

class LibraryCompactHome extends StatelessWidget {
  const LibraryCompactHome({
    super.key,
    required this.controller,
    required this.searchController,
    required this.searchFocusNode,
    required this.onSearch,
    required this.onOpenSource,
    required this.onOpenUrl,
  });

  final LibraryController controller;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onSearch;
  final ValueChanged<LibrarySource> onOpenSource;
  final ValueChanged<String> onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final config = controller.config;
    final useSourceList = _preferSourceList(context);
    return CustomScrollView(
      key: const Key('compact-home-scroll'),
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 72)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
              child: Semantics(
                header: true,
                label: config.identity.displayName,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LibraryBrandLogo(config: config, size: 64),
                    const SizedBox(width: 18),
                    Flexible(
                      child: ExcludeSemantics(
                        child: Text(
                          config.identity.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (config.home.splashImage.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    config.home.splashImage,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0xFFE9EEF8),
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (config.home.splashText.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(config.home.splashText),
                ),
              ),
            ),
          ),
        if (config.home.carouselImages.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 160,
              child: ListView.separated(
                key: const Key('home-carousel'),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                scrollDirection: Axis.horizontal,
                itemCount: config.home.carouselImages.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      config.home.carouselImages[index],
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: Color(0xFFE9EEF8),
                        child: Center(child: Icon(Icons.broken_image_outlined)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (config.home.announcementUrl.isNotEmpty ||
            config.home.webPages.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: Column(
                children: [
                  if (config.home.announcementUrl.isNotEmpty)
                    ListTile(
                      key: const Key('home-remote-announcement'),
                      leading: const Icon(Icons.campaign_outlined),
                      title: const Text('远程公告'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => onOpenUrl(config.home.announcementUrl),
                    ),
                  for (final page in config.home.webPages)
                    ListTile(
                      key: ValueKey('home-web-${page.name}'),
                      leading: page.icon.isEmpty
                          ? const Icon(Icons.web_outlined)
                          : Image.network(
                              page.icon,
                              width: 28,
                              height: 28,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.web_outlined),
                            ),
                      title: Text(page.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => onOpenUrl(page.url),
                    ),
                ],
              ),
            ),
          ),
        if (config.features.search)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 56, 20, 34),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: searchController,
                builder: (context, value, _) => SearchBar(
                  key: const Key('compact-home-search'),
                  controller: searchController,
                  focusNode: searchFocusNode,
                  hintText: '搜索全部来源',
                  leading: const Icon(Icons.search_rounded),
                  trailing: [
                    if (value.text.isNotEmpty)
                      IconButton(
                        tooltip: '清除搜索',
                        onPressed: searchController.clear,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    IconButton(
                      tooltip: '开始搜索',
                      onPressed: value.text.trim().isEmpty
                          ? null
                          : () => onSearch(value.text),
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ],
                  textInputAction: TextInputAction.search,
                  onSubmitted: onSearch,
                ),
              ),
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text('软件源', style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 28),
          sliver: useSourceList
              ? SliverList.builder(
                  key: const Key('compact-home-source-list'),
                  itemCount: config.sources.length,
                  itemBuilder: (context, index) {
                    final source = config.sources[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _HomeSourceEntry(
                        key: ValueKey('home-source-${source.sourceId}'),
                        source: source,
                        onTap: () => onOpenSource(source),
                      ),
                    );
                  },
                )
              : SliverGrid.builder(
                  key: const Key('compact-home-source-grid'),
                  itemCount: config.sources.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisExtent: 88,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final source = config.sources[index];
                    return _HomeSourceEntry(
                      key: ValueKey('home-source-${source.sourceId}'),
                      source: source,
                      onTap: () => onOpenSource(source),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class LibrarySourceOverview extends StatelessWidget {
  const LibrarySourceOverview({
    super.key,
    required this.controller,
    required this.onOpenSource,
  });

  final LibraryController controller;
  final ValueChanged<LibrarySource> onOpenSource;

  @override
  Widget build(BuildContext context) {
    final sources = controller.config.sources;
    final useSourceList = _preferSourceList(context);
    return AppListenableSelector<String?>(
      listenable: controller,
      selector: () => controller.selectedSource?.sourceId,
      builder: (context, selectedSourceId, _) => CustomScrollView(
        key: const Key('compact-source-overview'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '全部来源 · ${sources.length}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
            sliver: useSourceList
                ? SliverList.builder(
                    key: const Key('compact-source-overview-list'),
                    itemCount: sources.length,
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _OverviewSourceEntry(
                            source: source,
                            selected: source.sourceId == selectedSourceId,
                            onTap: () => onOpenSource(source),
                          ),
                          if (index < sources.length - 1)
                            const Divider(indent: 48, height: 1),
                        ],
                      );
                    },
                  )
                : SliverGrid.builder(
                    key: const Key('compact-source-overview-grid'),
                    itemCount: sources.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 116,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      return _OverviewSourceEntry(
                        source: source,
                        selected: source.sourceId == selectedSourceId,
                        onTap: () => onOpenSource(source),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HomeSourceEntry extends StatelessWidget {
  const _HomeSourceEntry({
    super.key,
    required this.source,
    required this.onTap,
  });

  final LibrarySource source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: _sourceSemanticLabel(source),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    source.recommended
                        ? Icons.star_rounded
                        : Icons.folder_outlined,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      source.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool _preferSourceList(BuildContext context) {
  final media = MediaQuery.of(context);
  final availableWidth = media.size.width - media.padding.horizontal;
  return availableWidth < 360 || media.textScaler.scale(1) >= 1.35;
}

class _OverviewSourceEntry extends StatelessWidget {
  const _OverviewSourceEntry({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final LibrarySource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: _sourceSemanticLabel(source),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      source.recommended
                          ? Icons.star_rounded
                          : Icons.folder_outlined,
                      size: 20,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        source.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: selected ? colors.primary : colors.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  source.searchable ? '可搜索' : '仅目录',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _sourceSemanticLabel(LibrarySource source) {
  final states = <String>[
    if (source.recommended) '推荐',
    source.searchable ? '可搜索' : '仅目录',
  ];
  return '${source.title}，${states.join('，')}';
}
