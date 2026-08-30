import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../data/database/database_helper.dart';

/// 登录验证结果
class BiliLoginStatus {
  final bool isLogin;
  final String uname;
  final String message;
  BiliLoginStatus({required this.isLogin, required this.uname, required this.message});
}

/// 扫码登录二维码
class BiliQrCode {
  final String qrcodeKey;
  final String qrUrl; // 二维码内容（用于生成二维码图片）
  BiliQrCode({required this.qrcodeKey, required this.qrUrl});
}

/// 扫码登录轮询状态
class BiliQrPollState {
  static const int success = 0;
  static const int expired = 86038;
  static const int scannedNotConfirmed = 86090;
  static const int notScanned = 86101;

  final int code;
  final String message;
  final bool loggedIn;
  BiliQrPollState({required this.code, required this.message, required this.loggedIn});
}

/// 字幕获取结果（只保留纯文本，不含时间轴）
class BiliSubtitleResult {
  final String bvid;
  final int cid;
  final int page;
  final String title;
  final String upName;
  final String lang; // ai-zh / zh-CN 等
  final String langDoc; // "中文（自动生成）" 等
  final List<String> lines; // 每句字幕文本
  final String text; // 合并后的纯文本

  BiliSubtitleResult({
    required this.bvid,
    required this.cid,
    required this.page,
    required this.title,
    required this.upName,
    required this.lang,
    required this.langDoc,
    required this.lines,
    required this.text,
  });
}

/// B站服务 - 登录态(扫码/SESSDATA) + 视频信息 + AI字幕获取与入库
///
/// 登录态两种获取方式：
/// 1. 扫码登录（推荐）：passport 的 qrcode generate/poll 接口，用户用B站APP
///    扫一扫确认后，poll 响应的 Set-Cookie 里直接返回 SESSDATA，无需 WebView
/// 2. 手动粘贴：浏览器登录 bilibili.com 后从 Cookie 复制 SESSDATA 到设置页
///
/// B站的 AI 字幕接口必须携带 SESSDATA 才能返回。
class BilibiliService {
  static const String _sessdataKey = 'bili_sessdata';

  final DatabaseHelper _db;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  BilibiliService(this._db);

