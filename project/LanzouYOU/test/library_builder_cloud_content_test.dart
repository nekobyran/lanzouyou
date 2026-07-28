import 'package:flutter_test/flutter_test.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/library_builder/library_cloud_content_page.dart';
import 'package:lanzouyou/pages/library_builder/library_recipe.dart';
import 'package:lanzouyou/services/cloud_service.dart';

void main() {
  test(
    'workspace discovery uses 50 item pages and exhausts every partition',
    () async {
      final cloud = _BuilderCloudService();
      cloud.seedWorkspace(
        imageCount: 51,
        webDescriptions: const {
          '文档站':
              'https://docs.example.com\nicon=https://cdn.example.com/doc.png',
        },
      );
      final saved = <LibraryBuildRecipe>[];
      final controller = LibraryCloudContentController(
        cloudService: cloud,
        initialRecipe: _recipe(),
        onRecipeChanged: (recipe) async => saved.add(recipe),
      );

      final workspace = await controller.load();

      expect(workspace.images, hasLength(51));
      expect(workspace.imagePartitions.map((value) => value.name), ['img1']);
      expect(workspace.rjkFolder?.name, 'rjk');
      expect(controller.recipe.home.webPages.single.toJson(), {
        'name': '文档站',
        'url': 'https://docs.example.com',
        'icon': 'https://cdn.example.com/doc.png',
      });
      expect(saved, hasLength(1));
      expect(cloud.listRequests, isNotEmpty);
      expect(cloud.listRequests.every((request) => request.$3 == 50), isTrue);
      expect(cloud.listRequests, contains(('img-1', 2, 50)));
    },
  );

  test(
    'uploads use the first non-full partition then create the next one',
    () async {
      final cloud = _BuilderCloudService()
        ..seedWorkspace(imageCount: 50, secondImageCount: 49);
      final controller = LibraryCloudContentController(
        cloudService: cloud,
        initialRecipe: _recipe(),
        onRecipeChanged: (_) async {},
      );
      await controller.load();

      await controller.uploadImage(r'D:\picked\cover.png');
      expect(cloud.uploads.last['folderId'], 'img-2');

      cloud.folders['img-2']!.add(
        const CloudItem(id: 'fill-img-2', name: 'fill.png', isFolder: false),
      );
      await controller.load();
      await controller.uploadImage(r'D:\picked\second.png');

      expect(cloud.calls, contains('mkdir:root:img3'));
      expect(cloud.uploads.last['folderId'], 'folder-img3');
    },
  );

  test(
    'apk image host applies icon and returns only usable https urls',
    () async {
      final cloud = _BuilderCloudService()..seedWorkspace();
      final controller = LibraryCloudContentController(
        cloudService: cloud,
        initialRecipe: _recipe(),
        onRecipeChanged: (_) async {},
      );
      await controller.load();

      final resource = await controller.uploadApkImage(
        apkPath: r'D:\picked\empty.apk',
        imagePath: r'D:\picked\poster.png',
      );

      expect(cloud.calls, contains('set_icon:upload-1:D:\\picked\\poster.png'));
      expect(resource.urls, [
        'https://cdn.example.com/upload-1.png',
        'https://download.example.com/upload-1',
        'https://www.lanzouw.com/upload-1',
      ]);
    },
  );

  test('documents and web folders persist cloud-backed home content', () async {
    final cloud = _BuilderCloudService()..seedWorkspace();
    final saved = <LibraryBuildRecipe>[];
    final controller = LibraryCloudContentController(
      cloudService: cloud,
      initialRecipe: _recipe(),
      onRecipeChanged: (recipe) async => saved.add(recipe),
    );
    await controller.load();

    await controller.createAnnouncement(name: '更新公告', body: '版本 2 已发布');
    expect(cloud.createdDescriptions['更新公告'], '版本 2 已发布');
    expect(
      controller.recipe.home.announcementUrl,
      'https://www.lanzouw.com/folder-update',
    );

    await controller.upsertWebPage(
      name: '官网',
      url: 'https://product.example.com',
      icon: 'https://cdn.example.com/product.png',
    );
    expect(
      cloud.createdDescriptions['官网'],
      'https://product.example.com\nicon=https://cdn.example.com/product.png',
    );
    expect(controller.recipe.home.webPages.single.name, '官网');
    expect(saved, hasLength(greaterThanOrEqualTo(2)));
    expect(
      controller.recipe.sources.single.shareUrl,
      'https://www.lanzouw.com/rjk-share',
    );
  });
}

LibraryBuildRecipe _recipe() {
  const share = ShareInfo(
    id: 'rjk',
    isFolder: true,
    name: '软件列表',
    shareUrl: 'https://www.lanzouw.com/rjk-share',
    password: '',
    description: '',
  );
  final base = LibraryBuildRecipe.fromShareInfo(share);
  return base.copyWith(
    workspace: const LibraryWorkspace(
      rootFolderId: 'root',
      rootFolderName: '工程',
      rootShareUrl: 'https://www.lanzouw.com/root-share',
    ),
  );
}

