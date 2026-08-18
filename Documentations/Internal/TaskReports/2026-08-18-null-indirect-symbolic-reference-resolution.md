# 2026-08-18 · 空间接符号引用的 witness 分派修复

## 问题

iOS 27 Simulator 的 `FoundationModels.framework` 在 interface 渲染阶段
SIGSEGV。栈从 `MetadataReader.demangle` 的 indirect context symbolic reference
进入 `RelativeIndirectPointerProtocol.resolveIndirect`，最终在
`MachOImage.readWrapperElement` 读取地址 0。Objective-C 提取已完成，但 Swift
interface 无法产出。

这不是 `FoundationModels` 的专有格式，也不是调用方缺少 catch：间接槽实际为
0，而 SIGSEGV 不会成为 Swift error，`MetadataReader` 的 catch 无法接管。

## 调研

- `RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper?>` 的
  `Pointee` 实际是 `SymbolOrElement<ContextDescriptorWrapper?>`，不是 Optional。
  因此 `RelativeIndirectPointerProtocol where Pointee: OptionalProtocol` 不适用。
- `SymbolOrElementPointer` 同时有无约束 `resolve`（协议 conformance witness）和
  `where Element: OptionalProtocol` 条件重载。具体类型直接调用选条件重载；
  associated-type generic 调用只能走无约束 witness。
- Swift 6.3.3 的最小探针确认了该分派差异：direct call 选 constrained overload，
  protocol generic call 选 unconditional witness。
- 无约束 witness 收到 `.address(0)` 后先做地址转换。`MachOImage` 把 0 转为
  `-Int(ptr)` 的 image offset，随后 `ptr + offset` 恰为 null，wrapper read 直接
  fault。
- 上游 0.15.2 / `main` 与 `next` 均无既有修复；Optional 重载来自早期提交且无
  generic-dispatch 回归测试。

## 最终方案

owner 固定为 `MachOSymbolPointers.SymbolOrElementPointer` 的真实无约束
`RelativeIndirectType` witness：

1. context-free、MachO、ReadingContext 三个 `resolve` 都在任何地址转换/读取前
   检查 0。
2. 私有 helper 受检转换 `Element.Type` 到 `any OptionalProtocol.Type`，取 `.none`
   后再受检转回 `Element`；成功返回 `.element(.none)`。
3. non-optional 或转换失败时抛既有 `ReadingError.invalidAddress(0)`。
4. 删除整段 Optional 条件重载，让 direct / generic dispatch 不再有两套 owner。
5. public 泛型类型、symbol 分支、非零地址分支保持不变；三个 constrained public
   declaration 被删除，但相同 call signature 由无约束 witness 继续提供。

明确不做 `MetadataReader` / `FoundationModels` guard，也不改
`RelativeIndirectPointerProtocol` 的通用算法。

## 实际执行

- `Sources/MachOSymbolPointers/SymbolOrElementPointer.swift`：三条 witness 路径
  接入 `resolvedNullElement()`，删除条件重载。
- `Tests/SwiftInspectionTests/NullIndirectSymbolicReferenceTests.swift`：在 CI 已有
  `MetadataReaderDemanglingTests` suite 上以 extension 新增 5 个完全合成、不依赖
  OS framework fixture 的测试；文件保持按回归主题独立，但 suite owner 与
  `.github/workflows/macOS.yml` 的既有 filter 一致：
  - `.address(0)` 经 generic `RelativeIndirectType.resolve()`，固定 optional
    `.element(nil)` 与 non-optional `ReadingError.invalidAddress(0)`。
  - 同一个值经 generic `RelativeIndirectType.resolve(in: MachO)`，固定同一两侧契约。
  - 非零 relative pointer 指向 `UInt64(0)`，经 generic protocol helper 解析为
    `.element(nil)`；probe 只记录槽地址读取，0 地址转换列表为空。
  - 同形状 non-optional element 精确抛 `ReadingError.invalidAddress(0)`，仍无 0
    地址转换。
  - 手工构造 kind `0x02` `MangledName`，用 `MachOImage` 进入
    `MetadataReader`，精确得到 `DemanglingError.requiredNonOptional`，不再 exit
    139。
