# 按布局需求解析 metadata accessor

- **状态**: Implemented
- **批准**: 维护者于 2026-10-03 批准修复 PrivateHeaderKit #153 中已确认的问题；本提案记录该已批准的范围，不增加新的 API 或交付范围。
- **关联 Issue**: [PrivateHeaderKit #153](https://github.com/lynnswap/PrivateHeaderKit/issues/153)、[#155](https://github.com/lynnswap/PrivateHeaderKit/issues/155)
- **实现 PR**: [MachOSwiftSection #5](https://github.com/lynnswap/MachOSwiftSection/pull/5)

## 问题与契约

普通 Swift 声明使用已解析的字段名称、类型和 flags。没有请求布局注释时，
`FieldLayoutRenderer` 不应执行类型的 runtime metadata accessor。
共享缓存中的映像可能只被映射，而尚未由 dyld 加载；仅有 `MachOImage` 值不能
证明执行该映像代码所需的初始化已经完成。此前 constructor 对非泛型类型急切调用
accessor，使默认 interface 输出在 Swift runtime metadata completion 中发生空地址崩溃。

## 已批准的决定

自动解析父类型 metadata 只服务真正消费它的布局操作：struct/class 的
`printFieldOffset` 与 enum 的 `printEnumLayout`。`printTypeLayout` 使用字段类型查询，
expanded offsets 依赖已取得的 field offsets，vtable/spare-bit 输出不需要额外调用父类型 accessor。
调用者提供的 metadata 始终保留；现有 `autoResolveAccessorMetadata: false` 与泛型行为保持。

不改变 public API、声明模型、静态布局 provider 或目标选择。普通字段与 enum case
仍照常打印。明确请求 runtime 布局的调用者仍需提供可执行 accessor 的进程内映像；
本修复不把缓存映射当作 dyld 加载保证，也不自动加载目标。

## 验证与交付

`FieldLayoutAccessorResolutionTests` 用 struct/class/enum 的真实计数 accessor 验证：
默认与无关选项不执行 accessor，请求 offset/enum layout 时执行一次，并保留 supplied metadata/opt-out。
Swift 6.3.3 的 Debug 与 Release 各 4 tests、12 个参数化 case 通过；恢复旧 constructor 时默认的三种类型均失败。
108 个相关测试包含 runtime/static renderer、generic specialization 和现有 interface snapshots，输出保持。
既有 CI Debug/Release matrix 执行新回归 suite。PrivateHeaderKit 的依赖采用和标准 CLI 实机验证由 #156 跟踪。
