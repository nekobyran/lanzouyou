import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/cloud_item.dart';
import '../../services/cloud_service.dart';
import 'library_recipe.dart';

typedef LibraryCloudRecipeSaver =
    Future<void> Function(LibraryBuildRecipe recipe);

class LibraryCloudPartition {
  const LibraryCloudPartition({
    required this.folder,
    required this.index,
    required this.items,
  });

  final CloudItem folder;
  final int index;
  final List<CloudItem> items;

  String get name => folder.name;
  bool get isFull => items.length >= LibraryCloudContentController.partitionCap;
}

class LibraryCloudResource {
  const LibraryCloudResource({
    required this.item,
    required this.partition,
    this.urls = const <String>[],
  });

  final CloudItem item;
  final CloudItem partition;
  final List<String> urls;

  String? get preferredUrl => urls.isEmpty ? null : urls.first;
}

class LibraryCloudWebFolder {
  const LibraryCloudWebFolder({
    required this.item,
    required this.url,
    required this.icon,
  });

  final CloudItem item;
  final String url;
  final String icon;

  bool get valid => _isHttpsUrl(url) && (icon.isEmpty || _isHttpsUrl(icon));

  LibraryWebPageRecipe get recipe =>
      LibraryWebPageRecipe(name: item.name, url: url, icon: icon);
}

class LibraryCloudWorkspaceSnapshot {
  const LibraryCloudWorkspaceSnapshot({
    required this.imagePartitions,
    required this.textPartitions,
    required this.images,
    required this.documents,
    required this.webFolders,
    required this.rjkFolder,
    required this.urlFolder,
  });

  final List<LibraryCloudPartition> imagePartitions;
  final List<LibraryCloudPartition> textPartitions;
  final List<LibraryCloudResource> images;
  final List<LibraryCloudResource> documents;
  final List<LibraryCloudWebFolder> webFolders;
  final CloudItem? rjkFolder;
  final CloudItem? urlFolder;
}

class LibraryCloudContentController {
  LibraryCloudContentController({
    required this.cloudService,
    required LibraryBuildRecipe initialRecipe,
    required this.onRecipeChanged,
  }) : _recipe = initialRecipe;

  static const partitionCap = 50;
  static const _maxPages = 10000;

  final CloudService cloudService;
  final LibraryCloudRecipeSaver onRecipeChanged;

  LibraryBuildRecipe _recipe;
  LibraryCloudWorkspaceSnapshot? _snapshot;

  LibraryBuildRecipe get recipe => _recipe;
  LibraryCloudWorkspaceSnapshot? get snapshot => _snapshot;

  Future<LibraryCloudWorkspaceSnapshot> load() async {
    final rootId = _recipe.workspace.rootFolderId.trim();
    if (rootId.isEmpty) {
      throw const CloudFailure('workspace_unbound', '工程尚未绑定云端工作区');
    }
    final rootItems = await _listAll(rootId);
    final imageFolders = _numberedFolders(rootItems, 'img');
    final textFolders = _numberedFolders(rootItems, 'txt');
    final imagePartitions = await _loadPartitions(imageFolders);
    final textPartitions = await _loadPartitions(textFolders);
    final rjkFolder = _namedFolder(
      rootItems,
      _recipe.workspace.libraryFolderName,
    );
    final urlFolder = _namedFolder(rootItems, _recipe.workspace.webFolderName);
    final webItems = urlFolder == null
        ? const <CloudItem>[]
        : (await _listAll(
            urlFolder.id,
          )).where((item) => item.isFolder).toList();
    final webFolders = await Future.wait(
      webItems.map((item) async {
        final description = await cloudService.getDescription(item);
        return _parseWebFolder(item, description.description);
      }),
    );
    final snapshot = LibraryCloudWorkspaceSnapshot(
      imagePartitions: imagePartitions,
      textPartitions: textPartitions,
      images: _resources(imagePartitions),
      documents: _resources(textPartitions),
      webFolders: List.unmodifiable(webFolders),
      rjkFolder: rjkFolder,
      urlFolder: urlFolder,
    );
    _snapshot = snapshot;
    await _syncWebPages(snapshot);
    return snapshot;
  }

