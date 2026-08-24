# docs 批次汇报:README 刷新(b15~b23 特性对齐)(2026-08-25)

基线:dev 合并点 `49c8b21`(ws-loginaudit 合并)。仅改 `README.md` + 本报告文件;未动任何源码。

## 通读核对清单(旧文 → 新文/理由)

| 段 | 旧文(过时/缺失) | 新文(按代码事实) | 事实来源 |
|---|---|---|---|
| Cookie 获取 | 「首次读取浏览器 Keychain 口令时系统会弹一次授权提示」未区分浏览器侧与应用侧 | 加注「(仅浏览器侧;应用自身存 Keychain 的 Cookie/凭据已配置免提示访问,见安全设计)」 | AddEditAccountView 导入区文案 + KeychainHelper selfAccess ACL |
| GitHub 一键自动登录 | 未提 Workspace ID 可留空 | 新增 bullet:登录成功后从跳回的工作区 URL 自动识别并回填 | GitHubLoginView.loadStartPage(ws 无效→opencode.ai 首页)、succeed() 回调 `workspaceId(from: webView?.url)`、AddEditAccountView.handleAuthCookie 回填 |
| 一键自动登录 | 未提自动保存 | 新增 bullet:添加场景自动创建账号(名称留空用 GitHub 用户名兜底)+ 保存前查重(同表单防重 / Workspace 查重) | AddEditAccountView.handleAuthCookie + autoSaveDecision(AutoSaveDecision 三种结果及提示文案) |
| 一键自动登录/使用 | 一次性验证码只说未保存时提示手动 | 补充:超过 90s(GitHub 30s 轮换+宽限)视为过期,不再自动填入,改手动输入当前码 | GitHubLoginService.isOneTimeCodeExpired(>90s)+ totpCodeNow 把关 |
| 安全设计 | 无钥匙串免提示说明 | 新增 bullet:「仅本 app 免提示访问」ACL + 启动时自动迁移既有项 + 分发构建须「OpenCodeGo Dev」证书身份签名(指向 CLAUDE.md) | KeychainHelper.selfAccess / migrateKeysToSelfAccess / runSelfAccessMigration,AccountStore 与 GitHubAccountStore 的 scheduleSelfAccessMigration |
| 安全设计 | 无数据文件防护 | 新增子节「数据安全」:写前滚动快照 *.json.bak(单份覆盖)、启动损坏→快照恢复+原件另存 *.bak-<时间戳> 留证、快照不可用→备份后置空并提示(绝不静默清空)、红色警告横幅+「知道了」会话隐藏、首次成功保存清错误 | AccountStore.load/save/snapshotBeforeWrite/stashCorruptedFile/restoreMainFileFromSnapshot + GitHubAccountStore 同构 + ContentView.loadErrorBanner |
| 构建与运行 | 无 DMG/图标构建入口 | 补 tools/build-dmg.sh(渲染图标→icns→打包 dmg,输出 ~/Desktop/OpenCodeGo-1.0.dmg;OpenCodeGo Dev 证书身份签名优先,未导入退 ad-hoc;前置 swift build -c release + pip3 install --user ds_store) | tools/build-dmg.sh |
| 使用-opencode | 步骤 2 要求填 Workspace ID;步骤 3 写「点刷新」 | 改:Workspace ID 可留空(自动登录成功后识别回填;手动添加仍需填);「全部刷新」(与 hero 按钮文案一致) | AddEditAccountView 提示文案 + ContentView 按钮 |
| 使用-GitHub 一键登录 | 步骤 3 只写「点保存完成」 | 补充:ws 自动识别回填、添加场景自动保存并关闭表单(查重失败则提示)、编辑场景只回填需手动保存 | AddEditAccountView.handleAuthCookie 各分支 |
| (新增)刷新行为 | 整节缺失 | 并行刷新(isRefreshing spinner「刷新中…」+禁用)、失败自动重试 1 次(按失败序号 250ms×n 短退避;Cookie 缺失类本地错误不重试;不跨轮),加载失败横幅见数据安全 | AccountStore.refreshAll(concurrency/retry/isRefreshing)+ ContentView |
| 2FA 验证码 | 缺失剪贴板行为 | 补 bullet + 使用步骤 4:「复制验证码/密码」后剪贴板 45 秒自动清除(新复制/视图关闭重新计时或取消) | GitHubAccountCardView(45s 延迟清理,新旧值比对) |
| 测试 | 「151 个单测」过时(经实测为 209) | 改 209,覆盖列表追加:自动登录终态守卫/超时重启/过期码不填入、自动保存查重、写前快照与损坏恢复、刷新重试与 isRefreshing、Keychain ACL 迁移(指纹重迁移) | `swift test` 实测 209 通过 0 失败;测试文件名核对(AccountStoreConcurrencyTests/AddEditAccountViewTests/KeychainHelperTests/GitHubLoginServiceTests) |
| 已知限制 | 一次性码只写 60s 失效 | 补充自动登录 90s 过期不自动填;新增:钥匙串免提示依赖 OpenCodeGo Dev 证书身份签名,ad-hoc 每次重签名需重新授权 | GitHubLoginService.isOneTimeCodeExpired + KeychainHelper 注释 |

## 核对通过(维持原样)的旧内容

- 「2FA 验证码」30s 倒计时、剩余 ≤5s 橙色高亮 → GitHubAccountCardView `remaining <= 5 ? .orange` ✔
- 「验证码 60 秒后失效 / 已失效」卡片文案 ✔;与自动登录 90s 判定是两处不同语义(卡片显示 vs 自动填入窗口),README 已分述
- 「TOTP 生成/批量导入/安全存储/1:1 移植数据获取/仅 macOS 14+」等 → 与代码一致,未动

## 实际改动

- `README.md` → 按上表 7 处更新 + 1 处新增小节(刷新行为)+ 1 处新增子节(数据安全)+ 测试数与覆盖列表刷新
- `REPORT.md` → 本汇报(工作区根,按批次约定位置,覆盖 ws-loginaudit 旧报告;旧内容已在 dev 历史中)

## 门禁结果

- 本批次为 README-only:无编译/测试要求
- `swift test`(full Xcode,后台运行):**209 通过 / 0 失败**(实测,顺带核实 README 测试数取 209 而非沿用旧 151)
- `git diff --check`:通过
- 改动文件:仅 README.md + REPORT.md;无凭据/密码引入;git status 无其他污染

## 遇到的问题

- 无 BLOCKED 级问题。两处裁决点:
  1. `REPORT.md` 按任务约定仍写工作区根,覆盖了 ws-loginaudit 的旧报告(其内容保留在 dev 提交历史 `baf884b`),如需旧报告留档请从历史取。
  2. 剪贴板 45s 自动清除不在任务列的 b15~b23 清单内,但属用户可见行为且此前未记载,已补一行(宁缺毋滥的两可项,可驳回重发)。

## 证据

- 测试输出摘要:Test Suite 'All tests' passed — Executed 209 tests, with 0 failures(2026-08-25 06:12:01)
- `git diff --check` 退出码 0;`git status --short` 仅 `M README.md`
- 事实核对源码:AccountStore.swift(GitHubAccountStore.swift 同构)、ContentView.swift、AddEditAccountView.swift、GitHubLoginView.swift、GitHubLoginService.swift(90s 判定)、KeychainHelper.swift(ACL/迁移)、GitHubAccountCardView.swift(45s/≤5s)、tools/build-dmg.sh

门禁: PASSED
结论: OK
