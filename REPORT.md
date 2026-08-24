# ghaudit 审计报告(GitHub 导入/账号管理路径健壮性审计)

日期:2026-08-25
工作区:`dm-wt-ghaudit`(分支 `ws-ghaudit`,基于 dev 6282836)
审计对象:`GitHubImportParser.swift`、`GitHubAccountStore.swift`、`GitHubAccountCardView.swift`、
`GitHubEditView.swift`、`GitHubImportView.swift`(+ 对应测试)。
结论先行:**1 个严重 bug(CRLF 整段不切分)、2 个高危(一次性码过期不刷新、添加态类型残留卡死保存)、
5 个中危修复,全部落地**;4 项列为建议未改(涉及语义变更/较大改动),详见「未修复问题与建议」。

## 一、问题清单(按严重度排序)

### 严重(修复)

| # | 问题 | 触发路径 | 影响 | 修复 | commit |
|---|---|---|---|---|---|
| S1 | **CRLF 文本整段不切分** | 粘贴/导入 Excel、Windows 导出的 CRLF CSV/TXT | `text.split(separator: "\n")` 按 Character 切分,CR+LF 在 Unicode 字素簇(TR29 GB3)中是**单一簇**,`"\n"` 不是独立 Character → 整份文本 split 恒为 1 段,被当成一行:逗号文件报「列数过多(实际 N 列)」,Tab 文件字段混入 `\r\n`。**任何 CRLF 文件导入必失败**。`parse` 与 `previewRows` 两处切分点均受影响 | ✅ 新增 `splitLines`(CRLF / 单独 CR / LF 归一化为 `\n` 后按行切分,空行保留、行号不漂移),两处共用 | 05b82c3 |
| S2 | **一次性验证码过期状态不自刷新** | 卡片展示 oneTimeCode 账号,静置 > 60s | 过期判定在 body 一次性渲染(`Date()` 求值一次),无 Timeline 驱动 → 「验证码 60 秒后失效」永远不翻转为「已失效」(悬停等重渲染才变);错误状态误导用户继续使用已过期验证码 | ✅ 改为 `TimelineView(.periodic 1s)` 周期驱动(context.date);判定提取为纯函数 `isOneTimeCodeExpired(_:at:)` | 1081977 |
| S3 | **添加态凭据类型残留卡死保存** | 「添加 GitHub 账号」:输入凭据(auto 推断 kind)→ 清空该字段 → 保存 | kind 残留且选择器已隐藏(仅非空时显示)无法改回;L6 判定 `effectiveKind != account?.credentialKind`(添加态恒 nil≠kind)恒成立 → 纯密码账号永远报「请先填写验证码/TOTP 密钥」,**无法保存,只能放弃重开 sheet** | ✅ 添加态(account == nil)空凭据一律按「无凭据」处理;编辑态保留 L6 保护(类型与已存不一致仍报错) | 1081977 |

### 中(修复)

| # | 问题 | 触发路径 | 影响 | 修复 | commit |
|---|---|---|---|---|---|
| M1 | 第三列为空整行报错 → 毁掉整份导入 | `user1,pass1234,`(Excel 空第三列导出、尾随分隔符均产生) | 报「第三列为空」;`parse` **首错即抛**,一行空列让全盘导入失败(Excel 表格第三列常为空,高频场景) | ✅ 空第三列按「未提供凭据」处理(与 2 列一致) | 396cbaa |
| M2 | store add/update 放行空白用户名 | 直接调 `store.add(username: "john doe")`(编辑器/解析器均已拒绝,store 是最后一环) | 空白用户名入库;影响头像首字母、后续对 GitHub 用户名规则的隐性破坏 | ✅ 新增 `usernameContainsWhitespace`,add/update 抛出 | df799b3 |
| M3 | importBatch 空串凭据写出空凭据 | 直接构造 `GitHubImportRow(credential: "", kind: .totpSecret)`(解析器正常不产出) | 命中 `(credential?, kind?)` 分支 → keychain 写入空串,账号 kind=.totpSecret → **卡片 TOTP 永远显示「—」** | ✅ 行级跳过(「凭据数据缺失」) | df799b3 |
| M4 | importBatch 空白用户名放行 | 同上,直接构造 row | 空白用户名入库 | ✅ 行级跳过(「用户名不能包含空白字符」) | df799b3 |
| M5 | 复制指示器 1.5s 回落竞态 | 1.5s 内再次复制同 target(同验证码 30s 窗口内连点) | 旧 reset Task 先醒来把 `copied` 清掉 → 新一次复制的「已复制」指示只显示约 0.5s,反馈被吞 | ✅ reset 任务纳入取消管理,sleep 被取消即退出(不写状态) | 1081977 |

### 低(修复)

| # | 问题 | 修复 | commit |
|---|---|---|---|
| L1 | 空格分隔拒绝 2 列(`user1 pass123` 报错),与逗号/Tab 支持 2 列不对称;2 token 无歧义(用户名不允许空白) | ✅ 空格分隔接受 2~3 列;4 列及以上报错并提示「密码含空格请用逗号/Tab 分隔」 | 396cbaa |

### 已确认无问题(审计覆盖点)