  Future<LibraryCloudResource> uploadImage(String path) =>
      _uploadToPartition(prefix: 'img', path: path);

  Future<LibraryCloudResource> uploadApkImage({
    required String apkPath,
    required String imagePath,
  }) async {
    final partition = await _writablePartition('img');
    final upload = await cloudService.upload(
      partition.folder.id,
      apkPath,
      kind: 'file',
    );
    final fileId = upload.id;
    if (fileId == null || fileId.isEmpty) {
      throw const CloudFailure('upload_identity_missing', '云端未返回上传文件标识，未绑定图片');
    }
    PreparedIcon? prepared;
    try {
      prepared = await cloudService.prepareIcon(imagePath);
      if (prepared.path.isEmpty || prepared.bytes >= 100000) {
        throw const CloudFailure('invalid_icon', '所选图片无法转换为有效图标');
      }
      await cloudService.setIcon(fileId, prepared.path);
    } finally {
      final preparedPath = prepared?.path;
      if (preparedPath != null && !_samePath(preparedPath, imagePath)) {
        try {
          final file = File(preparedPath);
          if (await file.exists()) await file.delete();
        } on Object {
          // Prepared icons are disposable cache files.
        }
      }
    }
    final refreshed = await load();
    final item =
        refreshed.images
            .where((resource) => resource.item.id == fileId)
            .firstOrNull
            ?.item ??
        CloudItem(id: fileId, name: upload.uploadedName, isFolder: false);
    return _resolveResource(item, partition.folder);
  }

