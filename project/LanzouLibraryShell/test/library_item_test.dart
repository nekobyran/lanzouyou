import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/models/library_item.dart';

void main() {
  test('folder navigation prefers its virtual url over the root share url', () {
    const folder = LibraryItem(
      sourceId: 'main',
      title: '子目录',
      url: 'https://www.lanzouw.com/virtual-folder',
      shareUrl: 'https://www.lanzouw.com/broot',
      isFolder: true,
    );
    const file = LibraryItem(
      sourceId: 'main',
      title: '文件',
      url: 'https://www.lanzouw.com/internal-file',
      shareUrl: 'https://www.lanzouw.com/ifile',
      isFolder: false,
    );

    expect(folder.navigationUrl, 'https://www.lanzouw.com/virtual-folder');
    expect(file.navigationUrl, 'https://www.lanzouw.com/ifile');
  });
}