class _BuilderCloudService implements CloudService {
  final folders = <String, List<CloudItem>>{};
  final calls = <String>[];
  final uploads = <Map<String, Object?>>[];
  final shareDescriptions = <String, String>{};
  final listRequests = <(String, int, int)>[];
  final createdDescriptions = <String, String>{};

  void seedWorkspace({
    int imageCount = 0,
    int? secondImageCount,
    Map<String, String> webDescriptions = const {},
  }) {
    folders['root'] = [
      const CloudItem(id: 'img-1', name: 'img1', isFolder: true),
      if (secondImageCount != null)
        const CloudItem(id: 'img-2', name: 'img2', isFolder: true),
      const CloudItem(id: 'txt-1', name: 'txt1', isFolder: true),
      const CloudItem(id: 'rjk', name: 'rjk', isFolder: true),
      const CloudItem(id: 'url', name: 'url', isFolder: true),
    ];
    folders['img-1'] = List.generate(
      imageCount,
      (index) => CloudItem(
        id: 'image-$index',
        name: 'image-$index.png',
        isFolder: false,
        iconUrl: 'https://cdn.example.com/image-$index.png',
      ),
    );
    if (secondImageCount != null) {
      folders['img-2'] = List.generate(
        secondImageCount,
        (index) => CloudItem(
          id: 'image-2-$index',
          name: 'image-2-$index.png',
          isFolder: false,
        ),
      );
    }
    folders['txt-1'] = [];
    folders['rjk'] = [];
    folders['url'] = [
      for (final entry in webDescriptions.entries)
        CloudItem(
          id: 'web-${entry.key}',
          name: entry.key,
          isFolder: true,
          description: entry.value,
        ),
    ];
    for (final entry in webDescriptions.entries) {
      shareDescriptions['web-${entry.key}'] = entry.value;
    }
  }

  @override
  Future<CloudPage> listFolder(
    String folderId, {
    int page = 1,
    int pageSize = 200,
  }) async {
    listRequests.add((folderId, page, pageSize));
    final all = folders[folderId] ?? const <CloudItem>[];
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, all.length);
    return CloudPage(
      items: start >= all.length ? const [] : all.sublist(start, end),
      page: page,
      hasMore: end < all.length,
    );
  }

  @override
  Future<void> createFolder(
    String parentId,
    String name, {
    String description = '',
  }) async {
    calls.add('mkdir:$parentId:$name');
    createdDescriptions[name] = description;
    final id = switch (name) {
      '更新公告' => 'folder-update',
      _ => 'folder-$name',
    };
    folders
        .putIfAbsent(parentId, () => [])
        .add(
          CloudItem(
            id: id,
            name: name,
            isFolder: true,
            description: description,
          ),
        );
    folders[id] = [];
    shareDescriptions[id] = description;
  }

  @override
  Future<UploadResult> upload(
    String folderId,
    String path, {
    bool compatibilityWrap = false,
    String kind = 'auto',
    String? operationId,
  }) async {
    final id = 'upload-${uploads.length + 1}';
    uploads.add({
      'folderId': folderId,
      'path': path,
      'compatibilityWrap': compatibilityWrap,
      'kind': kind,
      'operationId': operationId,
    });
    final item = CloudItem(
      id: id,
      name: path.split(RegExp(r'[\\/]')).last,
      isFolder: false,
      iconUrl: 'https://cdn.example.com/$id.png',
    );
    folders.putIfAbsent(folderId, () => []).add(item);
    return UploadResult(
      id: id,
      folderId: folderId,
      originalName: item.name,
      uploadedName: item.name,
    );
  }

  @override
  Future<ShareInfo> shareInfo(CloudItem item) async => ShareInfo(
    id: item.id,
    isFolder: item.isFolder,
    name: item.name,
    shareUrl: item.id == 'folder-update'
        ? 'https://www.lanzouw.com/folder-update'
        : 'https://www.lanzouw.com/${item.id}',
    password: '',
    description: shareDescriptions[item.id] ?? item.description ?? '',
    directUrl: item.isFolder ? null : 'https://download.example.com/${item.id}',
  );

  @override
  Future<void> setIcon(String fileId, String path) async {
    calls.add('set_icon:$fileId:$path');
  }

  @override
  Future<PreparedIcon> prepareIcon(
    String sourcePath, {
    String? outputPath,
  }) async =>
      PreparedIcon(
        path: outputPath ?? sourcePath,
        mediaType: 'image/png',
        bytes: 50000,
        width: 128,
        height: 128,
        sourceKind: 'image',
      );

  @override
  Future<ManagedDescription> getDescription(CloudItem item) async =>
      ManagedDescription(
        id: item.id,
        isFolder: item.isFolder,
        name: item.name,
        description: shareDescriptions[item.id] ?? item.description ?? '',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