- **解析器**:引号内分隔符 / `""` 转义 / 引号未闭合报行号 / 首尾空白 trim / TOTP 大小写与 padding(严格 base32)/ 6 位一次性码判定 / 空行与 `#` 注释跳过(行号保留)/ 2 列缺省第三列 / 重复用户名(同文件 + 已存在,size-insensitive)均有测试覆盖。
- **存储**:重复 UUID(User 输入域无此路径)/ 删除最后账号(落盘 `[]` + Keychain 清理)/ add·update·importBatch 半途 Keychain 失败回滚(无孤儿条目、内存不变)/ 损坏快照恢复与留证 / demo 与真实路径硬隔离(内存 Keychain + save 不落盘)。
- **视图**:TOTP 代码与倒计时同取 `context.date`(30s 边界一致,无竞态)/ 45s 剪贴板清理(cancel + 值比对,不误清用户后续复制)/ `secret` 随 `updatedAt` 重载 / 密码永不进 JSON 与预览(「密码已填」)。

## 二、未修复问题与建议(boss 裁决)

1. **密码首尾空白被静默 trim**(中风险):parser(`trimField`)、store(`add`/`update`/`importBatch`)、
   GitHubEditView(`save`)四处一致 trim。GitHub 密码技术上可含首尾空格 → 修剪后静默变成另一个
   密码,登录失败且用户不知情。**涉及三处文件既有语义,属行为变更,未改**。建议:落盘保留
   原值、仅校验用 trim(或对含首尾空格的密码在保存时给出「已去除首尾空格」提示)。
2. **字段中段引号被当引号模式**(低):`us"er"x` 会剥离引号改形字段,未闭合时报「引号未闭合」
   (对不该有引号的场景误导)。标准 CSV 导出不会产出。建议:按 RFC 4180 严格化(仅字段起始/结尾
   的引号进入引号模式),改动较大未做。
3. **带内嵌换行的引号字段不支持**(低):Excel 单元格内换行 → 先按行切分后报「引号未闭合」。
   建议:改为流式解析(引号内换行算内容),改动较大未做。
4. **显式改类型可存入与类型不符的凭据**(低):编辑表单选「TOTP 密钥」但输入 6 位数字 → 卡片
   TOTP 生成失败显示「—」。属用户显式选择,保留;可加「类型与内容不符」警告,未做。
5. **TOTP 复制与显示值跨 30s 边界差 ≤1s**(低):footbar 复制按 `Date()` 重算、显示按
   `context.date`,最坏复制到下一周期新码;1s 内自动刷新,几乎不可感知,未做。
6. **keychain 缺凭据时「读取 TOTP 密钥…」永久显示**(低):数据不一致时误导;M3 已消除主要
   来源。界面可改「未找到密钥」,展示优化未做。
7. **「第 0 行:`<错误>`」**(极低):importBatch 抛非行级错误时 outcome 以 lineNumber 0 展示。
   仅显示瑕疵,未做。

## 三、实际修复清单(4 个 commit)

| commit | 内容 |
|---|---|
| `396cbaa fix(ghaudit): 解析器:空第三列按无凭据处理、空格分隔支持 2 列` | M1 + L1 + 3 个单测 |
| `df799b3 fix(ghaudit): 存储:用户名空白校验下沉到 store + 导入行级防御` | M2 + M3 + M4 + 2 个单测 |
| `1081977 fix(ghaudit): 卡片/编辑视图:过期状态实时刷新、复制指示竞态、添加态类型残留` | S2 + S3 + M5 + 新测试文件(GitHubAccountCardViewTests) |
| `05b82c3 fix(ghaudit): CRLF 文本整段不切分(Excel/Windows 导出导入必失败)` | S1 + 2 个单测(parse 与 previewRows 两路径) |

改动文件(全部在边界内):`GitHubImportParser.swift`、`GitHubAccountStore.swift`、
`Views/GitHubAccountCardView.swift`、`Views/GitHubEditView.swift`、`Views/GitHubImportView.swift`、
`Tests/…/GitHubImportParserTests.swift`、`GitHubAccountStoreTests.swift`、`GitHubImportViewTests.swift`、
`GitHubAccountCardViewTests.swift`(新增)。未碰 Models 语义、AccountStore、登录相关、真实数据路径。

## 四、测试结果

- 基线:220 通过 / 0 失败(未改动前确认)。
- 修复后:**227 通过 / 0 失败**(+7:解析器 3、存储 2、卡片新文件 1、预览路径 1),
  其中 `testCRLFLines` 为修复前失败、修复后转绿(作为 S1 的回归证据)。
- `swift build` 通过;`git diff --check` 无输出(通过)。

## 五、遇到的问题

- S1(CRLF)是测试驱动发现的真实 bug:补 CRLF 单测时第一次跑红,定位到
  `String.split(separator:)` 按「字素簇 Character」切分、CRLF 为单一簇这一 Swift 语义
  (已用最小脚本复现验证)。修复方案(先归一化再切分)经最小脚本验证,两处切分点共用。
- 密码 trim 等 4 项建议涉及跨文件语义变更/较大改动,按任务边界未做,列于第二节。

门禁: PASSED
结论: OK
