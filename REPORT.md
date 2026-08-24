# injectretry 汇报(2026-08-25)

## 任务
审计 b23 发现 #8:`injectOneShot`(授权点击 / 2FA 填码 / 读 cookie)在 didFinish 后 300ms
执行一次;页面渲染慢(SPA)时注入落空且无后续 didFinish → 停留至 300s 全局超时。
修复:未命中/失败 → 受控重试(最多再试 2 次,共 3 次,300ms × n 级进小退避)。

## 实际改动

### `Sources/OpenCodeGo/Views/GitHubLoginView.swift`
- `injectOneShot(js:)` → `injectOneShot(js:attempt:)`:首次仍 300ms 注入;JS 结果回调解读,
  未命中 → 按退避序列(300/600/900)重试,最多 3 次,耗尽静默放弃(无新增状态,无终止语义变化)。
- 新增 `handleOneShotInjectResult(_:js:attempt:session:)`:重试决策 + 过期守卫
  (`!succeeded` 且会话代次匹配);命中返回不再重试,结果不推进状态机(与现状一致)。
- 新增 `injectSession` 会话代次:每次启动一次性注入 / `cancelPendingInjection` 自增;
  旧页面上下文迟到的 JS 结果无法再触发重试或取消新决策的注入任务 → 确认 injectionTask
  单任务无叠(重试退避窗口内新决策到达 → 由注入任务 cancel 中止;结果已在途 → 代次丢弃)。
- 新增纯函数(可测,共享判定一致):
  - `injectOneShotMaxAttempts = 3`(首次 + 最多 2 次重试);
  - `injectOneShotDelaysMs(maxAttempts:) -> [UInt64]`:各次尝试前等待序列 300/600/900;
  - `injectOneShotShouldRetry(_:) -> Bool`:no-authorize-btn / no-otp / no-form /
    JS 执行出错(nil/异常) → 重试;readCookiesJS JSON 串 `{auth:null,clicked:false}`
    (登录入口未就绪)→ 重试,`auth` 有值或已点击 → 不重试;authorized / submitted /
    otp-filled 等命中返回 → 不重试。

### `Tests/OpenCodeGoTests/GitHubLoginViewTests.swift`(新增,8 条)
退避序列(3 次级进 / 单次向后兼容 / 非正数空序列 / 总次数契约)、未命中判定
(no-* 协议 / JS 错误保守重试 / 命中不重试 / readCookies JSON 五种形态)。

## 重试/退避机制说明
- 时序:didFinish → decide → 注入 attempt 0(300ms)→ JS 回调解读 → 未命中 → attempt 1(600ms)
  → 未命中 → attempt 2(900ms)→ 仍未命中 → 静默放弃(维持原决定)。
- 取消/防叠:每一次尝试都重建注入 Task 并赋值 `injectionTask`(单任务不并存);
  新决策到达 → `cancelPendingInjection()` 取消在途 Task 并自增代次;执行前校验
  `!Task.isCancelled && !succeeded && webView 未替换`;结果回调经代次判别过期,丢弃旧结果。
- 幂等重复 didFinish(同 URL 同决策 dedupe 提前 return,不触发 cancel)→ 重试不被误取消。
- 语义不变:命中后的动作(点击/填码/读 cookie)与流程推进完全沿用原路径;3 次未命中
  后的行为与单次注入时代逐字一致(不推进状态、不转手动、不新增终态)。

## 门禁结果
- `swift build`:通过(Build complete)
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:
  **217 通过 / 0 失败**(原 209 全部保持 + 新增 8)
- `git diff --check`:通过(无空白错误)

## 遇到的问题
- 无阻塞问题。说明两点:
  1. SourceKit 对 `evaluateJavaScript` 同步 API 的 "Consider using asynchronous
     alternative" 警告(新增行 359 与既有 injectCredentials/injectOTPProbe 行同型)——
     与既有代码风格一致,不处理。
  2. 重试退避窗口内若步骤推进(新决策),由 injectionTask.cancel 中止在途重试;
     已在 JS 结果回调在途的旧结果由 injectSession 代次丢弃——两重保险,无叠。

## 证据
- 测试输出摘要:``Test Suite 'OpenCodeGoPackageTests.xctest' passed … Executed 217 tests,
  with 0 failures``
- 提交:`d8cab17 feat(injectretry): 一次性注入未命中受控重试(最多 3 次,300ms×n 级进退避)`
  `2e2dea8 test(injectretry): 一次性注入重试纯函数单测(退避序列/未命中判定 8 条)`
- 视图级 WKWebView 行为不可自动化(与 b22/b23 一致),执行路径靠既有手动验证覆盖。

门禁: PASSED
结论: OK
