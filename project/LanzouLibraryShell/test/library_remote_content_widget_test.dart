import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/repositories/library_remote_content_repository.dart';
import 'package:lanzou_library_shell/widgets/library_remote_content.dart';

void main() {
  testWidgets('announcement exposes loading, error, retry and original link', (
    tester,
  ) async {
    final repository = _ScriptedRemoteContentRepository(
      textResults: [
        Future<String>.error(StateError('offline')),
        Future<String>.value('维护公告正文'),
      ],
    );
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryRemoteAnnouncement(
            url: 'https://www.lanzouw.com/bannouncement',
            repository: repository,
            onOpenUrl: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('announcement-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('announcement-retry')));
    await tester.pump();
    await tester.pump();

    expect(find.text('维护公告正文'), findsOneWidget);
    expect(repository.textLoads, 2);
    expect(repository.refreshFlags, [false, true]);

    await tester.tap(find.text('打开原链接'));
    expect(opened, isTrue);
  });

  testWidgets('remote image replaces load and decode errors with retry UI', (
    tester,
  ) async {
    final repository = _ScriptedRemoteContentRepository(
      imageResults: [
        Future<Uint8List>.error(StateError('offline')),
        Future<Uint8List>.value(
          Uint8List.fromList(const [137, 80, 78, 71, 13, 10, 26, 10]),
        ),
      ],
    );
    const url = 'https://assets.example.test/broken.png';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 180,
            child: LibraryRemoteImage(
              url: url,
              repository: repository,
              semanticLabel: '测试图片',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('remote-image-error-$url')),
      findsOneWidget,
    );
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-image-error-$url')),
      findsOneWidget,
      reason: 'invalid image bytes must use the same actionable error state',
    );
    expect(repository.imageLoads, 2);
    expect(repository.refreshFlags, [false, true]);
  });
}

class _ScriptedRemoteContentRepository
    implements LibraryRemoteContentRepository {
  _ScriptedRemoteContentRepository({
    this.imageResults = const [],
    this.textResults = const [],
  });

  final List<Future<Uint8List>> imageResults;
  final List<Future<String>> textResults;
  final List<bool> refreshFlags = [];
  int imageLoads = 0;
  int textLoads = 0;

  @override
  Future<Uint8List> loadImage(String url, {bool refresh = false}) {
    refreshFlags.add(refresh);
    return imageResults[imageLoads++];
  }

  @override
  Future<String> loadText(String url, {bool refresh = false}) {
    refreshFlags.add(refresh);
    return textResults[textLoads++];
  }
}
