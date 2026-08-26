# OpenCode-Go-Quotas

把 [Ruinique/opencode-go-dashboard](https://github.com/Ruinique/opencode-go-dashboard) 改造成的原生 Swift 应用。
现代化 SwiftUI 界面(SVG 装饰 + 渐变仪表环):每个 opencode 账号展示 **Rolling / Weekly / Monthly** 三档用量与重置倒计时,附逐请求用量历史(今日 / 本周 / 本月 / 全部)。

同时内置 **GitHub 多账号管理**:批量导入、TOTP 验证码生成、Keychain 安全存储,并支持用 GitHub 账号一键自动登录 opencode.ai、自动捕获 auth Cookie。

数据获取逻辑与原项目 **1:1 移植**(`Sources/OpenCodeGo-Quotas/QuotaClient.swift` 对应原 `src/worker/quota.ts`):
- 额度:GET `https://opencode.ai/workspace/{ws}/go`,解析页面内嵌的 `rollingUsage/weeklyUsage/monthlyUsage/plan`
- 历史:POST `https://opencode.ai/_server`(SolidStart RPC),按 `id:"usg_xxx"` 锚点切块解析逐请求用量与费用

## Cookie 获取:一键导入 or 手动

- **自动导入**:添加账号时一键从本机 **Chrome / Edge** 读取 opencode.ai 的 `auth` Cookie(自动遍历所有配置文件,支持 Chrome 127+ 的新版加密:Keychain 口令 → PBKDF2 → AES-128-CBC → 剥离 32 字节 host 前缀)
- **手动填写**:浏览器 F12 → Application → Cookies → 复制 `auth` 值(`Fe26.` 开头)
- 首次读取浏览器 Keychain 口令时系统会弹一次授权提示(仅浏览器侧;应用自身存 Keychain 的 Cookie / 凭据已配置免提示访问,见「安全设计」)

## GitHub 多账号管理

集中管理用于登录 opencode.ai 的 GitHub 账号凭据,与 opencode 额度查询互相独立,通过主界面顶部标签切换。

### 批量导入

- 支持 **Tab / 逗号 / 分号 / 空格** 分隔,每行 `用户名, 密码, TOTP密钥或6位验证码`(第三列可省略,`#` 开头为注释行)
- 支持**粘贴文本**或**导入 CSV/TXT 文件**;逐行解析预览,无效行不阻塞有效行,导入完成后显示「导入 N 条,跳过 M 条」摘要
- 空格分隔要求恰好 3 列(避免误拆带空格的用户名);用户名已存在的行自动跳过(不覆盖,防止手滑覆盖现有账号)

### 2FA 验证码

- 粘贴 **TOTP secret**(base32,如 `JBSWY3DPEHPK3PXP`)后,卡片上随时生成当前 6 位验证码,带 **30 秒倒计时**(剩余 ≤5 秒高亮提醒)
- 粘贴 **6 位纯数字**按一次性验证码处理,显示「验证码 60 秒后失效」,过期后标记「已失效」
- 卡片「复制验证码」/「复制密码」复制到剪贴板后 **45 秒自动清除**(新复制或视图关闭时重新计时/取消)

### 安全

- 密码与 TOTP secret / 一次性验证码**只存 Keychain**(service `com.acccan.opencode-go.github`),不落盘、不打印、不上传
- 元数据 JSON(`github-accounts.json`)只有用户名/备注/凭据类型等非敏感字段

### 一键自动登录

- 用已导入的 GitHub 账号在应用内完成 opencode.ai 登录:自动填用户名/密码、自动输入 TOTP 验证码、自动点授权,捕获 auth Cookie 后填入账号表单(操作步骤见「使用」)
- **Workspace ID 可留空**:登录成功后从跳回的工作区 URL 自动识别 ID 并回填表单,无需预先填写
- **登录成功自动保存**:「添加账号」场景下捕获 Cookie 后自动创建账号(名称留空时用 GitHub 用户名兜底);保存前查重——同一表单已自动保存过、或识别到的 Workspace 已被现有账号占用时不再保存,并给出对应提示
- 需要所选账号的密码已保存;开启两步验证的账号请先保存 TOTP 密钥或一次性验证码;一次性验证码超过 90 秒(GitHub 30 秒轮换 + 宽限)自动视为过期,不再自动填入,改为在登录窗口手动输入当前码

## 安全设计

- **Cookie 存 Keychain**,不落盘、不打印、不上传
- **GitHub 密码 / TOTP secret / 一次性验证码同样只存 Keychain**(service `com.acccan.opencode-go.github`),与 opencode Cookie 同级保护
- 账号元数据 + 上次额度快照存 `~/Library/Application Support/OpenCode-Go-Quotas/accounts.json`
- GitHub 账号元数据(用户名/备注/凭据类型)存 `~/Library/Application Support/OpenCode-Go-Quotas/github-accounts.json`,无敏感字段
- 所有请求只读,不消耗配额
- **钥匙串免提示**:应用自身的 Keychain 项(Cookie / 密码 / 凭据)带「仅本 app 免提示访问」ACL,启动时自动把既有项迁移为同一 ACL——历次更新不再重复弹授权。前提是**分发/交付构建用「OpenCodeGo Dev」证书身份签名**(ACL 可信应用需求取自签名身份,ad-hoc 每次重签名即失效、需重新授权),详见仓库 CLAUDE.md「签名约定」

### 数据安全(写前快照 + 损坏自动回退)

- `accounts.json` / `github-accounts.json` 每次写盘前自动把当前文件复制成滚动快照(`*.json.bak`,单份覆盖)
- 启动时若主文件损坏(解码失败)→ 自动从快照恢复;损坏原件另存为 `*.bak-<时间戳>` 留证,界面横幅提示「已从备份恢复数据」
- 快照缺失或同样损坏 → 损坏原件备份后按空列表启动,并明确提示「请检查后重新添加」,绝不静默清空(避免下次保存把真实数据永久覆盖)
- 上述提示显示在页面顶部的红色警告横幅(任一数据文件出错即显示,「知道了」仅本次会话隐藏);Store 首次成功保存后自动清除错误状态

## 构建与运行

```bash
# 开发模式直接跑(无界面验证 UI 用 --demo)
swift run OpenCode-Go-Quotas --demo

# 打包成 .app(双击运行)
bash scripts/bundle-app.sh
open dist/OpenCode-Go-Quotas.app

# 一键产出安装包(渲染图标 → 生成 icns → 打包 dmg,输出 ~/Desktop/OpenCode-Go-Quotas-0.1.0.dmg)
bash tools/build-dmg.sh
```

> `tools/build-dmg.sh` 组装过程中用「OpenCodeGo Dev」证书身份签名(身份未导入则退回
> ad-hoc),使钥匙串 ACL 免提示需求跨版本稳定;前置为 `swift build -c release` 与
> `pip3 install --user ds_store`。

> 注意:`swift test` 需要完整 Xcode(本机 dev 目录指向 CommandLineTools):
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

## 使用

### opencode 额度

1. 「添加账号」→ 在「从浏览器自动获取」区选择 Chrome/Edge → 检测到 auth Cookie → 点「填入」
2. 填账号名称;Workspace ID 可留空——用 GitHub 账号自动登录成功后自动识别回填(手动添加仍需填 `wrk_xxx`,工作区 URL 里可见)
3. 点「全部刷新」看三档额度仪表环(刷新行为见下);点卡片「用量历史」按日/周/月查看消耗与费用

### GitHub 账号

1. 顶部标签切到「GitHub 账号」
2. 「批量导入」→ 粘贴文本或选择 CSV/TXT 文件 → 预览逐行解析结果 → 确认导入(无效行自动跳过并列出原因)
3. 单个账号:「添加账号」→ 填用户名、密码(可显隐)、验证码/TOTP 密钥(6 位数字按一次性验证码,其余按 base32 TOTP 密钥识别)、备注
4. 卡片上点「复制验证码」/「复制密码」直接取用(复制后剪贴板 45 秒自动清除);TOTP 密钥账号实时显示当前 6 位验证码与 30 秒倒计时;一次性验证码显示 60 秒失效倒计时,过期显示「已失效」

### GitHub 一键登录 opencode.ai

1. 「添加账号」(或编辑已有 opencode 账号)→ 在「用 GitHub 账号自动登录」区选择 GitHub 账号;Workspace ID 可先留空
2. 点「开始自动登录」,应用在独立窗口内自动完成:打开 opencode.ai → 跳转 GitHub 登录 → 自动填用户名/密码 → 自动输入 TOTP 验证码(未保存、或一次性验证码已超过 90s 过期时提示手动输入)→ 自动点「Authorize」
3. 捕获 opencode auth Cookie 后自动填入表单;Workspace ID 从登录后跳回的工作区 URL 自动识别回填。「添加账号」场景自动保存并关闭表单(保存前查重——同表单已保存过、Workspace 已被占用则不再保存并提示);「编辑」场景只回填,点「保存」完成

## 刷新行为

- **并行刷新**:「全部刷新」并发抓取所有账号额度(总耗时 ≈ 最慢单个账号,而非串行之和);刷新中按钮显示进度 spinner「刷新中…」并禁用重复点击
- **失败自动重试**:单轮内失败的账号(除 Cookie 缺失等本地错误)自动重试 1 次,按失败序号错开 250ms × n 短退避错峰;重试成功覆盖首轮错误,仍失败以重试错误为准——不跨轮、不无限重试
- **加载失败横幅**:任一数据文件(accounts.json / github-accounts.json)损坏、自动恢复或置空时,页面顶部显示红色警告横幅及具体提示(见「数据安全」);「知道了」仅本次会话隐藏,首次成功保存后错误状态自动清除

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

286 个单测覆盖:额度/历史解析(URLProtocol mock,含非 HTTP 响应容错、超时/取消、永久错误不重试)、cookie 解密 round-trip(本地构造 Chrome 127+ 加密样本)、
TOTP 生成(RFC 6238 向量 + base32 变体 + 倒计时边界)、GitHub 批量导入解析(分隔符/引号/凭据类型推断)、
GitHub 账号存储(内存 Keychain mock,读写/去重/导入摘要)、导入预览行级解析(无效行不阻塞)、
GitHub 自动登录状态机(URL→决策/JS 转义/cookie 提取,含终态守卫/超时重启/过期码不填入)、
一次性注入受控重试(退避序列/未命中判定)、自动保存查重(同表单防重/Workspace 查重)、
数据文件写前快照与损坏自动恢复、刷新失败自动重试与 isRefreshing 状态、
统一 JSON 文件存储(快照/损坏备份/恢复)、登录/诊断日志轮转、共享 TOTP 时钟、用量统计缓存与部分数据提示、
钥匙串免提示 ACL 迁移(指纹重迁移)、费用格式化(保底 2 位小数)、demo 隔离与凭据清除。

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
- 一次性验证码 60 秒后失效,需重新导入或编辑更新(应用会明确提示);自动登录中超过 90 秒(GitHub 30 秒轮换 + 宽限)视为过期,不再自动填入,改为在登录窗口手动输入当前码
- GitHub 一键自动登录依赖已保存的密码与 TOTP 密钥/一次性验证码:未保存时需手动在登录窗口内完成;GitHub 通行密钥、设备验证与风控页面同样需手动处理
- GitHub 凭据仅存本机 Keychain,更换设备需重新导入
- 仅 macOS 14+
- 浏览器 Cookie 需为持久化 Cookie 才会落盘;若在隐私模式下登录则可能读不到
- 钥匙串免提示依赖「OpenCodeGo Dev」证书身份签名:其他构建(如 ad-hoc)每次重签名后需重新授权一次
