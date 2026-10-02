# 技术债：MusicController 歌词翻译重试的 Swift 6 并发问题

## 现状

`swift build` 产生 3 条 Sendable 并发警告，位置：

`Lumi/Sources/Lumi/Modules/Music/Controllers/MusicController.swift:3487-3494`

```
warning: mutation of captured var 'attempts' in concurrently-executing code;
         this is an error in the Swift 6 language mode   [SendableClosureCaptures]
warning: reference to captured var 'attempts' in concurrently-executing code;
         this is an error in the Swift 6 language mode   [SendableClosureCaptures]
warning: capture of 'self' with non-Sendable type 'MusicController' in an isolated closure
```

相关代码是歌词翻译的重试闭包：`attempt()` 捕获并自增外层局部变量 `attempts`，
回调中又通过 `self.translationGeneration` 做「代次过期」校验。

## 影响

- **当前不影响正确性**：`Package.swift` 的 `swift-tools-version` 为 5.9，
  未启用 Swift 6 语言模式，因此这些是 **warning 而非 error**，编译与测试均通过
  （实测 `swift build` 成功、`swift test` 532 passed / 0 failed）。
- **升级即断**：一旦把 `swift-tools-version` 提到 6.0 或开启 Swift 6 语言模式，
  上述警告会直接变成**编译错误**，阻塞构建。

## 修复建议（待办，勿草率改并发逻辑）

这段是「网络重试 + 代次防错配」的时序敏感代码，改动不当容易引入
「译文与播放上下文错配」的偶发 bug，因此本次仅记录、不修改。后续处理思路：

1. 把 `attempts` 改为**值传递参数**（每次重试用不可变的局部变量），
   避免在并发闭包中修改被捕获的变量；
2. 或把重试状态收敛到一个 `actor` / `@Sendable` 的值类型中管理；
3. `self`（`MusicController`）跨线程捕获：视是否必要改为捕获具体的值
   （如把 `translationGeneration` 的值在进入后台前取出，而非闭包内读 `self`），
   或让 `MusicController` 标注 `@MainActor` / 实现 `Sendable`。

## 验收标准

修复后应满足：

- `swift build --sdk MacOSX26.5.sdk` 无 Sendable 并发警告；
- `swift test` 仍 532 passed / 0 failed；
- 歌词翻译的「代次过期」语义不变：过期批次的译文不得写入，
  否则会出现原文/译文错配（原注释已强调此点）。
