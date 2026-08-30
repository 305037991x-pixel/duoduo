import 'package:flutter/foundation.dart';
import 'database_factory_stub.dart'
    if (dart.library.js_interop) 'database_factory_web.dart'
    if (dart.library.io) 'database_factory_io.dart' as impl;

/// 按平台初始化 sqflite 数据库工厂。
/// - Web / 桌面(Windows/macOS/Linux)：用 FFI factory（sqflite_common_ffi*）
/// - Android / iOS：走原生 sqflite，无需设置
/// 必须在任何 openDatabase 之前调用一次。
Future<void> initDatabaseFactory() async {
  // Android/iOS 无需处理，直接返回
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return;
  }
  await impl.setupDatabaseFactory();
}
