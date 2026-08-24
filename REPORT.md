# stagetimeout 汇报(2026-08-25)

## 实际改动

- `Sources/OpenCodeGo/GitHubLoginService.swift` → 新增纯函数 `isStartupLoadingStep(_:)`:
  启动加载阶段判定(仅 `.idle` / `.loadingLoginPage` 为启动阶段,其余一律 false,
  含终态)。供视图的阶段超时「达成/触发」判定复用,避免两处判定漂移。
- `Sources/OpenCodeGo/Views/GitHubLoginView.swift`:
  - 新增 `loginStageTimeout = .seconds(15)`、`loginStageTimeoutMessage`
    (「登录页加载超时(15s),请重试或手动打开授权链接」);`loginTimeout` 由
    private 放开为 internal(便于测试锁定 15s < 300s 契约,语义不变);
  - 新增 `stageTimeoutTask` 状态 + `restartStageTimeout()` / `stopStageTimeout()`
    (仿照 restartTimeout/stopTimeout):`start()` 起计时 15s,触发时与全局超时同
    语义——置 `succeeded` 终止标记、停止轮询/双计时器、时间线打点(`stage-timeout:
    15s 未到达登录页`)+ dumpFlowLog(os_log + login.log 双通道)+ wipeStore,
    然后 `currentStep = .failed(loginStageTimeoutMessage)`;
  - 取消点(全部路径无残留):① `handleNavigation` 步骤变化且离开 idle/loadingLoginPage
    (首个关键步骤到达:github 登录页/授权页/2FA/转手动等)→ 达成即取消;
    ② `start()` 幂等复位;③ `succeed()`;④ `cancel()`;⑤ 300s 全局超时触发;
    ⑥ `onDisappear`。任务体内另有双守卫(`!succeeded` + `isStartupLoadingStep`)兜底。
- `Tests/OpenCodeGoTests/GitHubLoginServiceTests.swift` → +2 测试:判定矩阵
  (idle/loadingLoginPage 为启动阶段,githubLoginForm/fillingCredentials/twoFactor/
  waitingOAuthRedirect/needsManualIntervention/done/failed 均非);
  decide 联动(opencode 启动页仍留启动阶段 → 阶段计时继续,覆盖「轮询空转」;
  github 登录页/授权页决策即离开 → 达成取消)。
- `Tests/OpenCodeGoTests/GitHubLoginViewTests.swift` → +1 契约测试:15s 值、
  15s < 300s、失败文案含「登录页加载超时」与「15s」。

## 阶段超时 / 全局超时关系

- 全局 300s 无进展超时按「步骤变化」重启;阶段静默卡住(didFinish 不再到来 /
  轮询持续空转)时步骤不变,全局超时无法启动,这是审计 #9 的盲区。
- 15s 阶段超时只覆盖「启动加载」一段(start()→首个关键步骤);阶段达成即取消,
  后续(表单/2FA/回跳)仍由全局 300s 兜底,二者并行不叠加;任一先触发即终止
  流程并取消对方计时器,终态上无残留。

## 门禁结果

- swift build: 通过(Build complete)
- swift test: 220 通过 / 0 失败(原有 217 + 新增 3)
- git diff --check: 通过

## 遇到的问题

- 视图时序逻辑(真实 WKWebView 启动、15s 定时器触发、sheet 生命周期)无法自动化:
  以纯函数判定 + 常量契约测试覆盖(阶段判定矩阵、decide 联动、15s/文案契约),
  与 b23 既有做法一致(restartTimeout 亦无时序单测)。
- `loginTimeout` 可见性 private→internal:仅为契约测试断言 15s < 300s 所需,
  无任何行为变化;若 boss 希望保持 private,可删该断言(其余不受影响)。

## 证据

- `swift test` 摘要:Executed 220 tests, with 0 failures
- 新增 3 测试单跑均通过:
  `testIsStartupLoadingStepCoversStartupOnly` / `testDecideLeavesStartupStageAtGithubLoginPage`
  / `testLoginStageTimeoutContract`
- 提交(ws-stagetimeout,共 2 个):
  - c42f6ef feat(stagetimeout): 新增启动加载阶段判定 isStartupLoadingStep 及单测
  - 149ecfc feat(stagetimeout): 启动加载阶段 15s 守护超时(审计 #9)

门禁: PASSED
结论: OK
