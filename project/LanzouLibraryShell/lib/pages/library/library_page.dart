import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/library_config.dart';
import '../../controllers/library_controller.dart';
import '../../models/library_item.dart';
import '../../repositories/library_remote_content_repository.dart';
import '../../services/download_coordinator.dart';
import '../../services/library_core.dart';
import '../../services/link_opener.dart';
import '../../shared/app_listenable_selector.dart';
import '../../shared/app_motion.dart';
import '../downloads/downloads_page.dart';
import 'library_compact_home.dart';
import 'library_content.dart';
import 'library_detail.dart';
import 'library_navigation.dart';
import 'library_personal_page.dart';
import 'library_source_picker.dart';

const _compactBreakpoint = 720.0;
const _masterDetailBreakpoint = 1200.0;

/// Library route design contract:
/// - Compact: a real brand/search home, source/directory destination and the
///   feature-gated, persisted download history share one Material 3
///   NavigationBar.
/// - Medium/expanded: a custom lazy source pane keeps the same
///   controller-backed source, directory, search, download history and detail
///   tree; expanded adds the persistent detail.
/// - Surfaces: source/file grids and directory rows are direct lazy flows with
///   state layers, never one Card per item.
/// - Motion: every destination, source, content state, selection, detail and
///   insertion uses [AppMotion]; reduced motion resolves every duration to zero.
/// - Accessibility: semantic 48dp actions, Android back, Windows hover/focus,
///   Ctrl+F, F5 and Escape remain available without motion as a state carrier.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.config,
    required this.core,
    required this.linkOpener,
    this.remoteContent = const UnavailableLibraryRemoteContentRepository(),
    this.downloads,
    this.debugOnShellBuild,
  });

  final LibraryConfig config;
  final LibraryCore core;
  final LinkOpener linkOpener;
  final LibraryRemoteContentRepository remoteContent;
  final DownloadCoordinator? downloads;

  /// Test-only hook used to prove that controller notifications stay inside
  /// their owning pane instead of rebuilding the adaptive app shell.
  @visibleForTesting
  final VoidCallback? debugOnShellBuild;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

enum _CompactDestination { home, directory, downloads }

