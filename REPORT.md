# ghatips 汇报(2026-08-25)

工作区:`dm-wt-ghatips`(分支 `ws-ghatips`,基于 f6dd144 / b27-ghaudit 合并点)
任务:落地 ghaudit 建议 3 项 —— 密码首尾空白静默 trim(中)、「读取 TOTP 密钥…」误导(低)、
「第 0 行:<错误>」(极低)。

## 方案选型说明(密码 trim 提示)

选型:**去除 + 提示**(与现有 trim 行为一致,仅补用户知情)。落盘保留原值方案改动面大
(store add/update/importBatch 四处语义齐变),且保留原值会引入「校验值 ≠ 保存值」的
新不一致,故弃。

- **导入预览行**:解析器在 trim 前检测密码原始字段,新增 `GitHubImportRow.passwordHadEdgeWhitespace`
  标志(仅密码列,不扩散);预览行据其显示橙色「已去除密码首尾空白」。
- **编辑表单**:密码输入框下方实时提示「密码含首尾空白,保存时会自动去除(如密码本身以
  空格开头/结尾,请确认)」—— 保存流程零改动(trim 行为不变),用户在提交前即知情。
- **误报控制**(关键设计):导入文本 `user1, pass123` 的单个空格是**分隔符约定**(应用
  自带示例格式),不能算密码内容,否则提示会出现在几乎每一行。因此判定规则:
  - 引号包裹的字段(内容按字面,如 `" pass123 "`)→ 首尾空白是密码内容 → 提示;
  - 未加引号 → 仅当**单侧空白 ≥ 2 个字符**才提示(单侧 1 个 = 分隔符约定,不算);
  - 空格分隔格式(token 按空白切分)天然无首尾空白,不提示;纯空白字段由既有
    「密码至少 6 个字符」校验兜底,不提示。
- 用户名 trim 保持现状(用户名规则不允许空白,无提示必要);提示未扩散到凭据字段。

## 实际改动

- `Sources/OpenCodeGo/GitHubImportParser.swift` →
  - `GitHubImportRow` 新增 `passwordHadEdgeWhitespace: Bool = false`(memberwise init 向后兼容);
  - `csvSplit` 返回各字段「是否被引号包裹」;`splitFields` 改为返回
    `(fields, passwordHadEdgeWhitespace)`;
  - 新增纯函数 `passwordHasEdgeWhitespace(_:treatAsLiteral:)`(判定规则见上,可单测);
  - 密码仍按既有行为 trim 入库,无行为变更。
- `Sources/OpenCodeGo/Views/GitHubImportView.swift` →
  - `GitHubImportPreviewRow.passwordHint`(计算属性,文案 `已去除密码首尾空白`);
  - 预览行成功项旁显示橙色提示;新增 `skipText(_:)` 静态函数替代硬编码
    「第 \(lineNumber) 行:」,lineNumber 0 → 「导入错误:<消息>」。
- `Sources/OpenCodeGo/Views/GitHubEditView.swift` →
  - 静态纯函数 `passwordContainsEdgeWhitespace(_:)` + 密码字段下实时提示(橙色 Label)。
- `Sources/OpenCodeGo/Views/GitHubAccountCardView.swift` →
  - keychain 缺凭据时「读取 TOTP 密钥…」→「未找到密钥」。
- 测试:+9(解析器 5、预览/文案 3、编辑表单判定 1,新文件 `GitHubEditViewTests.swift`)。

## 门禁结果

- `swift build`:通过(无警告/错误);
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:**236 通过 / 0 失败**
  (基线 227,+9 新增);
- `git diff --check`:通过。

## 遇到的问题

- **误报风险(设计取舍)**:最初按「字段含任意首尾空白即提示」实现,发现应用自带示例格式
  `user1, 密码123`(分隔符后单个空格)会让提示出现在几乎每个预览行 → 收敛为「引号字段
  按字面 + 未引号字段单侧 ≥ 2 空白」规则,并补配套单测(见方案选型说明)。
- **行级 trim 吃掉最后字段尾随空格**:整行先 `trimmingCharacters(.whitespacesAndNewlines)`,
  `user1,pass123 `(密码为行末最后一个字段)的尾随空格在解析前已被行级 trim 消耗,
  无法与「行尾空白」区分 —— 固有歧义,未提示;编辑表单路径(原始输入无行级 trim)不受影响。
- 超出边界文件零改动;README 未提及此细节,无需更新。

## 证据

- 测试输出:`Executed 236 tests, with 0 failures`。
- 回归保护:既有 227 测试全部保持通过,其中 CRLF/引号/空格分隔等解析测试证明
  `csvSplit` 签名改动无行为回归。

门禁: PASSED
结论: OK
