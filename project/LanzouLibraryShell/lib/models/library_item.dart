class LibraryItem {
  const LibraryItem({
    required this.sourceId,
    required this.title,
    required this.url,
    required this.shareUrl,
    required this.isFolder,
    this.size = '',
    this.time = '',
    this.iconUrl = '',
    this.source = '',
    this.description = '',
    this.folderId = '',
  });

  factory LibraryItem.fromJson(Map<String, Object?> json) => LibraryItem(
    sourceId: _requiredString(json, 'sourceId'),
    title: _requiredString(json, 'title'),
    url: _string(json, 'url'),
    shareUrl: _string(json, 'shareUrl'),
    size: _string(json, 'size'),
    time: _string(json, 'time'),
    iconUrl: _string(json, 'iconUrl'),
    source: _string(json, 'source'),
    description: _string(json, 'description'),
    folderId: _string(json, 'folderId'),
    isFolder: json['isFolder'] == true,
  );

  final String sourceId;
  final String title;
  final String url;
  final String shareUrl;
  final String size;
  final String time;
  final String iconUrl;
  final String source;
  final String description;
  final String folderId;
  final bool isFolder;

  String get navigationUrl {
    if (isFolder) return url.isNotEmpty ? url : shareUrl;
    return shareUrl.isNotEmpty ? shareUrl : url;
  }

  String get stableKey => '$sourceId|$navigationUrl|$folderId|$title';

  Map<String, Object?> toCoreJson() => {
    'sourceId': sourceId,
    'title': title,
    'url': url,
    'shareUrl': shareUrl,
    if (size.isNotEmpty) 'size': size,
    if (time.isNotEmpty) 'time': time,
    if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
    if (source.isNotEmpty) 'source': source,
    if (description.isNotEmpty) 'description': description,
    if (folderId.isNotEmpty) 'folderId': folderId,
    'isFolder': isFolder,
  };
}

class LibraryFolder {
  const LibraryFolder({
    required this.sourceId,
    required this.title,
    required this.url,
    required this.items,
    this.publisher = '',
    this.avatarUrl = '',
    this.description = '',
    this.saveUrl = '',
    this.folderId = '',
    this.page = 1,
    this.hasMore = false,
    this.nextPageReadyAtMs,
    this.remoteSearch = false,
  });

  factory LibraryFolder.fromJson(Map<String, Object?> json) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('folder.items must be a list');
    }
    return LibraryFolder(
      sourceId: _requiredString(json, 'sourceId'),
      title: _requiredString(json, 'title'),
      publisher: _string(json, 'publisher'),
      avatarUrl: _string(json, 'avatarUrl'),
      description: _string(json, 'description'),
      saveUrl: _string(json, 'saveUrl'),
      url: _string(json, 'url'),
      folderId: _string(json, 'folderId'),
      page: (json['page'] as num?)?.toInt() ?? 1,
      hasMore: json['hasMore'] == true,
      nextPageReadyAtMs: (json['nextPageReadyAtMs'] as num?)?.toInt(),
      remoteSearch: json['remoteSearch'] == true,
      items: rawItems
          .map((value) => LibraryItem.fromJson(jsonObject(value, 'item')))
          .toList(growable: false),
    );
  }

  final String sourceId;
  final String title;
  final String publisher;
  final String avatarUrl;
  final String description;
  final String saveUrl;
  final String url;
  final String folderId;
  final int page;
  final bool hasMore;
  final int? nextPageReadyAtMs;
  final bool remoteSearch;
  final List<LibraryItem> items;
}

String requiredString(Map<String, Object?> json, String key) =>
    _requiredString(json, key);

String optionalString(Map<String, Object?> json, String key) =>
    _string(json, key);

Map<String, Object?> jsonObject(Object? value, String label) {
  if (value is! Map) throw FormatException('$label must be an object');
  return value.cast<String, Object?>();
}

List<Object?> jsonList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be a list');
  return value;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (value.isEmpty) throw FormatException('$key is required');
  return value;
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return '';
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}