class _LibraryPageState extends State<LibraryPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'library-search');
  final FocusNode _downloadSearchFocusNode = FocusNode(
    debugLabel: 'download-history-search',
  );
  late final LibraryController _controller;
  _CompactDestination _compactDestination = _CompactDestination.home;
  bool _compactSourceOpen = false;
  bool _wideDownloadsSelected = false;
  LibrarySearchViewSnapshot? _sourceReturnSnapshot;
  double _directoryScrollOffset = 0;
  double _sourceReturnScrollOffset = 0;
  String? _restoredSearchQuery;
  double _restoredSearchScrollOffset = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.config.home.visible) {
      _compactDestination = _CompactDestination.directory;
    }
    _controller = LibraryController(
      config: widget.config,
      core: widget.core,
      downloads: widget.downloads,
    );
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKeyEvent);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    _searchFocusNode.dispose();
    _downloadSearchFocusNode.dispose();
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      widget.debugOnShellBuild?.call();
      return true;
    }());
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _compactBreakpoint;
        final masterDetail = constraints.maxWidth >= _masterDetailBreakpoint;
        final scaffold = Scaffold(
          appBar: compact
              ? _buildCompactAppBar()
              : _WideLibraryAppBar(
                  controller: _controller,
                  config: widget.config,
                  showingDownloads: _wideDownloadsSelected,
                  onOpenOfficial: _openOfficial,
                  onChooseSource: _showSourcePicker,
                ),
          body: SafeArea(
            child: compact
                ? _buildCompactBody()
                : Row(
                    children: [
                      LibrarySourceRail(
                        controller: _controller,
                        extended: masterDetail,
                        downloadsEnabled: widget.config.features.download,
                        downloadsSelected: _wideDownloadsSelected,
                        onSourceSelected: _selectWideSource,
                        onDownloadsSelected: _selectWideDownloads,
                      ),
                      const VerticalDivider(),
                      Expanded(child: _buildWideWorkspace(masterDetail)),
                    ],
                  ),
          ),
          bottomNavigationBar: compact ? _buildCompactNavigationBar() : null,
        );
        return _LibraryBackScope(
          controller: _controller,
          hasLocalBack:
              (compact && _compactDestination != _compactRoot) ||
              (!compact && _wideDownloadsSelected) ||
              _sourceReturnSnapshot != null,
          onBack: _handleBack,
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _FocusSearchIntent(),
              SingleActivator(LogicalKeyboardKey.f5): _RefreshIntent(),
              SingleActivator(LogicalKeyboardKey.escape): _NavigateBackIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
                  onInvoke: (_) {
                    _focusSearch(compact);
                    return null;
                  },
                ),
                _RefreshIntent: CallbackAction<_RefreshIntent>(
                  onInvoke: (_) {
                    if (_controller.status != LibraryContentStatus.loading &&
                        widget.config.features.browse &&
                        (!compact || _compactSourceOpen) &&
                        !_wideDownloadsSelected) {
                      _controller.refresh();
                    }
                    return null;
                  },
                ),
                _NavigateBackIntent: CallbackAction<_NavigateBackIntent>(
                  onInvoke: (_) {
                    _handleBack();
                    return null;
                  },
                ),
              },
              child: Focus(
                autofocus: true,
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: scaffold,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget? _buildCompactAppBar() {
    if (_compactDestination == _CompactDestination.home ||
        _compactDestination == _CompactDestination.downloads) {
      return null;
    }
    return _CompactLibraryAppBar(
      controller: _controller,
      showingSource: _compactSourceOpen,
      officialUrl: widget.config.branding.officialUrl,
      onBack: _handleBack,
      onOpenOfficial: _openOfficial,
      onChooseSource: _showSourcePicker,
    );
  }

  Widget _buildCompactBody() {
    late final String pageKey;
    late final Widget page;
    if (_compactDestination == _CompactDestination.home) {
      pageKey = 'home';
      page = LibraryCompactHome(
        controller: _controller,
        searchController: _searchController,
        searchFocusNode: _searchFocusNode,
        remoteContent: widget.remoteContent,
        onSearch: _searchFromHome,
        onOpenSource: _openCompactSource,
        onOpenUrl: (url) => unawaited(widget.linkOpener.open(url)),
      );
    } else if (_compactDestination == _CompactDestination.downloads) {
      pageKey = 'personal';
      page = LibraryPersonalPage(
        config: widget.config,
        controller: _controller,
        searchFocusNode: _downloadSearchFocusNode,
        onOpenOfficial: _openOfficial,
      );
    } else if (!_compactSourceOpen) {
      pageKey = 'source-overview';
      page = LibrarySourceOverview(
        controller: _controller,
        onOpenSource: _openCompactSource,
      );
    } else {
      pageKey = 'source-directory';
      page = LibraryContentPane(
        key: const Key('compact-source-directory'),
        controller: _controller,
        searchController: _searchController,
        searchFocusNode: _searchFocusNode,
        compactGrid: true,
        showPersistentDetails: false,
        onShowTransientDetails: _showTransientDetails,
        onOpenItemSource: _openSearchResultSource,
        restoreScrollForQuery: _restoredSearchQuery,
        restoredScrollOffset: _restoredSearchScrollOffset,
        onDirectoryScrollOffsetChanged: _rememberDirectoryScrollOffset,
      );
    }
    return AppMotionEntrance(
      key: ValueKey('compact-page-$pageKey'),
      duration: AppMotion.emphasized,
      child: page,
    );
  }

  List<_CompactDestination> get _compactDestinations => [
    if (widget.config.home.visible) _CompactDestination.home,
    _CompactDestination.directory,
    _CompactDestination.downloads,
  ];

  _CompactDestination get _compactRoot => widget.config.home.visible
      ? _CompactDestination.home
      : _CompactDestination.directory;

  Widget _buildCompactNavigationBar() => NavigationBar(
    key: const Key('compact-navigation-bar'),
    selectedIndex: _compactDestinations.indexOf(_compactDestination),
    animationDuration: AppMotion.duration(context, AppMotion.standard),
    onDestinationSelected: _selectCompactDestination,
    destinations: [
      if (widget.config.home.visible)
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '首页',
        ),
      const NavigationDestination(
        icon: Icon(Icons.folder_outlined),
        selectedIcon: Icon(Icons.folder_rounded),
        label: '列表',
      ),
      const NavigationDestination(
        icon: Icon(Icons.person_outline),
        selectedIcon: Icon(Icons.person),
        label: '个人',
      ),
    ],
  );

  Widget _buildWideWorkspace(bool masterDetail) {
    if (_wideDownloadsSelected) {
      return AppMotionEntrance(
        key: const ValueKey('wide-downloads'),
        duration: AppMotion.emphasized,
        child: DownloadsPage(
          controller: _controller,
          searchFocusNode: _downloadSearchFocusNode,
        ),
      );
    }
    final content = LibraryContentPane(
      key: const Key('library-content-pane'),
      controller: _controller,
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      showPersistentDetails: masterDetail,
      onShowTransientDetails: _showTransientDetails,
      onOpenItemSource: _openSearchResultSource,
      restoreScrollForQuery: _restoredSearchQuery,
      restoredScrollOffset: _restoredSearchScrollOffset,
      onDirectoryScrollOffsetChanged: _rememberDirectoryScrollOffset,
    );
    if (!masterDetail) return content;
    return Row(
      key: const Key('master-detail-layout'),
      children: [
        Expanded(child: content),
        const VerticalDivider(),
        SizedBox(
          key: const Key('persistent-detail-pane'),
          width: 400,
          child: LibraryDetailPane(controller: _controller, compact: false),
        ),
      ],
    );
  }

  bool _canHandleBack(bool compact) {
    if (compact && _compactDestination != _compactRoot) return true;
    if (!compact && _wideDownloadsSelected) return true;
    if (_sourceReturnSnapshot != null) return true;
    return _controller.selectedItem != null ||
        _controller.isSearching ||
        _controller.breadcrumbs.length > 1;
  }

  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        !_canHandleBack(_isCompact)) {
      return KeyEventResult.ignored;
    }
    _handleBack();
    return KeyEventResult.handled;
  }

  bool get _isCompact =>
      mounted && MediaQuery.sizeOf(context).width < _compactBreakpoint;

  void _handleBack() {
    if (_wideDownloadsSelected && !_isCompact) {
      setState(() => _wideDownloadsSelected = false);
      return;
    }
    if (_controller.selectedItem != null) {
      _controller.clearSelection();
      return;
    }
    if (_controller.isSearching) {
      _searchController.clear();
      setState(() {
        _restoredSearchQuery = null;
        _restoredSearchScrollOffset = 0;
        _directoryScrollOffset = 0;
      });
      unawaited(_controller.search(''));
      return;
    }
    if (_controller.breadcrumbs.length > 1 &&
        _controller.status != LibraryContentStatus.loading) {
      unawaited(_controller.openBreadcrumb(_controller.breadcrumbs.length - 2));
      return;
    }
    final returnSnapshot = _sourceReturnSnapshot;
    if (returnSnapshot != null) {
      final returnQuery = returnSnapshot.query;
      _searchController.value = TextEditingValue(
        text: returnQuery,
        selection: TextSelection.collapsed(offset: returnQuery.length),
      );
      setState(() {
        _sourceReturnSnapshot = null;
        _restoredSearchQuery = returnQuery;
        _restoredSearchScrollOffset = _sourceReturnScrollOffset;
        _directoryScrollOffset = _sourceReturnScrollOffset;
        _wideDownloadsSelected = false;
        if (_isCompact) {
          _compactDestination = _CompactDestination.directory;
          _compactSourceOpen = true;
        }
      });
      _controller.restoreSearchView(returnSnapshot);
      return;
    }
    if (_isCompact && _compactSourceOpen) {
      setState(() => _compactSourceOpen = false);
      return;
    }
    if (_isCompact && _compactDestination != _compactRoot) {
      setState(() => _compactDestination = _compactRoot);
    }
  }

  void _focusSearch(bool compact) {
    if ((compact && _compactDestination == _CompactDestination.downloads) ||
        (!compact && _wideDownloadsSelected)) {
      _downloadSearchFocusNode.requestFocus();
      return;
    }
    if (compact &&
        (_compactDestination != _CompactDestination.home &&
            !_compactSourceOpen)) {
      setState(() => _compactDestination = _CompactDestination.home);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _searchFocusNode.requestFocus(),
      );
      return;
    }
    if (widget.config.features.search) _searchFocusNode.requestFocus();
  }

  void _selectCompactDestination(int index) {
    final next = _compactDestinations[index];
    if (next == _CompactDestination.home) {
      _resetSearch();
      setState(() {
        _compactDestination = next;
        _compactSourceOpen = false;
      });
      return;
    }
    if (next == _CompactDestination.downloads) {
      _resetSearch();
      setState(() {
        _compactDestination = next;
        _compactSourceOpen = false;
      });
      return;
    }
    _resetSearch();
    setState(() {
      _compactDestination = next;
      _compactSourceOpen = false;
    });
  }

  void _searchFromHome(String value) {
    final query = value.trim();
    if (query.isEmpty || !widget.config.features.search) return;
    setState(() {
      _sourceReturnSnapshot = null;
      _restoredSearchQuery = null;
      _restoredSearchScrollOffset = 0;
      _directoryScrollOffset = 0;
      _compactDestination = _CompactDestination.directory;
      _compactSourceOpen = true;
    });
    unawaited(_controller.search(query));
  }

  void _openCompactSource(LibrarySource source) {
    _searchController.clear();
    setState(() {
      _sourceReturnSnapshot = null;
      _restoredSearchQuery = null;
      _restoredSearchScrollOffset = 0;
      _directoryScrollOffset = 0;
      _compactDestination = _CompactDestination.directory;
      _compactSourceOpen = true;
    });
    unawaited(_controller.selectSource(source));
  }

  void _selectWideSource(LibrarySource source) {
    if (_wideDownloadsSelected || _sourceReturnSnapshot != null) {
      setState(() {
        _wideDownloadsSelected = false;
        _sourceReturnSnapshot = null;
        _restoredSearchQuery = null;
        _restoredSearchScrollOffset = 0;
        _directoryScrollOffset = 0;
      });
    }
    _controller.selectSource(source);
  }

  void _selectWideDownloads() {
    if (_wideDownloadsSelected) return;
    _controller.clearSelection();
    setState(() {
      _sourceReturnSnapshot = null;
      _restoredSearchQuery = null;
      _restoredSearchScrollOffset = 0;
      _directoryScrollOffset = 0;
      _wideDownloadsSelected = true;
    });
  }

  void _resetSearch() {
    _sourceReturnSnapshot = null;
    _restoredSearchQuery = null;
    _restoredSearchScrollOffset = 0;
    _directoryScrollOffset = 0;
    _searchController.clear();
    if (_controller.isSearching) unawaited(_controller.search(''));
  }

  void _openSearchResultSource(LibraryItem item) {
    final source = widget.config.sourceById(item.sourceId);
    final returnSnapshot = _controller.captureSearchView();
    if (source == null || returnSnapshot == null) {
      return;
    }
    final returnQuery = returnSnapshot.query;
    _searchController.value = TextEditingValue(
      text: returnQuery,
      selection: TextSelection.collapsed(offset: returnQuery.length),
    );
    setState(() {
      _sourceReturnSnapshot = returnSnapshot;
      _sourceReturnScrollOffset = _directoryScrollOffset;
      _restoredSearchQuery = null;
      _restoredSearchScrollOffset = 0;
      _directoryScrollOffset = 0;
      _wideDownloadsSelected = false;
      if (_isCompact) {
        _compactDestination = _CompactDestination.directory;
        _compactSourceOpen = true;
      }
    });
    unawaited(_controller.selectSource(source));
  }

  void _rememberDirectoryScrollOffset(double offset) {
    _directoryScrollOffset = offset;
  }

  Future<void> _showSourcePicker() async {
    final source = await showLibrarySourcePicker(
      context: context,
      sources: widget.config.sources,
      selectedSource: _controller.selectedSource,
    );
    if (!mounted || source == null) return;
    if (_isCompact) {
      _openCompactSource(source);
    } else {
      _selectWideSource(source);
    }
  }

  Future<void> _showTransientDetails(LibraryItem item) async {
    _controller.selectItem(item);
    final duration = AppMotion.duration(context, AppMotion.emphasized);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: AnimationStyle(
        duration: duration,
        reverseDuration: AppMotion.duration(context, AppMotion.standard),
      ),
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.86,
        child: LibraryDetailPane(controller: _controller, compact: true),
      ),
    );
    if (mounted && _controller.selectedItem?.stableKey == item.stableKey) {
      _controller.clearSelection();
    }
  }

  Future<void> _openOfficial() async {
    try {
      await widget.linkOpener.open(widget.config.branding.officialUrl);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开官网，请稍后重试')));
    }
  }
}