  Future<Map<String, String>> _headers({bool withCookie = true}) async {
    final sess = await getSessdata();
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/',
      if (withCookie && sess != null && sess.isNotEmpty) 'Cookie': 'SESSDATA=$sess',
    };
  }

  String? _sessdata;

  Future<String?> getSessdata() async {
    if (_sessdata != null) return _sessdata;
    final prefs = await SharedPreferences.getInstance();
    _sessdata = prefs.getString(_sessdataKey);
    return _sessdata;
  }

  Future<void> setSessdata(String value) async {
    _sessdata = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessdataKey, _sessdata!);
  }

  Future<bool> hasLogin() async {
    final s = await getSessdata();
    return s != null && s.isNotEmpty;
  }

  // ============ 扫码登录 ============

  /// 创建扫码登录二维码
  Future<BiliQrCode> createQrLogin() async {
    final resp = await _dio.get(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
      options: Options(headers: await _headers(withCookie: false)),
    );
    final data = resp.data;
    if (data['code'] != 0) {
      throw Exception('创建二维码失败：${data['code']} ${data['message']}');
    }
    final d = data['data'] as Map<String, dynamic>;
    return BiliQrCode(qrcodeKey: d['qrcode_key'].toString(), qrUrl: d['url'].toString());
  }

  /// 轮询扫码状态。登录成功时 SESSDATA 在 Set-Cookie 响应头中（data.url 参数里也有一份），自动保存。
  Future<BiliQrPollState> pollQrLogin(String qrcodeKey) async {
    final resp = await _dio.get(
      'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
      queryParameters: {'qrcode_key': qrcodeKey},
      options: Options(headers: await _headers(withCookie: false)),
    );
    final data = resp.data;
    if (data['code'] != 0) {
      throw Exception('轮询失败：${data['code']} ${data['message']}');
    }
    final d = data['data'] as Map<String, dynamic>;
    final code = (d['code'] as num?)?.toInt() ?? -1;
    if (code != BiliQrPollState.success) {
      return BiliQrPollState(code: code, message: d['message'].toString(), loggedIn: false);
    }

    // 登录成功：优先从 Set-Cookie 头提取，其次从 data.url 的查询参数提取
    String? sessdata = _extractFromSetCookie(resp.headers.map['set-cookie']);
    sessdata ??= _extractFromUrlParams(d['url']?.toString() ?? '');
    if (sessdata == null || sessdata.isEmpty) {
      throw Exception('登录成功但未能提取 SESSDATA');
    }
    await setSessdata(sessdata);
    return BiliQrPollState(code: code, message: '登录成功', loggedIn: true);
  }

  String? _extractFromSetCookie(List<String>? cookies) {
    if (cookies == null) return null;
    for (final c in cookies) {
      // SESSDATA 值可能包含逗号，以分号截断
      if (c.trimLeft().startsWith('SESSDATA=')) {
        final v = c.trimLeft().substring('SESSDATA='.length);
        final end = v.indexOf(';');
        return end == -1 ? v : v.substring(0, end);
      }
    }
    return null;
  }

  String? _extractFromUrlParams(String url) {
    if (url.isEmpty) return null;
    final idx = url.indexOf('SESSDATA=');
    if (idx == -1) return null;
    final rest = url.substring(idx + 'SESSDATA='.length);
    final end = rest.indexOf('&');
    final raw = end == -1 ? rest : rest.substring(0, end);
    return Uri.decodeComponent(raw);
  }

  // ============ 登录态验证 ============

  /// 校验登录态是否有效（调用 nav 接口）
  Future<BiliLoginStatus> verifyLogin() async {
    final sess = await getSessdata();
    if (sess == null || sess.isEmpty) {
      return BiliLoginStatus(isLogin: false, uname: '', message: '未配置登录态');
    }
    try {
      final resp = await _dio.get(
        'https://api.bilibili.com/x/web-interface/nav',
        options: Options(headers: await _headers()),
      );
      final data = resp.data;
      final code = data['code'];
      final d = data['data'] as Map<String, dynamic>?;
      if (code == 0 && d?['isLogin'] == true) {
        return BiliLoginStatus(
          isLogin: true,
          uname: (d?['uname'] ?? '').toString(),
          message: '登录有效：${d?['uname']}',
        );
      }
      return BiliLoginStatus(isLogin: false, uname: '', message: '登录态已失效，请重新扫码');
    } catch (e) {
      return BiliLoginStatus(isLogin: false, uname: '', message: '验证失败：$e');
    }
  }

  // ============ 字幕 ============

  /// 从任意 B站链接/文本中提取 BV 号
  /// 支持 www.bilibili.com/video/BVxxx、b23.tv 短链、纯 BV 号
  Future<String?> extractBvid(String input) async {
    final direct = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(input);
    if (direct != null) return direct.group(0);
    // 短链 b23.tv 需要先解析重定向
    final trimmed = input.trim();
    if (trimmed.startsWith('http')) {
      try {
        final resp = await _dio.get(
          trimmed,
          options: Options(
            headers: await _headers(withCookie: false),
            followRedirects: true,
            maxRedirects: 5,
          ),
        );
        final fromUri = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(resp.realUri.toString());
        if (fromUri != null) return fromUri.group(0);
        final fromBody = RegExp(r'"?bvid"?\s*[:=]\s*"(BV[0-9A-Za-z]{10})"').firstMatch(resp.data.toString());
        if (fromBody != null) return fromBody.group(1);
        final fromHtml = RegExp(r'BV[0-9A-Za-z]{10}').firstMatch(resp.data.toString());
        if (fromHtml != null) return fromHtml.group(0);
      } catch (_) {}
    }
    return null;
  }

  /// 主流程：链接/BV号 -> 视频信息 -> 字幕列表 -> 字幕JSON -> 入库
  /// 优先取 AI 字幕(ai-zh)，其次 CC 字幕(zh-CN)，再次任意可用字幕
  Future<BiliSubtitleResult> fetchVideoSubtitles(String urlOrBvid) async {
    final bvid = await extractBvid(urlOrBvid);
    if (bvid == null) {
      throw Exception('未能从输入中识别出 B站视频 BV 号');
    }

    // 1. 视频信息（含 cid、分P）
    final info = await _videoInfo(bvid);
    final title = (info['title'] ?? '').toString();
    final upName = ((info['owner'] as Map<String, dynamic>?)?['name'] ?? '').toString();
    final pages = (info['pages'] as List?) ?? const [];
    if (pages.isEmpty) throw Exception('未获取到视频分P信息');

    // 解析分P参数（?p=N），默认 P1
    final pMatch = RegExp(r'[?&]p=(\d+)').firstMatch(urlOrBvid);
    int pageNo = 1;
    if (pMatch != null) {
      final v = int.tryParse(pMatch.group(1)!) ?? 1;
      if (v >= 1 && v <= pages.length) pageNo = v;
    }
    final pageMap = pages[pageNo - 1] as Map<String, dynamic>;
    final cid = (pageMap['cid'] as num).toInt();

    // 2. 字幕列表
    final subtitles = await _subtitleList(bvid, cid, aid: info['aid'] as num?);
    if (subtitles.isEmpty) {
      throw Exception(
        '未找到可用字幕：该视频可能没有AI字幕/CC字幕，或登录态失效（AI字幕需要有效的登录态）',
      );
    }

    // 选择字幕：ai-zh 优先
    Map<String, dynamic> chosen = subtitles.first;
    for (final s in subtitles) {
      if (s['lan'] == 'ai-zh') {
        chosen = s;
        break;
      }
    }
    if (chosen['lan'] != 'ai-zh') {
      for (final s in subtitles) {
        if (s['lan'] == 'zh-CN' || s['lan'] == 'zh-Hans') {
          chosen = s;
          break;
        }
      }
    }

    // 3. 下载字幕 JSON（只取 content 文本，不要时间轴）
    String subtitleUrl = (chosen['subtitle_url'] ?? chosen['subtile_url'] ?? '').toString();
    if (subtitleUrl.isEmpty) throw Exception('字幕列表存在但字幕地址为空');
    if (subtitleUrl.startsWith('//')) subtitleUrl = 'https:$subtitleUrl';

    final lines = <String>[];
    try {
      final resp = await _dio.get(
        subtitleUrl,
        options: Options(headers: await _headers(withCookie: false)),
      );
      final body = (resp.data is Map ? resp.data['body'] : null) as List?;
      if (body != null) {
        for (final item in body) {
          if (item is Map) {
            final content = (item['content'] ?? '').toString().trim();
            if (content.isNotEmpty) lines.add(content);
          }
        }
      }
    } catch (e) {
      throw Exception('字幕文件下载失败：$e');
    }

    if (lines.isEmpty) throw Exception('字幕内容为空');

    final result = BiliSubtitleResult(
      bvid: bvid,
      cid: cid,
      page: pageNo,
      title: title,
      upName: upName,
      lang: (chosen['lan'] ?? '').toString(),
      langDoc: (chosen['lan_doc'] ?? '').toString(),
      lines: lines,
      text: lines.join('\n'),
    );

    // 4. 入库（字幕持久化，同一视频分P覆盖更新）
    await _saveSubtitle(result);
    return result;
  }

  Future<Map<String, dynamic>> _videoInfo(String bvid) async {
    final resp = await _dio.get(
      'https://api.bilibili.com/x/web-interface/view',
      queryParameters: {'bvid': bvid},
      options: Options(headers: await _headers(withCookie: false)),
    );
    final data = resp.data;
    if (data['code'] != 0) {
      throw Exception('获取视频信息失败：${data['code']} ${data['message']}');
    }
    return Map<String, dynamic>.from(data['data'] as Map<String, dynamic>);
  }

  /// 拉取字幕列表。优先 wbi 接口，失败时回退旧接口。
  /// AI 字幕必须携带 SESSDATA，否则列表通常为空。
  Future<List<Map<String, dynamic>>> _subtitleList(String bvid, int cid, {num? aid}) async {
    final endpoints = [
      'https://api.bilibili.com/x/player/wbi/v2',
      'https://api.bilibili.com/x/player/v2',
    ];
    for (final ep in endpoints) {
      try {
        final resp = await _dio.get(
          ep,
          queryParameters: {'bvid': bvid, 'cid': cid, if (aid != null) 'aid': aid.toInt()},
          options: Options(headers: await _headers()),
        );
        final data = resp.data;
        if (data is! Map || data['code'] != 0) continue;
        final d = data['data'];
        if (d is! Map) continue;
        final subtitle = d['subtitle'];
        if (subtitle is! Map) continue;
        final list = subtitle['subtitles'];
        if (list is List && list.isNotEmpty) {
          return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  Future<void> _saveSubtitle(BiliSubtitleResult r) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final map = {
      'id': '${r.bvid}_p${r.page}',
      'bvid': r.bvid,
      'cid': r.cid,
      'title': r.title,
      'up_name': r.upName,
      'page': r.page,
      'lang': r.lang,
      'lang_doc': r.langDoc,
      'line_count': r.lines.length,
      'content': r.text,
      'created_at': now,
      'updated_at': now,
    };
    await db.insert('subtitles', map, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ============ 字幕查询 ============

  Future<List<Map<String, Object?>>> getAllSubtitles() async {
    final db = await _db.database;
    return db.query('subtitles', orderBy: 'updated_at DESC');
  }

  Future<Map<String, Object?>?> getSubtitleByBvid(String bvid, {int page = 1}) async {
    final db = await _db.database;
    final maps = await db.query('subtitles',
        where: 'id = ?', whereArgs: ['${bvid}_p$page'], limit: 1);
    return maps.isEmpty ? null : maps.first;
  }

  Future<void> deleteSubtitle(String id) async {
    final db = await _db.database;
    await db.delete('subtitles', where: 'id = ?', whereArgs: [id]);
  }
}
