import 'package:flutter/material.dart';
import 'package:lanzouyou/models/cloud_item.dart';
import 'package:lanzouyou/pages/library_builder/library_builder_page.dart';
import 'package:lanzouyou/shared/app_theme.dart';

void main() {
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LanzouYOU 软件库生成器验收',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: LibraryBuilderPage(
        shareInfo: Future<ShareInfo>.value(_previewShare),
      ),
    ),
  );
}

const _previewShare = ShareInfo(
  id: 'preview-folder',
  isFolder: true,
  name: '示例软件库',
  shareUrl: 'https://example.lanzouw.com/bpreview',
  password: '',
  description: '仅用于本地视觉验收的公开示例数据',
);
