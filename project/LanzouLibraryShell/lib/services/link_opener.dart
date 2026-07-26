import 'package:url_launcher/url_launcher.dart';

abstract interface class LinkOpener {
  Future<void> open(String url);
}

class UrlLauncherLinkOpener implements LinkOpener {
  const UrlLauncherLinkOpener();

  @override
  Future<void> open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      throw const FormatException('下载链接无效');
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) throw const FormatException('无法打开下载链接');
  }
}
