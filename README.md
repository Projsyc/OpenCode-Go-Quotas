# OpenCodeGo — OpenCode Go 多账号额度查询 + GitHub 多账号管理 (macOS)

把 [Ruinique/opencode-go-dashboard](https://github.com/Ruinique/opencode-go-dashboard) 改造成的原生 Swift 应用。
现代化 SwiftUI 界面(SVG 装饰 + 渐变仪表环):每个 opencode 账号展示 **Rolling / Weekly / Monthly** 三档用量与重置倒计时,附逐请求用量历史(今日 / 本周 / 本月 / 全部)。

同时内置 **GitHub 多账号管理**:批量导入、TOTP 验证码生成、Keychain 安全存储,并支持用 GitHub 账号一键自动登录 opencode.ai、自动捕获 auth Cookie。

数据获取逻辑与原项目 **1:1 移植**(`Sources/OpenCodeGo/QuotaClient.swift` 对应原 `src/worker/quota.ts`):
- 额度:GET `https://opencode.ai/workspace/{ws}/go`,解析页面内嵌的 `rollingUsage/weeklyUsage/monthlyUsage/plan`
- 历史:POST `https://opencode.ai/_server`(SolidStart RPC),按 `id:"usg_xxx"` 锚点切块解析逐请求用量与费用

## Cookie 获取:一键导入 or 手动

- **自动导入**:添加账号时一键从本机 **Chrome / Edge** 读取 opencode.ai 的 `auth` Cookie(自动遍历所有配置文件,支持 Chrome 127+ 的新版加密:Keychain 口令 → PBKDF2 → AES-128-CBC → 剥离 32 字节 host 前缀)
- **手动填写**:浏览器 F12 → Application → Cookies → 复制 `auth` 值(`Fe26.` 开头)
- 首次读取浏览器 Keychain 口令时系统会弹一次授权提示

## GitHub 多账号管理

集中管理用于登录 opencode.ai 的 GitHub 账号凭据,与 opencode 额度查询互相独立,通过主界面顶部标签切换。

### 批量导入

- 支持 **Tab / 逗号 / 分号 / 空格** 分隔,每行 `用户名, 密码, TOTP密钥或6位验证码`(第三列可省略,`#` 开头为注释行)
- 支持**粘贴文本**或**导入 CSV/TXT 文件**;逐行解析预览,无效行不阻塞有效行,导入完成后显示「导入 N 条,跳过 M 条」摘要
- 空格分隔要求恰好 3 列(避免误拆带空格的用户名);用户名已存在的行自动跳过(不覆盖,防止手滑覆盖现有账号)

### 2FA 验证码

- 粘贴 **TOTP secret**(base32,如 `JBSWY3DPEHPK3PXP`)后,卡片上随时生成当前 6 位验证码,带 **30 秒倒计时**(剩余 ≤5 秒高亮提醒)
- 粘贴 **6 位纯数字**按一次性验证码处理,显示「验证码 60 秒后失效」,过期后标记「已失效」

### 安全

- 密码与 TOTP secret / 一次性验证码**只存 Keychain**(service `com.acccan.opencode-go.github`),不落盘、不打印、不上传
- 元数据 JSON(`github-accounts.json`)只有用户名/备注/凭据类型等非敏感字段

### 一键自动登录

- 用已导入的 GitHub 账号在应用内完成 opencode.ai 登录:自动填用户名/密码、自动输入 TOTP 验证码、自动点授权,捕获 auth Cookie 后填入账号表单(操作步骤见「使用」)
- 需要所选账号的密码已保存;开启两步验证的账号请先保存 TOTP 密钥或一次性验证码

## 安全设计

- **Cookie 存 Keychain**,不落盘、不打印、不上传
- **GitHub 密码 / TOTP secret / 一次性验证码同样只存 Keychain**(service `com.acccan.opencode-go.github`),与 opencode Cookie 同级保护
- 账号元数据 + 上次额度快照存 `~/Library/Application Support/OpenCodeGo/accounts.json`
- GitHub 账号元数据(用户名/备注/凭据类型)存 `~/Library/Application Support/OpenCodeGo/github-accounts.json`,无敏感字段
- 所有请求只读,不消耗配额

## 构建与运行

```bash
# 开发模式直接跑(无界面验证 UI 用 --demo)
swift run OpenCodeGo --demo

# 打包成 .app(双击运行)
bash scripts/bundle-app.sh
open dist/OpenCodeGo.app
```

> 注意:`swift test` 需要完整 Xcode(本机 dev 目录指向 CommandLineTools):
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

## 使用

### opencode 额度

1. 「添加账号」→ 在「从浏览器自动获取」区选择 Chrome/Edge → 检测到 auth Cookie → 点「填入」
2. 填账号名称 + Workspace ID(`wrk_xxx`,工作区 URL 里可见)
3. 点「刷新」看三档额度仪表环;点卡片「用量历史」按日/周/月查看消耗与费用

### GitHub 账号

1. 顶部标签切到「GitHub 账号」
2. 「批量导入」→ 粘贴文本或选择 CSV/TXT 文件 → 预览逐行解析结果 → 确认导入(无效行自动跳过并列出原因)
3. 单个账号:「添加账号」→ 填用户名、密码(可显隐)、验证码/TOTP 密钥(6 位数字按一次性验证码,其余按 base32 TOTP 密钥识别)、备注
4. 卡片上点「复制验证码」/「复制密码」直接取用;TOTP 密钥账号实时显示当前 6 位验证码与 30 秒倒计时;一次性验证码显示 60 秒失效倒计时,过期显示「已失效」

### GitHub 一键登录 opencode.ai

1. 「添加账号」(或编辑已有 opencode 账号)→ 在「用 GitHub 账号自动登录」区选择 GitHub 账号
2. 点「开始自动登录」,应用在独立窗口内自动完成:打开 opencode.ai → 跳转 GitHub 登录 → 自动填用户名/密码 → 自动输入 TOTP 验证码(未保存验证码时提示手动输入)→ 自动点「Authorize」
3. 捕获 opencode auth Cookie 后自动填入表单 → 点「保存」完成

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

151 个单测覆盖:额度/历史解析(URLProtocol mock,含非 HTTP 响应容错)、cookie 解密 round-trip(本地构造 Chrome 127+ 加密样本)、
TOTP 生成(RFC 6238 向量 + base32 变体 + 倒计时边界)、GitHub 批量导入解析(分隔符/引号/凭据类型推断)、
GitHub 账号存储(内存 Keychain mock,读写/去重/导入摘要)、导入预览行级解析(无效行不阻塞)、
GitHub 自动登录状态机(URL→决策/JS 转义/cookie 提取)、费用格式化(保底 2 位小数)、demo 隔离与凭据清除。

## 与原项目的差异

| | 原项目 | 本应用 |
|---|---|---|
| 形态 | Cloudflare Worker + React 自托管面板 | 原生 macOS SwiftUI app |
| Cookie 来源 | 手动复制粘贴 | Chrome/Edge 一键导入或手动 |
| Cookie 存放 | 服务器 D1 数据库 | 本机 Keychain |
| 部署 | 需 Cloudflare 账号 | 免部署 |

## 已知限制

- opencode.ai 页面结构变更后解析逻辑需同步更新(与原项目相同)
- Cookie 过期时应用会明确提示;可用 GitHub 一键自动登录重登,或重新导入/复制更新
- 一次性验证码 60 秒后失效,需重新导入或编辑更新(应用会明确提示)
- GitHub 一键自动登录依赖已保存的密码与 TOTP 密钥/一次性验证码:未保存时需手动在登录窗口内完成;GitHub 通行密钥、设备验证与风控页面同样需手动处理
- GitHub 凭据仅存本机 Keychain,更换设备需重新导入
- 仅 macOS 14+
- 浏览器 Cookie 需为持久化 Cookie 才会落盘;若在隐私模式下登录则可能读不到
