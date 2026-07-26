import 'package:flutter/material.dart';

import 'app/library_shell_app.dart';
import 'config/library_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final config = await LibraryConfigLoader.embeddedRuntime().load();
    runApp(LibraryShellApp.production(config: config));
  } on LibraryConfigException catch (error) {
    runApp(LibraryConfigErrorApp(error: error));
  }
}
