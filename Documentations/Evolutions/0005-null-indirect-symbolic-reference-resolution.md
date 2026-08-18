# 0005 - 空间接符号引用的单一 witness 解析契约

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-18
- **最后更新**: 2026-08-18
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `codex/fix-null-indirect-symbolic-reference`
- **配套文档**: [NullIndirectSymbolicReferenceResolution.md](../Internal/NullIndirectSymbolicReferenceResolution.md)

## 摘要

`RelativeIndirectSymbolOrElementPointer<ContextDescriptorWrapper?>` 已用
Optional 表达「间接槽可以为空」，但 `SymbolOrElementPointer` 把空值行为写在
`where Element: OptionalProtocol` 的重载里。具体类型直接调用能选中该重载；
`RelativeIndirectPointerProtocol` 经 associated type 调用时却使用无约束的
`RelativeIndirectType` witness，遂把地址 0 送入 reader 并在进程内路径解引用
空指针。本提案把空值语义移入唯一的无约束 witness：Optional element 得到
`.element(.none)`，非 Optional element 抛 `ReadingError.invalidAddress(0)`；删除
条件重载，使直接与泛型分派共享同一 owner。

## 动机与破坏的 invariant

间接 context symbolic reference（mangling kind `0x02`）先按相对位移找到一个
指针槽，再解析槽内地址。槽内 0 是「没有 descriptor」，不是可读虚拟地址。

现有实现破坏了两条本应由 pointer abstraction 保证的 invariant：

1. 任何地址转换、wrapper read 之前必须处理 0。
2. 相同具体类型的直接调用与 protocol-generic 调用必须具有相同语义。

`MetadataReader` 外层已有 `catch`，但 SIGSEGV 不是 Swift error，无法进入该边界。
因此在 `MetadataReader` 或具体 framework 名上加 guard 都是把 ABI 解释责任移到
调用者，不能修复 invariant。

## 决策

### 1. Owner 留在 `SymbolOrElementPointer` 的真实 conformance witness

三个既有无约束 `resolve` 方法（context-free / MachO / ReadingContext）先检查
`.address(0)`，再走原有非零逻辑。公开类型、方法签名、symbol 分支和非零分支
全部不变。

### 2. 复用现有 `OptionalProtocol`，不扩 public API

私有 helper 对 `Element.Type` 做受检 existential cast，读取其 `.none`，再做受检
cast 回 `Element`。成功即返回 `.element(.none)`；Element 不能表达空值或 cast
失败时抛现有 `ReadingError.invalidAddress(0)`。不用 force cast，也不新增第二套
nullability protocol。

### 3. 删除条件重载

保留 `where Element: OptionalProtocol` extension 即使当前实现相同，也会让 source
里继续存在两个语义 owner，并让未来改动再次分叉。故整段删除。

## 被否方案

- **在 `MetadataReader` 的 kind-0x02 分支判 0**：越过 pointer abstraction，其他
  caller 仍可崩；且需要先暴露间接槽实现细节。
- **按 `FoundationModels` 特判**：把一个通用 ABI 状态误写成 framework 例外，下一
  个携带空槽的 binary 会原样复现。
- **只修 `RelativeIndirectPointerProtocol where Pointee: OptionalProtocol`**：本案
  `Pointee` 是 `SymbolOrElement<ContextDescriptorWrapper?>`，并非 Optional，约束不
  成立。
- **新增 public nullable-pointer 类型或协议**：能表达契约，但为修复既有 witness
  引入不必要的 API 与迁移成本。

## 兼容性

- 无 public declaration 变化，源码兼容。
- Optional 空槽从崩溃变为既有模型中的 `.element(nil)`。
- 非 Optional 空槽从非法内存访问变为 `ReadingError.invalidAddress(0)`。
- 非零地址、bind/rebase symbol 与 context-free symbol 行为不变。

## 验证

- 合成非零 relative pointer → `UInt64(0)` 槽，经 generic
  `RelativeIndirectPointerProtocol` 路径断言 `.element(nil)`，并记录 reader 未收到
  address-zero 读取/转换。
- 同形状 non-optional pointer 断言 `ReadingError.invalidAddress(0)`。
- 合成 kind `0x02` 的 `MangledName`，用 `MachOImage` 进入 `MetadataReader`，断言
  `DemanglingError.requiredNonOptional`，不再 exit 139。
- 运行受影响测试、`swift test --skip IntegrationTests` 与 `git diff --check`；不运行
  `Tests/IntegrationTests`。

## 发布

本批不 bump 版本、不写 changelog。后续 release 按正常版本流程收录。