class _LibraryBackScope extends StatelessWidget {
  const _LibraryBackScope({
    required this.controller,
    required this.hasLocalBack,
    required this.onBack,
    required this.child,
  });

  final LibraryController controller;
  final bool hasLocalBack;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<
      ({String? selectedKey, bool searching, int depth})
    >(
      listenable: controller,
      selector: () => (
        selectedKey: controller.selectedItem?.stableKey,
        searching: controller.isSearching,
        depth: controller.breadcrumbs.length,
      ),
      child: child,
      builder: (context, value, child) {
        final canHandle =
            hasLocalBack ||
            value.selectedKey != null ||
            value.searching ||
            value.depth > 1;
        return PopScope<void>(
          canPop: !canHandle,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) onBack();
          },
          child: child!,
        );
      },
    );
  }
}

class _CompactLibraryAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _CompactLibraryAppBar({
    required this.controller,
    required this.showingSource,
    required this.officialUrl,
    required this.onBack,
    required this.onOpenOfficial,
    required this.onChooseSource,
  });

  final LibraryController controller;
  final bool showingSource;
  final String officialUrl;
  final VoidCallback onBack;
  final VoidCallback onOpenOfficial;
  final VoidCallback onChooseSource;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<String>(
      listenable: controller,
      selector: () => showingSource
          ? controller.isSearching
                ? '搜索结果'
                : controller.selectedSource?.title ?? '目录'
          : '目录',
      builder: (context, title, _) => AppBar(
        automaticallyImplyLeading: false,
        leading: showingSource
            ? IconButton(
                key: const Key('compact-source-back'),
                tooltip: '返回来源列表',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        titleSpacing: showingSource ? 4 : 20,
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('compact-source-picker-action'),
            tooltip: '选择来源',
            onPressed: onChooseSource,
            icon: const Icon(Icons.source_rounded),
          ),
          if (officialUrl.isNotEmpty)
            IconButton(
              tooltip: '官网',
              onPressed: onOpenOfficial,
              icon: const Icon(Icons.public_rounded),
            ),
        ],
      ),
    );
  }
}

class _WideLibraryAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _WideLibraryAppBar({
    required this.controller,
    required this.config,
    required this.showingDownloads,
    required this.onOpenOfficial,
    required this.onChooseSource,
  });

  final LibraryController controller;
  final LibraryConfig config;
  final bool showingDownloads;
  final VoidCallback onOpenOfficial;
  final VoidCallback onChooseSource;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppListenableSelector<LibraryContentStatus>(
      listenable: controller,
      selector: () => controller.status,
      builder: (context, status, _) => AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 20,
        title: Text(
          showingDownloads ? '下载' : config.identity.displayName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!showingDownloads)
            IconButton(
              key: const Key('wide-source-picker-action'),
              tooltip: '选择来源',
              onPressed: onChooseSource,
              icon: const Icon(Icons.source_rounded),
            ),
          if (config.branding.officialUrl.isNotEmpty)
            IconButton(
              tooltip: '官网',
              onPressed: onOpenOfficial,
              icon: const Icon(Icons.public_rounded),
            ),
          if (config.features.browse && !showingDownloads)
            IconButton(
              tooltip: '刷新',
              onPressed: status == LibraryContentStatus.loading
                  ? null
                  : controller.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _NavigateBackIntent extends Intent {
  const _NavigateBackIntent();
}
