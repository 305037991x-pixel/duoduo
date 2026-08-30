import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/asymmetric/api.dart' show RSAPublicKey;
import 'package:pointycastle/asymmetric/oaep.dart' show OAEPEncoding;
import 'package:pointycastle/asymmetric/rsa.dart' show RSAEngine;
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
/// 登录态有效期约1个月。扫码登录会保存 refresh_token，在拉字幕/验证前
/// 调用 refreshCookieIfNeeded 自动续期（B站官方刷新流程），只要一个月内
/// 用过一次就无需重新扫码；手动粘贴方式没有 refresh_token，到期需重扫。
///
/// B站的 AI 字幕接口必须携带 SESSDATA 才能返回。
class BilibiliService {
  static const String _sessdataKey = 'bili_sessdata';
  static const String _jctKey = 'bili_jct'; // csrf token
  static const String _refreshTokenKey = 'bili_refresh_token';

  /// B站 Web 端 cookie 刷新用的固定 RSA 公钥（JWK 格式，逆向自官方 wasm）
  static const String _refreshPubKeyN =
      'y4HdjgJHBlbaBN04VERG4qNBIFHP6a3GozCl75AihQloSWCXC5HDNgyinEnhaQ_4-gaMud_'
      'GF50elYXLlCToR9se9Z8z433U3KjM-3Yx7ptKkmQNAMggQwAVKgq3zYAoidNEWuxpkY_m'
      'AitTSRLnsJW-NCTa0bqBFF6Wm1MxgfE';

  final DatabaseHelper _db;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  BilibiliService(this._db);

