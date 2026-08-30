# B站登录态获取 / 验证 / 自动续期 / AI字幕 —— 跨项目复用说明

> 本文档整理自「多多」App 已验证可用的实现（`lib/services/bilibili_service.dart`），
> 目标是让任何项目（不限语言）都能照着接入。所有接口均于 2026-08 实测通过。

---

## 0. 结论速览

| 需求 | 结论 |
| --- | --- |
| B站有没有个人 OAuth 授权 | ❌ 开放平台只面向企业/创作者（稿件、直播），个人用户无授权入口 |
| 能否拉起系统浏览器拿登录态 | ❌ 浏览器 Cookie 沙箱隔离，第三方 App 读不到 |
| **推荐方式** | ✅ **B站APP扫码登录**：纯 HTTP 接口，无需 WebView，Android/iOS/桌面/Web 全平台可用 |
| 登录态绑定什么 | 账号会话，**不绑设备、不绑应用**；SESSDATA 可复制到其他软件直接用 |
| 登录态有效期 | 约 **1 个月**；过期前 B站接口会提示可刷新，可用 refresh_token 无限续期 |
| 续期前提 | 保存了登录时返回的 `refresh_token` 和 `bili_jct`(csrf)；手动粘贴 SESSDATA 无法续期 |
| 多软件共用 | SESSDATA 可共享（只读）；**refresh_token 只能由一个客户端持有续期**，否则互踢 |

---

## 1. 扫码登录

### 1.1 创建二维码

```
GET https://passport.bilibili.com/x/passport-login/web/qrcode/generate
Headers:
  User-Agent: Mozilla/5.0 (...)          # 普通浏览器 UA
  Referer: https://www.bilibili.com/
```

响应：
```json
{ "code": 0, "data": { "qrcode_key": "xxx", "url": "https://account.bilibili.com/h5/account-h5/auth/scan-web?...qrcode_key=xxx" } }
```
把 `data.url` 的内容渲染成二维码图片展示给用户（任何 QR 渲染库都行，
Dart 可用纯 Dart 的 `qr_flutter`，无原生依赖）。

### 1.2 轮询扫码状态（每 2 秒一次）

```
GET https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key={key}
```

`data.code` 状态：
| code | 含义 | 处理 |
| --- | --- | --- |
| 86101 | 未扫码 | 继续轮询 |
| 86090 | 已扫码未确认 | 提示「请在手机上确认」 |
| 86038 | 二维码过期（约3分钟） | 重新 generate，继续轮询 |
| 0 | **登录成功** | 见下 |

登录成功时：
- **新 Cookie 在响应的 `Set-Cookie` 头里**：`SESSDATA`、`bili_jct`、`DedeUserID` 等，逐一解析保存
- 同样的值也出现在 `data.url`（crossDomain 链接的查询参数）里，可作备用提取来源
  （注意 SESSDATA 的值**可能含逗号**，解析时按 `;` 截断，别按逗号切）
- `data.refresh_token`：**持久化刷新口令，必须保存**，续期全靠它

> 提取优先级建议：Set-Cookie 头 → data.url 参数。两处内容一致。

### 1.3 验证登录态是否有效

```
GET https://api.bilibili.com/x/web-interface/nav        (带 SESSDATA Cookie)
```
`code == 0 且 data.isLogin == true` → 有效，`data.uname` 是昵称；
`code == -101` → 已失效，需要重新扫码。

---

## 2. 自动续期（官方 Cookie 刷新流程）

B站网页端自己的续期机制，第三方照做即可。只在 B站说「该刷了」时执行，
平时调用无副作用。

### 2.1 检查是否需要刷新

```
GET https://passport.bilibili.com/x/passport-login/web/cookie/info?csrf={bili_jct}
(带 SESSDATA + bili_jct Cookie)
```
响应 `data.refresh`：`true` = 需要刷新；`data.timestamp`：当前毫秒时间戳（下一步要用这个值，别用本地时钟）。
`code == -101` 表示登录已失效，跳过。

### 2.2 生成 correspondPath（RSA-OAEP）

明文：`refresh_{timestamp}`（timestamp 为 2.1 返回值）
算法：**RSA-OAEP，摘要 SHA-256，MGF1 也用 SHA-256**，密文转小写 hex。

固定公钥（JWK，1024-bit，B站官方 wasm 逆向而来，全平台通用）：
```json
{
  "kty": "RSA",
  "n": "y4HdjgJHBlbaBN04VERG4qNBIFHP6a3GozCl75AihQloSWCXC5HDNgyinEnhaQ_4-gaMud_GF50elYXLlCToR9se9Z8z433U3KjM-3Yx7ptKkmQNAMggQwAVKgq3zYAoidNEWuxpkY_mAitTSRLnsJW-NCTa0bqBFF6Wm1MxgfE",
  "e": "AQAB"
}
```

各语言实现要点：
- JS (Web/Node)：`crypto.subtle.importKey("jwk", …, {name:"RSA-OAEP", hash:"SHA-256"})` 后 encrypt
- Python：`pycryptodome` 的 `PKCS1_OAEP.new(key, SHA256)`（MGF1 默认跟随同一摘要）
- Java/Kotlin：`Cipher.getInstance("RSA/ECB/OAEPPadding")` + `OAEPParameterSpec("SHA-256","MGF1",MGF1ParameterSpec.SHA256,…)`
- Dart：`pointycastle` 的 `OAEPEncoding.withSHA256(RSAEngine())`
  （JWK 的 n 是 base64url 无填充，解码成大端字节再转 BigInt 即为模数）