  Future<void> applyImageToSplash(LibraryCloudResource resource) async {
    final url = await _usableResourceUrl(resource);
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(splashImage: url)),
    );
  }

  Future<void> appendCarouselImage(LibraryCloudResource resource) async {
    final url = await _usableResourceUrl(resource);
    final images = <String>[..._recipe.home.carouselImages];
    if (!images.contains(url)) images.add(url);
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(carouselImages: images)),
    );
  }

  Future<void> applyImageAsWebIcon(
    LibraryCloudResource resource,
    int pageIndex,
  ) async {
    if (pageIndex < 0 || pageIndex >= _recipe.home.webPages.length) {
      throw const CloudFailure('web_page_missing', '所选网页不存在');
    }
    final url = await _usableResourceUrl(resource);
    final pages = <LibraryWebPageRecipe>[..._recipe.home.webPages];
    final page = pages[pageIndex];
    pages[pageIndex] = LibraryWebPageRecipe(
      name: page.name,
      url: page.url,
      icon: url,
    );
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(webPages: pages)),
    );
  }

  Future<void> createAnnouncement({
    required String name,
    required String body,
  }) async {
    final safeName = _requiredName(name);
    final partition = await _writablePartition('txt');
    if (partition.items.any((item) => item.isFolder && item.name == safeName)) {
      throw const CloudFailure('already_exists', '文档目录中已有同名内容');
    }
    await cloudService.createFolder(
      partition.folder.id,
      safeName,
      description: body,
    );
    final items = await _listAll(partition.folder.id);
    final folder = items
        .where((item) => item.isFolder && item.name == safeName)
        .firstOrNull;
    if (folder == null) {
      throw const CloudFailure('create_unconfirmed', '云端未返回新建文档');
    }
    final info = await cloudService.shareInfo(folder);
    final url = _firstHttps([info.shareUrl, info.directUrl]);
    if (url == null) {
      throw const CloudFailure('public_url_missing', '新建文档没有可用的 HTTPS 地址');
    }
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(announcementUrl: url)),
    );
    await load();
  }

  Future<void> uploadAnnouncement(String path) async {
    final resource = await _uploadToPartition(prefix: 'txt', path: path);
    await useDocumentAsAnnouncement(resource);
  }

  Future<void> useDocumentAsAnnouncement(LibraryCloudResource resource) async {
    final resolved = resource.urls.isEmpty
        ? await _resolveResource(resource.item, resource.partition)
        : resource;
    final url = _firstHttps(resolved.urls);
    if (url == null) {
      throw const CloudFailure('public_url_missing', '该文档没有可用的 HTTPS 地址');
    }
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(announcementUrl: url)),
    );
  }

  Future<void> upsertWebPage({
    CloudItem? existing,
    required String name,
    required String url,
    String icon = '',
  }) async {
    final safeName = _requiredName(name);
    final safeUrl = url.trim();
    final safeIcon = icon.trim();
    if (!_isHttpsUrl(safeUrl) ||
        (safeIcon.isNotEmpty && !_isHttpsUrl(safeIcon))) {
      throw const CloudFailure('invalid_url', '网页地址和图标必须使用 HTTPS');
    }
    final snapshot = _snapshot ?? await load();
    final parent = snapshot.urlFolder;
    if (parent == null) {
      throw const CloudFailure('url_folder_missing', '工作区缺少 url 目录');
    }
    final description = [
      safeUrl,
      if (safeIcon.isNotEmpty) 'icon=$safeIcon',
    ].join('\n');
    if (existing == null) {
      if (snapshot.webFolders.any((folder) => folder.item.name == safeName)) {
        throw const CloudFailure('already_exists', 'url 目录中已有同名网页');
      }
      await cloudService.createFolder(
        parent.id,
        safeName,
        description: description,
      );
    } else {
      if (existing.name != safeName) {
        await cloudService.rename(existing, safeName);
      }
      await cloudService.setDescription(existing, description);
    }
    await load();
  }

  Future<LibraryCloudResource> _uploadToPartition({
    required String prefix,
    required String path,
  }) async {
    final partition = await _writablePartition(prefix);
    final upload = await cloudService.upload(
      partition.folder.id,
      path,
      kind: 'file',
    );
    final fileId = upload.id;
    if (fileId == null || fileId.isEmpty) {
      throw const CloudFailure('upload_identity_missing', '云端未返回上传文件标识');
    }
    final refreshed = await load();
    final resources = prefix == 'img' ? refreshed.images : refreshed.documents;
    final item =
        resources
            .where((resource) => resource.item.id == fileId)
            .firstOrNull
            ?.item ??
        CloudItem(id: fileId, name: upload.uploadedName, isFolder: false);
    return _resolveResource(item, partition.folder);
  }

  Future<LibraryCloudPartition> _writablePartition(String prefix) async {
    var snapshot = _snapshot ?? await load();
    var partitions = prefix == 'img'
        ? snapshot.imagePartitions
        : snapshot.textPartitions;
    for (final partition in partitions) {
      if (!partition.isFull) return partition;
    }
    final nextIndex = _nextContinuousIndex(partitions);
    final name = '$prefix$nextIndex';
    await cloudService.createFolder(_recipe.workspace.rootFolderId, name);
    snapshot = await load();
    partitions = prefix == 'img'
        ? snapshot.imagePartitions
        : snapshot.textPartitions;
    final created = partitions
        .where((partition) => partition.name == name)
        .firstOrNull;
    if (created == null) {
      throw CloudFailure('create_unconfirmed', '云端未返回新建分区 $name');
    }
    return created;
  }

  Future<LibraryCloudResource> _resolveResource(
    CloudItem item,
    CloudItem partition,
  ) async {
    final info = await cloudService.shareInfo(item);
    final urls = <String>[];
    for (final candidate in [item.iconUrl, info.directUrl, info.shareUrl]) {
      final value = candidate?.trim();
      if (value != null && _isHttpsUrl(value) && !urls.contains(value)) {
        urls.add(value);
      }
    }
    return LibraryCloudResource(
      item: item,
      partition: partition,
      urls: List.unmodifiable(urls),
    );
  }

  Future<String> _usableResourceUrl(LibraryCloudResource resource) async {
    final resolved = resource.urls.isEmpty
        ? await _resolveResource(resource.item, resource.partition)
        : resource;
    final url = resolved.preferredUrl;
    if (url == null) {
      throw const CloudFailure('public_url_missing', '该资源没有可用的 HTTPS 地址');
    }
    return url;
  }

  Future<List<LibraryCloudPartition>> _loadPartitions(
    List<({CloudItem folder, int index})> folders,
  ) async {
    final partitions = await Future.wait(
      folders.map((entry) async {
        final items = await _listAll(entry.folder.id);
        return LibraryCloudPartition(
          folder: entry.folder,
          index: entry.index,
          items: List.unmodifiable(items),
        );
      }),
    );
    return List.unmodifiable(partitions);
  }

  List<LibraryCloudResource> _resources(
    List<LibraryCloudPartition> partitions,
  ) => List.unmodifiable([
    for (final partition in partitions)
      for (final item in partition.items)
        LibraryCloudResource(
          item: item,
          partition: partition.folder,
          urls: [if (_isHttpsUrl(item.iconUrl ?? '')) item.iconUrl!],
        ),
  ]);

  Future<List<CloudItem>> _listAll(String folderId) async {
    final items = <CloudItem>[];
    for (var page = 1; page <= _maxPages; page++) {
      final result = await cloudService.listFolder(
        folderId,
        page: page,
        pageSize: partitionCap,
      );
      items.addAll(result.items);
      if (!result.hasMore) return items;
    }
    throw const CloudFailure('too_many_pages', '目录页数超过安全上限');
  }

  Future<void> _syncWebPages(LibraryCloudWorkspaceSnapshot snapshot) async {
    final pages = snapshot.webFolders
        .where((folder) => folder.valid)
        .map((folder) => folder.recipe)
        .toList(growable: false);
    if (_sameWebPages(_recipe.home.webPages, pages)) return;
    await _setRecipe(
      _recipe.copyWith(home: _recipe.home.copyWith(webPages: pages)),
    );
  }

  Future<void> _setRecipe(LibraryBuildRecipe recipe) async {
    await onRecipeChanged(recipe);
    _recipe = recipe;
  }

  static List<({CloudItem folder, int index})> _numberedFolders(
    List<CloudItem> items,
    String prefix,
  ) {
    final pattern = RegExp('^$prefix([1-9][0-9]*)\$');
    final folders = <({CloudItem folder, int index})>[];
    for (final item in items) {
      if (!item.isFolder) continue;
      final match = pattern.firstMatch(item.name);
      if (match == null) continue;
      folders.add((folder: item, index: int.parse(match.group(1)!)));
    }
    folders.sort((first, second) => first.index.compareTo(second.index));
    return folders;
  }

  static CloudItem? _namedFolder(List<CloudItem> items, String name) =>
      items.where((item) => item.isFolder && item.name == name).firstOrNull;

  static int _nextContinuousIndex(List<LibraryCloudPartition> partitions) {
    final indexes = partitions.map((partition) => partition.index).toSet();
    var index = 1;
    while (indexes.contains(index)) {
      index++;
    }
    return index;
  }
}

