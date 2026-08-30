import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 桌面端（Windows/macOS/Linux）：使用 sqflite_common_ffi。
Future<void> setupDatabaseFactory() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
