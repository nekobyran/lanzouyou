import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanzou_library_shell/config/library_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('LibraryConfig', () {
    test('parses the complete version 1 contract', () {
      final config = LibraryConfig.fromJson(
        jsonDecode('''
          {
            "schemaVersion": 1,
            "identity": {
              "projectId": "sample_library",
              "displayName": "示例软件库",
              "applicationId": "cc.example.library",
              "versionName": "1.0.0",
              "versionCode": 1,
              "windowsExeName": "sample_library"
            },
            "branding": {
              "seedColor": "#2563EB",
              "themeMode": "system",
              "logoAsset": "assets/runtime/logo.png",
              "officialUrl": "https://example.invalid",
              "publisher": "示例维护者"
            },
            "sources": [
              {
                "sourceId": "main",
                "title": "主软件源",
                "shareUrl": "https://www.lanzouw.com/b000000",
                "password": "private-value",
                "searchable": true,
                "recommended": true
              }
            ],
            "features": {
              "browse": true,
              "search": true,
              "download": true,
              "showDescription": true
            }
          }
        ''')
            as Map<String, Object?>,
      );

      expect(config.schemaVersion, 1);
      expect(config.identity.displayName, '示例软件库');
      expect(config.branding.seedColor.toARGB32(), 0xFF2563EB);
      expect(config.sources.single.sourceId, 'main');
      expect(config.features.download, isTrue);
    });

    test('rejects unsupported versions and duplicate source ids', () {
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 2,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'sources': <Object?>[],
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'sources': [
            canonicalSource('same', '一'),
            canonicalSource('same', '二'),
          ],
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
    });

    test('keeps credentials only in the private core source object', () {
      final source = LibrarySource.fromJson({
        'sourceId': 'main',
        'title': '主源',
        'shareUrl': 'https://www.lanzouw.com/b000000',
        'password': ' private-value ',
        'searchable': true,
        'recommended': true,
      });

      expect(source.toCoreJson()['password'], ' private-value ');
      expect(source.toPublicJson().containsKey('password'), isFalse);
    });

    test('accepts only the audited Lanzou share-domain allowlist', () {
      for (final url in const [
        'https://lanzouw.com/b000000',
        'https://www.lanzouw.com/b000000',
        'https://pan.lanzoui.com/b000000?next=:443',
      ]) {
        expect(
          () => LibrarySource.fromJson({
            ...canonicalSource('source_one', '示例源'),
            'shareUrl': url,
          }),
          returnsNormally,
        );
      }
      for (final url in const [
        'https://www.lanzouw.com:443/b000000',
        'https://www.lanzouw.com:444/b000000',
        'https://lanzou0.com/b000000',
        'https://lanzou1.com/b000000',
        'https://lanzoua.com/b000000',
        'https://evil-lanzouw.com/b000000',
        'https://lanzouw.com.evil.test/b000000',
        'https://www.lanzouw.com./b000000',
      ]) {
        expect(
          () => LibrarySource.fromJson({
            ...canonicalSource('source_one', '示例源'),
            'shareUrl': url,
          }),
          throwsA(isA<LibraryConfigException>()),
        );
      }
    });

    test('accepts empty optional branding fields', () {
      final config = LibraryConfig.fromJson({
        'schemaVersion': 1,
        'identity': canonicalIdentity,
        'branding': {...canonicalBranding, 'officialUrl': '', 'publisher': ''},
        'sources': [canonicalSource('source_one', '示例源')],
        'features': canonicalFeatures,
      });

      expect(config.branding.officialUrl, isEmpty);
      expect(config.branding.publisher, isEmpty);
    });

    test('parses canonical remote home content and preserves visibility', () {
      final config = LibraryConfig.fromJson({
        'schemaVersion': 1,
        'identity': canonicalIdentity,
        'branding': canonicalBranding,
        'home': {
          'visible': false,
          'splashImage': 'https://assets.example.test/splash.png',
          'splashText': '欢迎使用',
          'carouselImages': ['https://assets.example.test/carousel.png'],
          'announcementUrl': 'https://www.lanzouw.com/bannouncement',
          'webPages': [
            {
              'name': '文档',
              'url': 'https://docs.example.test',
              'icon': 'https://assets.example.test/docs.png',
            },
          ],
        },
        'sources': [canonicalSource('source_one', '示例源')],
        'features': canonicalFeatures,
      });

      expect(config.home.visible, isFalse);
      expect(config.home.splashText, '欢迎使用');
      expect(config.home.carouselImages, hasLength(1));
      expect(config.home.announcementUrl, endsWith('/bannouncement'));
      expect(config.home.webPages.single.name, '文档');
    });

    test('rejects insecure remote home content URLs', () {
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'home': {
            'visible': true,
            'splashImage': 'http://assets.example.test/splash.png',
            'splashText': '',
            'carouselImages': <Object?>[],
            'announcementUrl': '',
            'webPages': <Object?>[],
          },
          'sources': [canonicalSource('source_one', '示例源')],
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
    });

    test('does not expose malformed JSON contents in load errors', () async {
      final loader = LibraryConfigLoader.testHarness(
        bundle: StringAssetBundle('{"password":"secret-value",'),
      );

      try {
        await loader.load();
        fail('load should fail');
      } on LibraryConfigException catch (error) {
        expect(error.message, isNot(contains('secret-value')));
        expect(error.message, '无法读取软件库配置，请重新生成安装包');
      }
    });

    test('enforces builder bounds and safe slugs without echoing values', () {
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': {...canonicalIdentity, 'projectId': 'Invalid-Project'},
          'branding': canonicalBranding,
          'sources': [canonicalSource('source_one', '示例源')],
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
      final largeCatalog = LibraryConfig.fromJson({
        'schemaVersion': 1,
        'identity': canonicalIdentity,
        'branding': canonicalBranding,
        'sources': List.generate(
          606,
          (index) => canonicalSource('source_$index', '示例源'),
        ),
        'features': canonicalFeatures,
      });
      expect(largeCatalog.sources, hasLength(606));
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'sources': List.generate(
            4097,
            (index) => canonicalSource('source_$index', '示例源'),
          ),
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
      const secret = 'secret-value-that-must-not-appear';
      try {
        LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'sources': [
            {
              ...canonicalSource('source_one', '示例源'),
              'password': secret.padRight(65, 'x'),
            },
          ],
          'features': canonicalFeatures,
        });
        fail('validation should fail');
      } on LibraryConfigException catch (error) {
        expect(error.message, isNot(contains(secret)));
      }
    });

    test('rejects missing and extra non-canonical fields', () {
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': Map<String, Object?>.from(canonicalBranding)
            ..remove('themeMode'),
          'sources': [canonicalSource('source_one', '示例源')],
          'features': canonicalFeatures,
        }),
        throwsA(isA<LibraryConfigException>()),
      );
      expect(
        () => LibraryConfig.fromJson({
          'schemaVersion': 1,
          'identity': canonicalIdentity,
          'branding': canonicalBranding,
          'sources': [canonicalSource('source_one', '示例源')],
          'features': canonicalFeatures,
          'build': <String, Object?>{},
        }),
        throwsA(isA<LibraryConfigException>()),
      );
    });

    test('rejects reserved names and platform version overflows', () {
      final invalidIdentities = <Map<String, Object?>>[
        {...canonicalIdentity, 'projectId': 'con'},
        {...canonicalIdentity, 'windowsExeName': 'lpt1'},
        {
          ...canonicalIdentity,
          'applicationId': 'a.${List.filled(126, 'b').join()}',
        },
        {...canonicalIdentity, 'versionName': '1.65536'},
        {...canonicalIdentity, 'versionCode': 0x100000000},
      ];

      for (final identity in invalidIdentities) {
        expect(
          () => LibraryConfig.fromJson({
            'schemaVersion': 1,
            'identity': identity,
            'branding': canonicalBranding,
            'sources': [canonicalSource('source_one', '示例源')],
            'features': canonicalFeatures,
          }),
          throwsA(isA<LibraryConfigException>()),
        );
      }
    });

    test(
      'bundled maintainer template is an explicit non-production sentinel',
      () async {
        final raw = await rootBundle.loadString(libraryConfigAsset);
        expect(raw, isNotEmpty);
        final loader = LibraryConfigLoader.embeddedRuntime();

        await expectLater(
          loader.load(),
          throwsA(
            isA<LibraryConfigException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  LibraryConfigErrorKind.unconfiguredTemplate,
                )
                .having(
                  (error) => error.message,
                  'message',
                  '请通过 LanzouYOU 生成软件库后再打开',
                ),
          ),
        );
        expect(raw, isNot(contains('identity')));
        expect(raw, isNot(contains('sources')));
      },
    );
  });
}

const canonicalIdentity = <String, Object?>{
  'projectId': 'sample_library',
  'displayName': '示例',
  'applicationId': 'cc.example.library',
  'versionName': '1.0.0',
  'versionCode': 1,
  'windowsExeName': 'sample_library',
};

const canonicalBranding = <String, Object?>{
  'seedColor': '#2563EB',
  'officialUrl': 'https://example.invalid',
  'publisher': '示例维护者',
  'logoAsset': 'assets/runtime/logo.png',
  'themeMode': 'system',
};

const canonicalFeatures = <String, Object?>{
  'browse': true,
  'search': true,
  'download': true,
  'showDescription': true,
};

Map<String, Object?> canonicalSource(String sourceId, String title) => {
  'sourceId': sourceId,
  'title': title,
  'shareUrl': 'https://www.lanzouw.com/b000000',
  'password': '',
  'searchable': true,
  'recommended': false,
};

class StringAssetBundle extends CachingAssetBundle {
  StringAssetBundle(this.value);

  final String value;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
}
