# C++ 命名规范

> 适用范围：`application/`、`src/`、`inc/device_core/` 以及对应测试中的自研
> C++ 代码。第三方、生成代码和外部协议标识不在机械改名范围内。

## 基本规则

- 类型、类、结构体、concept 和类型别名使用 `PascalCase`。
- 有动作或副作用的函数使用 `PascalCase`，例如 `StartReceive`、
  `AcquireExclusive` 和 `OpenComponent`。
- 局部变量、参数、数据字段和命名空间使用 `snake_case`。
- 非公开数据成员使用尾下划线，例如 `receive_size_bytes_`。
- 常量和枚举值使用 `kPascalCase`，宏保留 `UPPER_SNAKE_CASE`。
- 首字母缩写按普通单词处理：`Dma`、`Far`、`Fft`、`Ddc`、`Pl`、`Axi`。
- 名称表达业务角色，不使用 `data1`、`tmp`、`ptr`、`obj`、`manager` 等脱离
  上下文后无法理解的泛化名称。

以上约定与 [Google C++ Style Guide](https://google.github.io/styleguide/cppguide.html#Naming)
的类型、变量、常量、函数和枚举命名原则一致；仓库现有的动作函数采用
`PascalCase`，优先保持项目内部一致性。

## 访问器例外

无副作用、接近标准库容器语义的访问器或谓词可以使用 `snake_case`，例如
`size()`、`data()`、`empty()`、`ok()`、`valid()` 和配置值访问器。重写第三方或
生成接口时必须保持其原始名称，例如 Thrift 的 `execute` 和 `describe`。

## 语义后缀

- 裸整数表示长度、容量、偏移、速率、频率或时间时必须带单位或计量语义：
  `size_bytes`、`offset_bytes`、`sample_rate_hz`、`center_frequency_mhz`、
  `elapsed_nanoseconds`、`started_at_unix_ms`。
- 标识符应说明对象类别：`component_id`、`control_endpoint_id`、`channel_id`、
  `file_id`，不使用孤立的 `id`。
- 所有权或生命周期不明显时在名称或类型中体现，例如 `FrameLease`、
  `callback_context`、`borrowed`、`owned`。
- 持锁要求必须进入函数名：函数内部加锁使用普通动作名；要求调用方已持锁使用
  `WithLockHeld`；明确不加锁的底层操作使用 `Unlocked`。
- 生命周期动作使用成对名称：`Open/Close`、`Start/Stop`、`Register/Unregister`、
  `Acquire/Release`，避免同一概念混用 `Init`、`Enable`、`Run`。

## 兼容边界

下列名称由外部契约决定，除非同步迁移所有消费者并明确提升协议或 ABI 版本，否则
不得仅为风格统一而修改：

- `third_party/`、`application/generated/` 及 `inc/` 中的第三方库；
- Thrift IDL 字段、方法和生成的 C++ override；
- JSON key、命令行参数和配置文件 key；
- libwebsockets、AXI DMA 等 C API 回调参数和宏；
- FAR/MHAL 线协议结构字段、宏及编码值；
- PL 寄存器表中的硬件名称、位定义和对外字符串；
- `yhjson` 的兼容层接口及标准库式容器访问器。

新代码进入兼容边界时，在适配层立即翻译为本规范下的内部名称，不让外部命名继续
传播到领域模块。

## Review 清单

- [ ] 名称在脱离当前函数后仍能表达角色。
- [ ] 长度、地址、频率和时间包含单位。
- [ ] 锁状态、所有权、可空性和生命周期动作没有隐藏约定。
- [ ] 缩写大小写一致，未产生 `FFTModule`、`DMATransfer` 一类全大写词段。
- [ ] 改名未改变 JSON、Thrift、FAR/MHAL、PL 寄存器或第三方 ABI。
- [ ] 声明、定义、调用、测试和文档已同步，交叉编译及相关测试通过。