class LibraryCloudContentPage extends StatefulWidget {
  const LibraryCloudContentPage({
    required this.controller,
    this.pickFile,
    super.key,
  });

  final LibraryCloudContentController controller;
  final Future<String?> Function(FileType type, List<String>? extensions)?
  pickFile;

  @override
  State<LibraryCloudContentPage> createState() =>
      _LibraryCloudContentPageState();
}

class _LibraryCloudContentPageState extends State<LibraryCloudContentPage> {
  LibraryCloudWorkspaceSnapshot? _snapshot;
  bool _loading = true;
  bool _busy = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final snapshot = await widget.controller.load();
      if (mounted) setState(() => _snapshot = snapshot);
    } on Object {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('云内容'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.photo_library_outlined), text: '图库'),
              Tab(icon: Icon(Icons.description_outlined), text: '文档'),
              Tab(icon: Icon(Icons.public_outlined), text: '网页'),
              Tab(icon: Icon(Icons.inventory_2_outlined), text: '软件列表'),
            ],
          ),
        ),
        body: Stack(
          children: [
            _content(),
            if (_busy) ...[
              const ModalBarrier(dismissible: false, color: Colors.black26),
              const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('正在更新云内容'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed || _snapshot == null) {
      return _CloudEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '无法读取云内容',
        actionLabel: '重试',
        onAction: _reload,
      );
    }
    return TabBarView(
      children: [
        _images(_snapshot!),
        _documents(_snapshot!),
        _webPages(_snapshot!),
        _sourceStatus(_snapshot!),
      ],
    );
  }

  Widget _images(LibraryCloudWorkspaceSnapshot snapshot) {
    return Column(
      children: [
        _ActionBar(
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _uploadImage,
              icon: const Icon(Icons.upload_outlined),
              label: const Text('上传图片'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _uploadApkImage,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('APK 图床'),
            ),
          ],
        ),
        Expanded(
          child: snapshot.images.isEmpty
              ? const _CloudEmptyState(
                  icon: Icons.photo_library_outlined,
                  title: '图库暂无资源',
                )
              : ListView.separated(
                  key: const Key('library-cloud-images'),
                  itemCount: snapshot.images.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final resource = snapshot.images[index];
                    return ListTile(
                      leading: const Icon(Icons.image_outlined),
                      title: Text(resource.item.name),
                      subtitle: Text(
                        '${resource.partition.name} · '
                        '${resource.preferredUrl ?? '选择后获取公开 HTTPS 地址'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<_ImageUse>(
                        tooltip: '应用图片',
                        onSelected: (value) => _useImage(resource, value),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: _ImageUse.splash,
                            child: Text('设为启动图'),
                          ),
                          PopupMenuItem(
                            value: _ImageUse.carousel,
                            child: Text('追加轮播图'),
                          ),
                          PopupMenuItem(
                            value: _ImageUse.webIcon,
                            child: Text('设为网页图标'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _documents(LibraryCloudWorkspaceSnapshot snapshot) {
    return Column(
      children: [
        _ActionBar(
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _createAnnouncement,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建正文'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _uploadText,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('上传 TXT'),
            ),
          ],
        ),
        Expanded(
          child: snapshot.documents.isEmpty
              ? const _CloudEmptyState(
                  icon: Icons.description_outlined,
                  title: '文档区暂无内容',
                )
              : ListView.separated(
                  key: const Key('library-cloud-documents'),
                  itemCount: snapshot.documents.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final resource = snapshot.documents[index];
                    return ListTile(
                      leading: Icon(
                        resource.item.isFolder
                            ? Icons.folder_outlined
                            : Icons.text_snippet_outlined,
                      ),
                      title: Text(resource.item.name),
                      subtitle: Text(resource.partition.name),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => widget.controller
                                    .useDocumentAsAnnouncement(resource),
                                success: '已设为远程公告',
                              ),
                        child: const Text('设为公告'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _webPages(LibraryCloudWorkspaceSnapshot snapshot) {
    return Column(
      children: [
        _ActionBar(
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy || snapshot.urlFolder == null
                  ? null
                  : () => _editWebPage(),
              icon: const Icon(Icons.add_link),
              label: const Text('新建网页'),
            ),
          ],
        ),
        Expanded(
          child: snapshot.webFolders.isEmpty
              ? const _CloudEmptyState(
                  icon: Icons.public_outlined,
                  title: 'url 目录暂无网页',
                )
              : ListView.separated(
                  key: const Key('library-cloud-web-pages'),
                  itemCount: snapshot.webFolders.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final page = snapshot.webFolders[index];
                    return ListTile(
                      leading: Icon(
                        page.valid ? Icons.public_outlined : Icons.link_off,
                      ),
                      title: Text(page.item.name),
                      subtitle: Text(
                        page.valid ? page.url : 'description 中缺少有效 HTTPS 地址',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: '编辑网页',
                        onPressed: _busy ? null : () => _editWebPage(page),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _sourceStatus(LibraryCloudWorkspaceSnapshot snapshot) {
    final source = widget.controller.recipe.sources.firstOrNull;
    return ListView(
      key: const Key('library-cloud-rjk-status'),
      children: [
        ListTile(
          leading: Icon(
            snapshot.rjkFolder == null
                ? Icons.cloud_off_outlined
                : Icons.check_circle_outline,
          ),
          title: const Text('rjk 软件列表'),
          subtitle: Text(
            snapshot.rjkFolder == null
                ? '工作区中未发现 rjk 目录'
                : source == null
                ? '当前工程尚未绑定软件列表分享'
                : '已绑定 ${source.title}\n${source.shareUrl}',
          ),
        ),
        const Divider(height: 1),
        const ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('绑定由工程来源管理'),
          subtitle: Text('云内容页面只显示状态，不会把 img、txt 或 url 资源写入软件列表来源。'),
        ),
      ],
    );
  }

  Future<void> _uploadImage() async {
    final path = await _pick(FileType.image);
    if (path == null) return;
    await _run(() => widget.controller.uploadImage(path), success: '图片已上传');
  }

  Future<void> _uploadApkImage() async {
    final apk = await _pick(FileType.custom, const ['apk']);
    if (apk == null) return;
    final image = await _pick(FileType.image);
    if (image == null) return;
    LibraryCloudResource? uploaded;
    await _run(() async {
      uploaded = await widget.controller.uploadApkImage(
        apkPath: apk,
        imagePath: image,
      );
    }, success: 'APK 图床已创建');
    final resource = uploaded;
    if (!mounted || resource == null || resource.urls.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('可用 HTTPS 地址'),
        content: SizedBox(
          width: 520,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: resource.urls.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: SelectableText(resource.urls[index]),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _useImage(LibraryCloudResource resource, _ImageUse use) async {
    if (use == _ImageUse.webIcon) {
      final pages = widget.controller.recipe.home.webPages;
      if (pages.isEmpty) {
        _message('请先在网页区创建网页');
        return;
      }
      final index = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择网页'),
          children: [
            for (var index = 0; index < pages.length; index++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, index),
                child: Text(pages[index].name),
              ),
          ],
        ),
      );
      if (index == null) return;
      await _run(
        () => widget.controller.applyImageAsWebIcon(resource, index),
        success: '网页图标已更新',
      );
      return;
    }
    await _run(
      () => use == _ImageUse.splash
          ? widget.controller.applyImageToSplash(resource)
          : widget.controller.appendCarouselImage(resource),
      success: use == _ImageUse.splash ? '启动图已更新' : '轮播图已追加',
    );
  }

  Future<void> _createAnnouncement() async {
    final result = await _announcementDialog();
    if (result == null) return;
    await _run(
      () => widget.controller.createAnnouncement(
        name: result.$1,
        body: result.$2,
      ),
      success: '正文已创建并设为远程公告',
    );
  }

  Future<void> _uploadText() async {
    final path = await _pick(FileType.custom, const ['txt']);
    if (path == null) return;
    await _run(
      () => widget.controller.uploadAnnouncement(path),
      success: 'TXT 已上传并设为远程公告',
    );
  }

  Future<void> _editWebPage([LibraryCloudWebFolder? current]) async {
    final result = await _webPageDialog(current);
    if (result == null) return;
    await _run(
      () => widget.controller.upsertWebPage(
        existing: current?.item,
        name: result.$1,
        url: result.$2,
        icon: result.$3,
      ),
      success: current == null ? '网页已创建' : '网页已更新',
    );
  }

  Future<void> _run(
    Future<void> Function() operation, {
    required String success,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return;
      _snapshot = widget.controller.snapshot;
      _message(success);
      setState(() {});
    } on Object {
      if (mounted) _message('操作失败，请检查登录状态与网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _pick(FileType type, [List<String>? extensions]) async {
    final injected = widget.pickFile;
    if (injected != null) return injected(type, extensions);
    final result = await FilePicker.pickFiles(
      type: type,
      allowedExtensions: extensions,
      allowMultiple: false,
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) {
      if (result != null && mounted) _message('未能读取所选文件');
      return null;
    }
    return path;
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<(String, String)?> _announcementDialog() async {
    final name = TextEditingController();
    final body = TextEditingController();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建远程正文'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: body,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(labelText: '正文'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(context, (name.text.trim(), body.text));
              }
            },
            child: const Text('创建并应用'),
          ),
        ],
      ),
    );
    name.dispose();
    body.dispose();
    return result;
  }

  Future<(String, String, String)?> _webPageDialog(
    LibraryCloudWebFolder? current,
  ) async {
    final name = TextEditingController(text: current?.item.name ?? '');
    final url = TextEditingController(text: current?.url ?? '');
    final icon = TextEditingController(text: current?.icon ?? '');
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current == null ? '新建网页' : '编辑网页'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'HTTPS 地址'),
              ),
              TextField(
                controller: icon,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'HTTPS 图标（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty &&
                  _isHttpsUrl(url.text.trim()) &&
                  (icon.text.trim().isEmpty || _isHttpsUrl(icon.text.trim()))) {
                Navigator.pop(context, (
                  name.text.trim(),
                  url.text.trim(),
                  icon.text.trim(),
                ));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    name.dispose();
    url.dispose();
    icon.dispose();
    return result;
  }
}

enum _ImageUse { splash, carousel, webIcon }

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

class _CloudEmptyState extends StatelessWidget {
  const _CloudEmptyState({
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 44, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(title),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onAction,
            icon: const Icon(Icons.refresh),
            label: Text(actionLabel!),
          ),
        ],
      ],
    ),
  );
}

LibraryCloudWebFolder _parseWebFolder(CloudItem item, String description) {
  final lines = description.split(RegExp(r'\r?\n'));
  final url = lines.isEmpty ? '' : lines.first.trim();
  var icon = '';
  for (final line in lines.skip(1)) {
    if (line.trimLeft().startsWith('icon=')) {
      icon = line.trimLeft().substring('icon='.length).trim();
      break;
    }
  }
  return LibraryCloudWebFolder(item: item, url: url, icon: icon);
}

String _requiredName(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name.runes.length > 80 ||
      name.contains(RegExp(r'[\r\n\x00-\x1F\x7F]'))) {
    throw const CloudFailure('invalid_name', '名称必须为 1-80 个有效字符');
  }
  return name;
}

String? _firstHttps(Iterable<String?> values) {
  for (final value in values) {
    final candidate = value?.trim();
    if (candidate != null && _isHttpsUrl(candidate)) return candidate;
  }
  return null;
}

bool _isHttpsUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

bool _sameWebPages(
  List<LibraryWebPageRecipe> first,
  List<LibraryWebPageRecipe> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index].name != second[index].name ||
        first[index].url != second[index].url ||
        first[index].icon != second[index].icon) {
      return false;
    }
  }
  return true;
}

bool _samePath(String first, String second) =>
    File(first).absolute.path.toLowerCase() ==
    File(second).absolute.path.toLowerCase();

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
