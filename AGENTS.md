# 工程前提

- 本工程是一个 RFSoC 的 Vivado 工程。
- 编译本工程时必须使用 Vivado 2025.2。
- 新增或改造的自定义 RTL 与测试必须使用 SystemVerilog（`.sv`）；不改动供应商生成的 Verilog 文件。

# 自定义 RTL 时序规则

- 减少组合逻辑，优先使用寄存器和流水线切分长路径。
- 减少控制信号的数量与扇出，避免一个控制条件驱动大范围数据通路。
- 减少逻辑层数；每一级只完成边界清晰、深度可控的运算。
- 减少 `if`/`else` 的嵌套和分支，优先使用扁平状态、固定格式和静态选择。
- 自定义 RTL 最好不使用 `for`；只有静态展开不会形成深组合链、且确有必要时才使用。

# rdma host cpp
See docs/*.md. Priorities: correctness, maintainability, performance.

C++代码以简洁、直接、可读为优先：

- 优先使用 RAII、std::span、std::string_view、std::optional、std::expected
- 优先使用 range-for、structured binding、if-init
- 避免不必要的临时变量
- 避免 getter/setter 样板代码
- 避免重复的类型名，合理使用 auto
- 避免过度封装和无意义 helper
- 一个函数只做一件事情
- 优先早返回，减少嵌套
- 不为了“通用性”引入不必要的 template
- 不为了异常情况增加复杂抽象
- 能用标准库解决的问题，不自己实现
- 不写注释解释显而易见的代码
- 注释只解释 WHY，不解释 WHAT

Write simple, modern, efficient C++.

Priorities:

1. Correctness
2. Performance
3. Simplicity
4. Readability
5. Maintainability

Prefer direct and predictable code over clever or overly abstract code.

---

## Keep It Simple

* Prefer the simplest correct implementation.
* Avoid unnecessary abstractions, wrappers, and helper classes.
* Do not introduce factories, managers, builders, or interfaces unless they solve a real problem.
* Prefer standard library facilities over custom utilities.
* Avoid premature generalization.
* Do not add code for hypothetical future requirements.

When two implementations are equivalent, prefer the one with:

* fewer allocations
* fewer copies
* fewer indirections
* fewer branches
* fewer abstractions
* less code

Do not sacrifice readability merely to reduce line count.

---

## Modern C++

Prefer appropriate use of:

* RAII
* `auto`
* `const`
* `constexpr`
* `std::array`
* `std::span`
* `std::string_view`
* `std::optional`
* `std::variant`
* `std::expected`
* range-based `for`
* structured bindings
* concepts

Prefer value semantics and explicit ownership.

Avoid owning raw pointers.

Use `std::unique_ptr` for exclusive ownership and `std::shared_ptr` only when shared ownership is actually required.

---

## Functions and Control Flow

Keep functions focused and reasonably small.

Prefer early returns and shallow control flow.

Always use braces:

```cpp
if (error) {
    return false;
}
```

Avoid unnecessary temporary variables, but keep variables when they improve readability or debugging.

Use `auto` when the type is obvious or verbose; use explicit types when they communicate useful information.

---

## Performance

Performance matters, especially in hot paths.

Avoid unnecessary:

* allocations
* copies
* synchronization
* virtual dispatch
* system calls
* pointer indirection
* work inside loops

Prefer:

* contiguous data
* cache-friendly layouts
* batching
* zero-copy where appropriate
* predictable control flow

Do not optimize based on speculation. Measure when performance is important.

Do not sacrifice correctness for micro-optimizations.

---

## Concurrency

Keep synchronization simple and explicit.

Use atomics only when necessary.

Do not introduce lock-free algorithms without a concrete reason.

Choose the simplest synchronization primitive that satisfies the required memory-ordering and concurrency semantics.

---

## Existing Code

Understand the existing code and follow its architecture and conventions.

Make the smallest change necessary.

Do not:

* refactor unrelated code
* rename unrelated symbols
* reformat unrelated code
* introduce unnecessary abstractions
* change APIs without a reason

Reuse existing utilities and patterns when appropriate.

---

## Comments

Do not comment obvious code.

Comments should explain **why**, especially for:

* performance constraints
* hardware requirements
* synchronization
* non-obvious invariants
* workarounds

Prefer clear code over comments.

---

## Validation

After making changes:

* compile the affected target
* run relevant tests
* inspect the final diff
* remove unused code, includes, variables, and debug output

Never claim validation was performed if it was not actually run.

---

## Final Rule

Prefer:

> **Simple, direct, efficient, and obviously correct code.**

Avoid code that is clever, over-engineered, or optimized without evidence.
