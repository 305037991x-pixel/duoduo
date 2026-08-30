/// 兜底实现（默认走原生，不做任何事）。
Future<void> setupDatabaseFactory() async {
  // 原生 Android/iOS 由 sqflite 自行处理，无需配置
}