- `SwiftInspectionTests` 增加测试专用的直接 `MachOKit` product dependency，用于
  创建当前 `MachOImage`；生产 target 依赖图不变。
- 文档同步：设计文档、evolution proposal 0005、演进日志、README 索引与
  AGENTS architecture。

实现与设计契约一致。三个 constrained public overload declaration 被删除，但同一
call signature 由 unconditional witness 提供；源码分发下现有调用兼容，不作二进制
ABI 保证。

## 验证

- `swift test --filter MetadataReaderDemanglingTests`：9 tests / 1 suite，既有
  suite 连同 5 个新增 regression tests 一起通过。
- CI 的原样 filter `swift test --filter '\.MetadataReaderDemanglingTests(/|$)'`
  同样执行 9 tests / 1 suite；workflow 无需修改。
- 初次 `swift test --skip IntegrationTests` 在 fresh worktree 发现唯一共同根因：
  gitignored 的 `SymbolTestsCore.framework` fixture 不存在，853 个 fixture 测试随之
  失败；这不是 product diff。
- 按 AGENTS 先重建 fixture。机器没有项目 team 的 `Mac Development` 证书；首轮
  禁用签名的 build 使两个相对 function offset 比 baseline 整体偏 16。未改
  baseline，改用 `CODE_SIGN_IDENTITY=-` 的 `Sign to Run Locally` ad-hoc 签名
  重建后，相关 2 suites / 8 tests 恢复全绿，确认是 fixture link/signing layout，
  不是本批实现。
- 最终 `swift test --skip IntegrationTests --quiet`：1359 tests / 253 suites，
  全部通过。
- 未运行 `Tests/IntegrationTests`，未重录任何 baseline。
- `git diff --check`：通过。

## 下游 fork cohort 对齐

PrivateHeaderKit 随后的 Objective-C protocol metadata 修复需要直接固定
`lynnswap/MachOObjCSection@7d159a0216565edae417bf40716dd447bf295e7b`。如果本 package
继续从 MxIris URL 引入同一 identity，SwiftPM 会报告 `Conflicting identity for
machoobjcsection`，并明确提示该 warning 将来会成为 error。

因此 remote fallback 改为同一 lynnswap URL 与 exact revision；本地 sibling 优先规则
不变。`swift package show-dependencies` 用于验证 graph 只剩一个
`machoobjcsection` source。没有为此建立 upstream PR；正式 release 可用后，下游应把
两个临时 fork pin 作为同一 cohort 一并撤回。

该 commit 只存在于未 tag 的 PrivateHeaderKit cohort branch，不是 RuntimeViewer 或其他
consumer 的一般升级版本。RuntimeViewer 当前直接固定官方 MachOObjCSection；若将来要采用
本 revision，必须同时改其 direct pin，否则会把相同 identity 的两个 source 再次带回 graph。
本任务不发布 tag、不合入 upstream/main，也不修改 RuntimeViewer。

验证结果：`swift package --force-resolved-versions show-dependencies --format json`
无 duplicate-identity warning，resolved checkout 为精确 SHA `7d159a0`；随后
`swift test --skip IntegrationTests --quiet` 为 1359 tests / 253 suites 全绿。

后续 Issue #60 沿用同一 cohort contract，把 remote fallback 前移到
`ecc84fb790509fb71f4c1f0bd2fb6e4bac6069df`。这是 dependency-only 对齐；本报告上述
`7d159a0` 验证仍是原任务当时的历史记录。follow-up 重新 resolve 后只存在一个
`machoobjcsection` identity，checkout 为 `ecc84fb`；ad-hoc 重建 `SymbolTestsCore` fixture 后，
`swift test --skip IntegrationTests --quiet` 再次通过 1359 tests / 253 suites。

## 文档

- [NullIndirectSymbolicReferenceResolution.md](../NullIndirectSymbolicReferenceResolution.md)
- [0005 - 空间接符号引用的单一 witness 解析契约](../../Evolutions/0005-null-indirect-symbolic-reference-resolution.md)
