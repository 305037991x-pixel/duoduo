# 多多学 Duoduo Learn

> 多邻国风格的自定义题库学习 APP — 创建你自己的知识题包，AI 帮你拆题，游戏化打卡学习。

## 功能特色

### 学习模式
- **知识点模式**：按题包顺序学习，巩固特定主题
- **随机挑战模式**：跨题包随机出题，检验综合掌握程度

### 题型支持
- 单选题 / 多选题
- 判断题
- 填空题
- 匹配题
- 排序题

### AI 拆题
- 粘贴文本或分享内容到 APP，AI 自动生成题目
- 支持多厂商 AI 接口（OpenAI 兼容协议）
- 拍照识别文本，一键生成题包

### 游戏化系统
- **经验值 (XP)**：答题获得 XP，升级你的学习等级
- **连续打卡 (Streak)**：每日学习保持连续天数
- **心数系统 (Hearts)**：答错扣心，完美通关恢复
- **每日目标**：设定每日 XP 目标，追踪完成进度
- **月度打卡**：月历可视化打卡记录，满 20 天获得勋章
- **成就系统**：21 个成就徽章，覆盖连续学习、经验值、答题数、题包、完美通关、月度打卡等维度

## 技术栈

| 分类 | 技术 |
|------|------|
| 框架 | Flutter 3.x (Dart 3.x) |
| 状态管理 | Riverpod |
| 本地存储 | SQLite (sqflite) + SharedPreferences |
| 网络请求 | Dio |
| AI 服务 | OpenAI 兼容 API（多厂商支持） |
| 动画 | flutter_animate |
| 字体 | Google Fonts |
| 分享接收 | receive_sharing_intent |

## 项目结构

```
lib/
├── app.dart                    # 主应用入口 & 底部导航
├── main.dart                   # 应用启动
├── core/
│   ├── constants/              # 颜色、主题常量
│   └── providers/              # Riverpod 全局 Provider 定义
├── data/
│   ├── database/               # SQLite 数据库 Helper
│   └── models/                 # 数据模型（Deck, Question, UserStats 等）
├── features/
│   ├── home/                   # 首页（学习路径）
│   ├── deck/                   # 题库管理
│   ├── learning/               # 答题界面 & 题型组件
│   ├── ingestion/              # AI 拆题导入
│   ├── profile/                # 个人页（统计、成就、打卡日历）
│   └── settings/               # 设置页
├── services/
│   ├── gamification_service.dart  # 游戏化服务（XP、打卡、成就）
│   ├── openai_service.dart        # AI 接口服务
│   └── content_analyzer.dart      # 内容分析服务
└── shared/
    └── widgets/                # 公共 UI 组件
```

## 快速开始

### 环境要求
- Flutter 3.x
- Dart 3.x
- Android SDK
- JDK 17+

### 安装运行

```bash
# 克隆仓库
git clone https://github.com/xuanli199/duoduo.git
cd duoduo

# 安装依赖
flutter pub get

# 运行（debug 模式）
flutter run

# 构建 Release APK
flutter build apk --release
```

> 构建时如遇 Java Runtime 缺失，请设置 `JAVA_HOME` 环境变量指向 JDK 17。

### 配置 AI 接口

在 APP 设置页面中配置：
- API 地址（兼容 OpenAI 协议的任意接口）
- API Key
- 模型名称

## 下载

前往 [Releases](https://github.com/305037991x-pixel/duoduo/releases) 页面下载最新 APK。

## License

MIT

## B站字幕接入文档

B站扫码登录、登录态自动续期、AI字幕获取的完整技术方案（可复用到其他项目）：
见 [docs/bilibili-login-auth-and-subtitle.md](docs/bilibili-login-auth-and-subtitle.md)。