  Future<Map<String, String>> _headers({bool withCookie = true}) async {
    final sess = await getSessdata();
    final jct = await _getJct();
    final cookieParts = <String>[
      if (sess != null && sess.isNotEmpty) 'SESSDATA=$sess',
      if (jct != null && jct.isNotEmpty) 'bili_jct=$jct',
    ];
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/',
      if (withCookie && cookieParts.isNotEmpty) 'Cookie': cookieParts.join('; '),
    };
  }

  String? _sessdata;

  Future<String?> getSessdata() async {
    if (_sessdata != null) return _sessdata;
    final prefs = await SharedPreferences.getInstance();
    _sessdata = prefs.getString(_sessdataKey);
    return _sessdata;
  }

  Future<String?> _getJct() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_jctKey);
  }

  Future<String?> _getRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey);
  }

  Future<void> _saveCredentials({required String sessdata, String? jct, String? refreshToken}) async {
    _sessdata = sessdata.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessdataKey, _sessdata!);
    if (jct != null && jct.isNotEmpty) await prefs.setString(_jctKey, jct);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await prefs.setString(_refreshTokenKey, refreshToken);
    }
  }

  Future<void> setSessdata(String value) async {
    await _saveCredentials(sessdata: value);
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

  /// 轮询扫码状态。登录成功时新 cookie 在 Set-Cookie 响应头中（data.url 参数里也有一份），
  /// refresh_token 在 JSON data 中；三者一并保存，供后续自动续期使用。
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
    final cookies = resp.headers.map['set-cookie'];
    String? sessdata = _extractFromSetCookie('SESSDATA', cookies) ??
        _extractFromUrlParam('SESSDATA', d['url']?.toString() ?? '');
    final jct = _extractFromSetCookie('bili_jct', cookies) ??
        _extractFromUrlParam('bili_jct', d['url']?.toString() ?? '');
    if (sessdata == null || sessdata.isEmpty) {
      throw Exception('登录成功但未能提取 SESSDATA');
    }
    await _saveCredentials(
      sessdata: sessdata,
      jct: jct,
      refreshToken: d['refresh_token']?.toString(),
    );
    return BiliQrPollState(code: code, message: '登录成功', loggedIn: true);
  }

  String? _extractFromSetCookie(String name, List<String>? cookies) {
    if (cookies == null) return null;
    final prefix = '$name=';
    for (final c in cookies) {
      if (c.trimLeft().startsWith(prefix)) {
        final v = c.trimLeft().substring(prefix.length);
        final end = v.indexOf(';');
        return end == -1 ? v : v.substring(0, end);
      }
    }
    return null;
  }

  String? _extractFromUrlParam(String name, String url) {
    if (url.isEmpty) return null;
    final idx = url.indexOf('$name=');
    if (idx == -1) return null;
    final rest = url.substring(idx + name.length + 1);
    final end = rest.indexOf('&');
    final raw = end == -1 ? rest : rest.substring(0, end);
    return Uri.decodeComponent(raw);
  }

  // ============ Cookie 自动续期 ============

  /// 检查并自动续期登录态（B站官方 Web cookie 刷新流程）。
  /// 仅当 B站返回 refresh=true（即将到期）时才真正刷新；任何失败都静默忽略。
  /// 返回 true 表示本次完成了刷新。
  Future<bool> refreshCookieIfNeeded() async {
    try {
      if (!await hasLogin()) return false;
      final jct = await _getJct();
      final refreshToken = await _getRefreshToken();
      if (jct == null || jct.isEmpty || refreshToken == null || refreshToken.isEmpty) {
        return false; // 手动粘贴 SESSDATA 的用户没有续期材料，只能重新扫码
      }

      // 1. 检查是否需要刷新
      final infoResp = await _dio.get(
        'https://passport.bilibili.com/x/passport-login/web/cookie/info',
        queryParameters: {'csrf': jct},
        options: Options(headers: await _headers()),
      );
      final info = infoResp.data;
      if (info is! Map || info['code'] != 0) return false;
      final infoData = info['data'] as Map<String, dynamic>?;
      if (infoData == null || infoData['refresh'] != true) return false;
      final timestamp = (infoData['timestamp'] as num).toInt();

      // 2. 生成 correspondPath：RSA-OAEP(SHA-256) 加密 refresh_{timestamp} 转 hex
      final correspondPath = _generateCorrespondPath(timestamp);

      // 3. 用 correspondPath 换取实时刷新口令 refresh_csrf（SSR HTML 中）
      final csrfResp = await _dio.get(
        'https://www.bilibili.com/correspond/1/$correspondPath',
        options: Options(headers: await _headers()),
      );
      final csrfMatch =
          RegExp(r'<div id="1-name">([^<]+)</div>').firstMatch(csrfResp.data.toString());
      if (csrfMatch == null) return false;
      final refreshCsrf = csrfMatch.group(1)!;

      // 4. 刷新：旧 csrf + 旧 refresh_token -> 新 SESSDATA/bili_jct + 新 refresh_token
      final refreshResp = await _dio.post(
        'https://passport.bilibili.com/x/passport-login/web/cookie/refresh',
        data: 'csrf=$jct&refresh_csrf=$refreshCsrf&source=main_web&refresh_token=$refreshToken',
        options: Options(
          headers: await _headers(),
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      final refresh = refreshResp.data;
      if (refresh is! Map || refresh['code'] != 0) return false;

      final setCookies = refreshResp.headers.map['set-cookie'];
      final newSessdata = _extractFromSetCookie('SESSDATA', setCookies);
      final newJct = _extractFromSetCookie('bili_jct', setCookies);
      final newRefreshToken =
          ((refresh['data'] as Map<String, dynamic>?)?['refresh_token'] ?? '').toString();
      if (newSessdata == null || newSessdata.isEmpty) return false;
      await _saveCredentials(
        sessdata: newSessdata,
        jct: newJct,
        refreshToken: newRefreshToken.isEmpty ? null : newRefreshToken,
      );

      // 5. 确认更新：让旧 refresh_token 对应的凭据失效（官方要求，防滥用）
      await _dio.post(
        'https://passport.bilibili.com/x/passport-login/web/confirm/refresh',
        data: 'csrf=${newJct ?? ''}&refresh_token=$refreshToken',
        options: Options(
          headers: await _headers(),
          contentType: Headers.formUrlEncodedContentType,
        ),
      );
      return true;
    } catch (_) {
      return false; // 静默失败，继续使用旧登录态
    }
  }

  /// B站固定公钥 RSA-OAEP(SHA-256, MGF1-SHA256) 加密 refresh_{timestamp}，密文转小写hex
  String _generateCorrespondPath(int timestamp) {
    final pub = RSAPublicKey(_bigIntFromBase64Url(_refreshPubKeyN), BigInt.from(65537));
    final cipher = OAEPEncoding.withSHA256(RSAEngine());
    cipher.init(true, PublicKeyParameter<RSAPublicKey>(pub));
    final plain = Uint8List.fromList(utf8.encode('refresh_$timestamp'));
    final encrypted = cipher.process(plain);
    return encrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  BigInt _bigIntFromBase64Url(String s) {
    var padded = s.replaceAll('-', '+').replaceAll('_', '/');
    final mod = padded.length % 4;
    if (mod != 0) padded += '=' * (4 - mod);
    final bytes = base64.decode(padded);
    return BigInt.parse(
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);
  }

  // ============ 登录态验证 ============

  /// 校验登录态是否有效（调用 nav 接口），顺带做一次自动续期
  Future<BiliLoginStatus> verifyLogin() async {
    final sess = await getSessdata();
    if (sess == null || sess.isEmpty) {
      return BiliLoginStatus(isLogin: false, uname: '', message: '未配置登录态');
    }
    try {
      await refreshCookieIfNeeded();
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
    // 拉取前静默续期登录态（登录态即将到期时自动换新，用户无感）
    await refreshCookieIfNeeded();
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