- 输出校验：1024-bit 密钥 → 密文 128 字节 → **hex 串长 256**

### 2.3 用 correspondPath 换实时口令 refresh_csrf

```
GET https://www.bilibili.com/correspond/1/{correspondPath}    (带 SESSDATA Cookie)
```
返回一个 SSR HTML 页面，刷新口令在 `<div id="1-name">{refresh_csrf}</div>` 里，正则提取即可。
若 correspondPath 错误/过期返回 404。

### 2.4 执行刷新

```
POST https://passport.bilibili.com/x/passport-login/web/cookie/refresh
Content-Type: application/x-www-form-urlencoded
Cookie: 旧 SESSDATA + 旧 bili_jct

csrf={旧bili_jct}&refresh_csrf={上一步}&source=main_web&refresh_token={旧refresh_token}
```
成功（code 0）后：
- **新 SESSDATA / bili_jct 在 Set-Cookie 头里**，覆盖保存
- **新 refresh_token 在 `data.refresh_token`**，覆盖保存（旧的马上要作废）

### 2.5 确认更新（作废旧凭据，官方要求）

```
POST https://passport.bilibili.com/x/passport-login/web/confirm/refresh
csrf={新bili_jct}&refresh_token={旧refresh_token}
Cookie: 新 SESSDATA
```
这一步让旧 refresh_token 失效，防止凭据被滥用。**注意 csrf 用新的，refresh_token 用旧的。**

### 2.6 工程实践建议

- 把整个续期包在 try/catch 里**静默失败**：任何一步出错都继续用旧 Cookie，不影响业务
- 触发时机：每次调用敏感接口（如拉字幕）前顺手调一次「检查+按需刷新」；或每日首次使用时
- 多客户端场景：**同一账号的 refresh_token 只能存在于一个客户端**。刷新并 confirm 后旧 token 作废，
  另一个客户端再刷会报 86095（refresh_csrf 错误或 refresh_token 与 cookie 不匹配）
- 手动粘贴 SESSDATA 接入的用户没有 refresh_token/bili_jct，无法续期，到期只能重扫

---

## 3. AI 字幕获取（登录态的主要用途）

```
1) GET https://api.bilibili.com/x/web-interface/view?bvid={BV号}
   → data.cid（分P视频取 data.pages[p-1].cid）、data.title、data.aid

2) GET https://api.bilibili.com/x/player/wbi/v2?bvid={BV}&cid={cid}&aid={aid}
   (必须带 SESSDATA，否则 subtitles 为空；失败可回退旧接口 /x/player/v2)
   → data.subtitle.subtitles[]，lan == "ai-zh" 即 AI 字幕（其次 zh-CN CC字幕）
   → 取 subtitle_url（注意常以 // 开头，需补 https:）

3) GET {subtitle_url}   (不需要 Cookie)
   → JSON { body: [ { from, to, content } ... ] }
   → 只取 content 拼接即可（时间轴按需保留）
```
支持 `bilibili.com/video/BVxxx`、`b23.tv` 短链（跟随重定向后正则提 BV）、`?p=N` 分P。

---

## 4. 请求头通用要求

```
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) ... Chrome/125 Safari/537.36
Referer: https://www.bilibili.com/
Cookie: SESSDATA=xxx; bili_jct=yyy        # 需要登录态的接口
```

---

## 5. 常用端点速查

| 用途 | 端点 | 鉴权 |
| --- | --- | --- |
| 生成登录二维码 | `passport.bilibili.com/x/passport-login/web/qrcode/generate` | 无 |
| 轮询扫码 | `passport.bilibili.com/x/passport-login/web/qrcode/poll` | 无 |
| 验证登录 | `api.bilibili.com/x/web-interface/nav` | Cookie |
| 检查刷新 | `passport.bilibili.com/x/passport-login/web/cookie/info` | Cookie |
| 刷新凭据 | `passport.bilibili.com/x/passport-login/web/cookie/refresh` | Cookie |
| 确认刷新 | `passport.bilibili.com/x/passport-login/web/confirm/refresh` | Cookie |
| 视频信息 | `api.bilibili.com/x/web-interface/view` | 无 |
| 字幕列表 | `api.bilibili.com/x/player/wbi/v2` | **必须** |
| 字幕文件 | `aisubtitle.hdslb.com/...`（来自字幕列表） | 无 |

---

## 6. 参考实现（本项目）

- Dart 完整实现：`lib/services/bilibili_service.dart`（扫码 + 续期 + 字幕 + SQLite 入库）
- 扫码 UI：`lib/features/settings/qr_login_dialog.dart`（二维码 + 2s 轮询 + 过期自动重生成）
- 官方社区文档：bilibili-API-collect 的 `docs/login/cookie_refresh.md` 与 QR 登录章节

## 7. 风险与合规提示

- 以上均为 B站网页版公开行为的逆向整理，非官方开放 API，接口行为可能变化
- 控制调用频率（字幕、轮询均已内置合理间隔），高频请求可能触发风控（要求验证/重新登录）
- 登录凭据等同账号密码，只存用户本机，不要上报服务器、不要写进日志
