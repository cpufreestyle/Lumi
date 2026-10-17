# 技术债：MusicController 歌词翻译重试的 Swift 6 并发问题（已修复）

## 结论

**2026-10-04 已修复并验证。** MusicController.swift 的翻译重试路径已无
Sendable 并发警告，验收标准全部达成。

## 历史现状（保留备查）

修复前 swift build 产生 3 条 Sendable 并发警告，位置：

`Lumi/Sources/Lumi/Modules/Music/Controllers/MusicController.swift:3487-3494`

```
warning: mutation of captured var 'attempts' in concurrently-executing code;
         this is an error in the Swift 6 language mode   [SendableClosureCaptures]
warning: reference to captured var 'attempts' in concurrently-executing code;
         this is an error in the Swift 6 language mode   [SendableClosureCaptures]
warning: capture of 'self' with non-Sendable type 'MusicController' in an isolated closure
```

相关代码是歌词翻译的重试闭包：attempt() 捕获并自增外层局部变量 attempts，
回调中又通过 self.translationGeneration 做「代次过期」校验。

## 影响（修复前）

- **当时不影响正确性**：Package.swift 的 swift-tools-version 为 5.9，
  未启用 Swift 6 语言模式，因此这些是 warning 而非 error，编译与测试均通过。
- **升级即断**：一旦把 swift-tools-version 提到 6.0 或开启 Swift 6 语言模式，
  上述警告会直接变成编译错误，阻塞构建。

## 采用的方案

按原文档第 1 条思路改，做了三处调整（均在 processTranslationWindow 内）：

1. attempts 由被捕获的可变局部变量改为**值传递参数** currentAttempts；
2. 两处调用 self 的闭包改为 [weak self] + guard let self，
   与同文件 rebuildSyncedWithTranslations 既有范式一致；
3. 逐行兜底里的缓存查询上移为 processBatch 体内的 cachedTranslation 闭包
   —— applyResult 是会被闭包调用的 local func，其内部再捕获非 Sendable 的
   self 仍会被判为 isolated closure，必须提到非隔离上下文里定义。

**未采用**「收敛到 actor / @Sendable 值类型」和「给 MusicController 标
@MainActor / 实现 Sendable」：前者改动面远超一段重试逻辑，后者会牵连
整个类的线程模型，风险与收益不成比例。本次只求消灭警告，不重构并发架构。

## 验证结果（2026-10-04）

| 项 | 结果 |
|----|------|
| swift build --sdk MacOSX26.5.sdk | 0 warning / 0 error |
| swift test | 532 passed / 0 failed |
| 代次过期语义 | 校验仍在 applyResult 之前，过期批次仍丢弃译文 |
| attempt 序列 | 1 -> 2 -> 逐行兜底，与修复前一致 |

## 注意（后续修同类问题时）

不要让 applyResult 这类「被闭包调用的 local func」内部出现捕获 self 的闭包——
编译器会把外层 local func 判为 isolated，进而把内部闭包的 self 捕获报成
isolated-closure 警告。缓存查询要放在更外层的非隔离上下文里预先定义。

---

# 追加：MusicPlaybackClock 的 actor 隔离告警（2026-10-04 已修复）

> 更正上表：「0 warning / 0 error」仅指 MusicController 那 3 条 Sendable 告警。
> 当时全仓库仍剩本节这 1 条 actor 隔离告警，故彼时并非真正的 0 warning 构建。

## 现象

`Lumi/Sources/Lumi/Modules/Music/Services/MusicPlaybackClock.swift:50`

```
warning: call to main actor-isolated instance method 'advanceInterpolatedProgress()'
         in a synchronous nonisolated context   [#ActorIsolatedCall]
```

## 根因

`Timer(timeInterval:repeats:block:)` 的 block 是 `@Sendable` 非隔离闭包；
`advanceInterpolatedProgress()` 与 `commitProgress()` 为写 `@Published` UI 状态
显式标了 `@MainActor`。编译器无法证明 block 跑在主线程，于是告警。

注意 `MusicController` 类本身**没有**标 `@MainActor`，所以同仓库其他 Timer 回调
（`FocusController.refreshRemaining`、`PollingCoordinator.tick`、
`IslandWindowController.hideIsland`）调用的都是非隔离方法，不产生告警——
只有这一处调了隔离方法。

## 方案与取舍

用 `MainActor.assumeIsolated` 包裹调用：

```swift
let timer = Timer(timeInterval: Self.playbackClockInterval, repeats: true) { [weak self] _ in
    guard let self else { return }
    MainActor.assumeIsolated {
        self.advanceInterpolatedProgress()
    }
}
RunLoop.main.add(timer, forMode: .common)
```

定时器由 `RunLoop.main` 持有，闭包必然在主线程执行，`assumeIsolated` 只是把这个
事实显式告诉编译器：同步调用、零额外跳转。备选方案均否掉：

- `DispatchQueue.main.async`：补间节拍是 20Hz，每拍多一次 RunLoop 轮转等于白加一拍延迟，
  正好抵消本模块「把歌词滞后从 1.5s 压到 0.05s」的全部收益；
- `Task { @MainActor in }`：每秒多 20 个 Task 分配，纯浪费；
- 去掉 `@MainActor` 标注：回退到「调用方记得派主线程」的口头约定，是负优化。

附带收益：若将来误把定时器挂到非主线程 RunLoop，debug 下立即崩，
而不是静默跨线程写 `@Published` 状态。

## 验证

全量清构建（删掉 `.build` 后重编，排除增量缓存）：0 warning / 0 error；
`swift test` 536 passed / 0 failed。
