import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite/sqflite.dart';

/// Web 端：使用 sqflite_common_ffi_web（基于 IndexedDB）。
Future<void> setupDatabaseFactory() async {
  databaseFactory = databaseFactoryFfiWeb;
}
