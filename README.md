<div align="center">

# Zebry

**Niri 截图辅助 CLI —— 用 Zig 0.16 打造的窗口与 UI 区域查询工具**

通过 Niri IPC 获取窗口几何，按需通过 AT-SPI2 读取原生 UI 区域，
输出带 `children` 父子结构的 JSON。

[![Zig](https://img.shields.io/badge/Zig-0.16-F7A41D?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%2F%20Niri-blue)](https://github.com/YaLTeR/niri)

</div>

---

## 目录

- [设计取向](#-设计取向)
- [快速开始](#-快速开始)
- [一键配置无障碍环境](#-一键配置无障碍环境)
- [命令一览](#-命令一览)
- [查询边界与预算](#-查询边界与预算)
- [JSON 输出格式](#-json-输出格式)
- [当前限制](#-当前限制)
- [性能基准测试](#性能基准测试)
- [项目结构](#项目结构)

---

## 设计取向

当前实现优先**控制查询开销**：

| 不使用 | 而是 |
|---|---|
| 浏览器调试接口 / 扩展 | 只读取应用已通过 AT-SPI2 公开的节点 |
| 截图视觉识别 | 直接走 Niri IPC + 无障碍树 |
| 后台服务 / 线程池 | 单次进程调用，用完即走 |

- 普通浏览器默认只保留网页外框（`document web`）；已公开的无障碍节点可用 `--include-web` 显式展开。
- Electron、Tauri/WebKitGTK 等桌面应用的文档节点默认继续通过 AT-SPI 遍历，让应用自身的按钮、输入框可被识别。

## 快速开始

### 依赖

默认构建需要系统 `libatspi`、`libglib-2.0`、`libgobject-2.0`（D-Bus 由 libatspi 间接使用）：

| 发行版 | 安装命令 |
|---|---|
| Arch Linux / CachyOS | `sudo pacman -S at-spi2-core glib2` |
| Debian / Ubuntu | `sudo apt install libatspi2.0-dev libglib2.0-dev` |
| Fedora | `sudo dnf install at-spi2-core-devel glib2-devel` |

> `-Datspi=false` 构建**不需要**这些可访问性库，只依赖 libc。

### 构建

```bash
# 开发构建，包含原生 UI 区域支持
zig build
zig build test

# 性能构建，去除调试符号
zig build -Doptimize=ReleaseFast

# 最低开销版本：只依赖 libc，仅保留 Niri 窗口几何
zig build -Doptimize=ReleaseFast -Datspi=false
```

`-Datspi=false` 的版本保留相同 CLI 和 JSON 形状，区域自动回退为窗口 Bounding Box。
普通构建不编译项目 C 源码或 C 头文件——AT-SPI 声明来自 `zig translate-c`，遍历和引用管理全部用 Zig 实现。

### 运行

需要运行中的 Niri 已设置 `NIRI_SOCKET`：

```bash
./zig-out/bin/zebry smart
```

## 一键配置无障碍环境

环境配置由独立脚本**显式执行**——`zig build` 和 `zebry` 查询不会修改用户配置。脚本使用 Python 3，不需要 sudo，不会关闭或重启应用：

```bash
# 源码目录中执行，默认等同 enable
python3 scripts/setup-accessibility.py

# 或构建后执行已安装的命令
./zig-out/bin/zebry-setup-accessibility enable

# 预览，不修改文件或会话
./zig-out/bin/zebry-setup-accessibility --dry-run

# 检查配置及当前会话状态
./zig-out/bin/zebry-setup-accessibility status

# 恢复启用前的文件和已记录的会话状态
./zig-out/bin/zebry-setup-accessibility disable
```

<details>
<summary><b>脚本具体做了什么？</b></summary>

- 设置 `ACCESSIBILITY_ENABLED=1`、`GNOME_ACCESSIBILITY=1`、`QT_ACCESSIBILITY=1`、`QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`，写入用户 `environment.d`
- 为 Chrome、Chromium、VS Code 和现有 Electron 参数文件加入 `--force-renderer-accessibility`
- 更新 Niri 的环境配置（包括标准的分文件 include），加入登录时执行的一次性会话初始化脚本
- 更新用户 systemd/D-Bus 激活环境及 `org.a11y.Status.IsEnabled`
- **没有新增常驻进程**

</details>

<details>
<summary><b>注意事项与边界</b></summary>

- 现有应用必须**完全退出后重开**；已有终端/启动器不会自动继承新环境，注销后重新登录能统一刷新整个会话。
- 生成的启动器可在当前终端明确传入环境和 Chromium 参数：
  ```bash
  ~/.local/bin/zebry-accessible-run discord
  ~/.local/bin/zebry-accessible-run code --new-window
  ```
- Electron 没有统一的全局 flags 文件标准。独立打包的应用可能忽略 `electron-flags.conf`，这时使用上面的启动器或配置应用自己的启动入口；不能保证任何应用都公开完整控件树。
- 全局开启 Chromium accessibility 会增加应用本身维护树的开销。
- 脚本遵循 `HOME` 和 XDG 配置路径，原文件备份与安装状态位于 `$XDG_STATE_HOME/zebry/accessibility/state.json`（默认 `~/.local/state/...`）。重复启用不会重复追加；关闭时检查安装后的内容，遇到用户后续编辑会报告冲突而不覆盖。
- `--no-session` 只修改持久文件，适用于离线配置；`--niri-config PATH` 可指定 Niri 根配置。Niri 校验失败时会撤销本次文件修改。
- D-Bus 不支持删除激活环境项，关闭后需注销重新登录以清除原先不存在的变量；已运行应用仍持有自己的环境。

</details>

## 命令一览

| 命令 | 说明 |
|---|---|
| `zebry smart` | 查询 Niri 窗口列表中对应的应用，不遍历无关应用的树 |
| `zebry focused [--window-id N]` | 当前聚焦（或指定）窗口的完整信息 |
| `zebry regions --window-id N` | 指定窗口的 UI 区域树 |
| `zebry regions --pid P` | 该 PID 下各窗口分别构建区域树，再拼接根节点 |
| `zebry tree --pid P` | 诊断某应用的窗口和已收集区域数量（非完整原始树） |
| `zebry windows` / `outputs` / `workspaces` | 直接透传 Niri IPC 数据 |

### 常用标志

| 标志 | 说明 |
|---|---|
| `--no-atspi` | 单次调用完全跳过可访问性初始化（即便构建含 AT-SPI） |
| `--include-web` | 展开浏览器的 AT-SPI `document web` 节点（开销更高） |
| `--budget-ms N` | 放宽遍历预算，最高 1000ms（默认 50ms） |
| `--depth N` | 限制递归深度，默认 16，最高 32 |
| `--window-id N` / `--pid P` | 目标窗口 / 进程 |

### 示例

```bash
./zig-out/bin/zebry focused --window-id 3
./zig-out/bin/zebry regions --pid 1686

# 跳过可访问性初始化
./zig-out/bin/zebry smart --no-atspi

# 需要更完整的原生 UI 区域时放宽预算
./zig-out/bin/zebry focused --window-id 3 --budget-ms 200

# 展开浏览器已公开的无障碍节点
./zig-out/bin/zebry focused --window-id 3 --include-web --budget-ms 1000

# 限制递归深度
./zig-out/bin/zebry regions --window-id 3 --depth 12
```

`focused` 和 `regions --window-id` 先匹配目标应用及窗口，再遍历该窗口的区域。
Chrome 页面默认只保留 `document web` 外框；使用 `--include-web` 才会继续遍历其子节点，
但页面本身没有公开的 DOM/AX 节点无法由 Zebry 推导。同 PID 下的其他窗口只读匹配所需的元数据。

## 查询边界与预算

AT-SPI 查询默认共用 **50ms 遍历预算**：

| 限制项 | 默认值 |
|---|---|
| 遍历预算 | 50ms（`--budget-ms` 可调，上限 1000ms） |
| 单次调用最多访问内部节点 | 1024 |
| 单窗口最多收集区域 | 128 |
| 递归深度 | 16（`--depth` 可调，上限 32） |
| Niri Socket 单次读写超时 | 100ms |
| Niri 响应大小上限 | 128KiB |

- 调用超时随剩余预算动态调整。Zebry 进程内设置 `ATSPI_NO_CACHE=1`，避免依赖 AT-SPI registry 的批量 `Cache.GetItems`——这会消除部分应用/Niri 的 `/org/a11y/atspi/cache` 警告，并改用按节点的直接查询。
- 预算检查发生在同步调用之间，正在进行的调用可能延后结束；libatspi 初始化、缓存加载、Niri IPC 和 JSON 输出也有独立开销，因此 `--budget-ms` **不是整个命令的硬截止时间**。
- 达到预算时保留已获得的区域并输出 `regions_truncated: true`；没有有效区域时回退为窗口矩形。
- `--include-web` 只展开应用已经公开的 `document web` 无障碍节点，仍然不读取 DOM、不连接浏览器调试端口。`--no-atspi` 和 `-Datspi=false` 才会完全避开 D-Bus 查询。
- Niri IPC 使用换行分隔的 JSON：直接解码到类型，跳过未知字段；融合流程只解析显示器逻辑几何，不分配模式列表等额外信息。

## JSON 输出格式

- `focused` 输出一个窗口或 `null`
- `smart` 输出 `focused_window`、`visible_windows`、`all_windows`
- `regions` 输出区域数组

所有区域节点使用相同的递归形状：

```json
{
  "name": "Tabs",
  "role": "page tab list",
  "bounds": {
    "logical":  {"x": 0, "y": 0, "width": 800, "height": 40},
    "physical": {"x": 0, "y": 0, "width": 1000, "height": 50},
    "scale": 1.25
  },
  "children": [
    {
      "name": "Terminal",
      "role": "page tab",
      "bounds": {
        "logical":  {"x": 8, "y": 0, "width": 300, "height": 34},
        "physical": {"x": 10, "y": 0, "width": 375, "height": 42},
        "scale": 1.25
      },
      "children": []
    }
  ]
}
```

<details>
<summary><b>父子关系如何计算？</b></summary>

父子关系按**逻辑矩形包含**计算，不是原始可访问性树关系：

- 每个节点选择包含自己的最小矩形为父节点
- 完全重合的矩形去重；相交但互不包含的区域保持同级
- 区域在缩放前裁剪到窗口范围，过滤隐藏元素的无效坐标和无名全窗布局包裹层

</details>

### 窗口级字段

| 字段 | 含义 |
|---|---|
| `atspi_available` | 是否匹配到并成功查询 AT-SPI 窗口 |
| `regions_truncated` | 查询是否因时间、深度或数量限制而未完成 |
| `region_source` | `atspi2` 或 `bounding_box` |
| `bounds_estimated` | 是否因缺少合成器位置而沿用估算原点 |
| `geometry` | 窗口内容矩形，逻辑与物理坐标 |
| `visible_geometry` | 基于已知位置的视口交集 |

无有效内部区域时，`regions` 包含一个 `role: "window"`、`children: []` 的窗口矩形。
`atspi_available: true` 时也可能回退（例如预算耗尽或应用只公开无效组件几何）。
如果应用没有注册 AT-SPI root，或调用持续超时，则 `atspi_available` 为 `false`，
`regions_truncated` 标记查询不完整，最终回退到窗口 Bounding Box。

## 当前限制

- **窗口位置**：Niri 可能不给出 `tile_pos_in_workspace_view`。`pos_in_scrolling_layout` 只是列号和列内序号，无法独立还原滚动偏移。缺少位置时暂用 `(0,0)` 并标记 `bounds_estimated: true`，此时全局定位和可见性不可靠。
- **多显示器**：当前融合只使用第一个有逻辑几何的显示器，多显示器归属和物理坐标原点仍需完善。
- **阴影**：`shadow` 是 tile 与窗口尺寸差值，可能包含边框等装饰，不保证全部是透明 CSD 阴影。
- **未实现**：layer-shell 几何、动画稳定检测和查询后的窗口二次验证。
- **AT-SPI 是可选数据**：游戏、部分终端或沙箱应用可能只返回窗口外框。不会自动改变应用的无障碍设置。网页内部任意 DOM 元素识别不在目标内；只有浏览器/应用已通过 AT-SPI2 公开的语义节点才会输出（`--include-web` 可请求展开这些已公开节点）。

## 性能基准测试

以下数据基于 `zig build -Doptimize=ReleaseFast` 构建，50 次迭代取统计值。
测试环境：Niri 运行中（4 个活跃窗口），DBus session bus 正常连接，Zig 0.16，Linux。

### 纯 Niri IPC 查询（无 AT-SPI）

| 命令 | 平均 | P50 | P95 | Min | Max |
|---|---|---|---|---|---|
| `windows` | 9.68 ms | 9.69 ms | 11.32 ms | 8.29 ms | 11.97 ms |
| `outputs` | 9.55 ms | 9.63 ms | 10.60 ms | 8.45 ms | 10.96 ms |
| `workspaces` | 9.53 ms | 9.61 ms | 10.81 ms | 8.28 ms | 11.38 ms |

纯 Niri IPC 查询极其稳定，方差 < 1 ms。Unix socket + 直接 JSON 解码把开销压到最低。

### AT-SPI 开销 — `smart` vs `smart --no-atspi`

| 模式 | 平均 | P50 |
|---|---|---|
| `zebry smart` (默认，AT-SPI 开启) | **62.67 ms** | 62.50 ms |
| `zebry smart --no-atspi` | **10.15 ms** | 10.20 ms |

AT-SPI 初始化 + 遍历开销约 **52 ms/次**。在默认预算（50ms）下几乎占满整个调用时间。

### Budget 调参对性能的影响

| Budget | 平均 | P50 | P95 | Min | Max |
|---|---|---|---|---|---|
| 10 ms | 12.42 ms | 12.14 ms | 13.22 ms | 11.68 ms | 13.29 ms |
| 50 ms (default) | 54.55 ms | 53.77 ms | 61.92 ms | 52.02 ms | 62.34 ms |
| 100 ms | 104.17 ms | 107.42 ms | 115.15 ms | 73.77 ms | 115.87 ms |
| 200 ms | 163.20 ms | 211.23 ms | 213.92 ms | 69.30 ms | 215.21 ms |
| 500 ms | 265.13 ms | 173.57 ms | 513.29 ms | 65.06 ms | 515.42 ms |
| 1000 ms | 106.90 ms | 99.95 ms | 156.32 ms | 71.40 ms | 168.14 ms |

**关键发现：**
- 低预算（10-50ms）线性增长，符合预期。
- **200ms+ 时方差骤增**：P95/P99 显著高于平均值，部分调用耗时翻倍。这是因为预算检查发生在同步调用之间——如果 AT-SPI 树中有某个节点响应慢，Zebry 会继续等待直到该调用结束，实际耗时超过预算值。
- **500ms 预算的异常高均值（265ms）**源于几次极端长尾（max 515ms）。这很可能是某个应用的 AT-SPI 节点数较多，即使预算耗尽也在等最后一个正在进行的调用完成。
- 1000ms 预算反而回落到 107ms，说明大多数情况下 100-200ms 已经足够覆盖所有节点，1000ms 只是给"跑不掉"的情况留了余地。

**建议：** 对于截图辅助场景，**50-100ms 是甜点区**。200ms+ 的收益递减明显，且方差不可控。

### 递归深度影响

| Depth | 平均 | P50 |
|---|---|---|
| 4 | 16.03 ms | 15.91 ms |
| 8 | 50.94 ms | 52.94 ms |
| 16 (default) | 54.11 ms | 53.26 ms |
| 32 | 53.59 ms | 53.00 ms |

depth > 8 不产生额外工作。**当前环境中应用的 AT-SPI 树最深约 8 层**，这是好现象——递归深度限制在实际中不会成为瓶颈。

### 输出大小对比

| 查询 | 大小 | 备注 |
|---|---|---|
| `windows` (raw) | 1,021 B | 窗口列表元数据 |
| `outputs` (raw) | 2,560 B | 显示器几何信息 |
| `workspaces` (raw) | 530 B | 最小输出 |
| `smart --no-atspi` | 10,102 B | 窗口 + 几何 + bounding box |
| `smart` (50ms) | 10,075 B | TRUNCATED — 预算耗尽 |
| `smart` (1000ms) | **85,394 B** | **TRUNCATED — 10× 放大！** |
| `smart --include-web` | 10,075 B | TRUNCATED |
| `focused --no-atspi` | 958 B | 单窗口裁剪版 |
| `regions --pid` | 474 B | 仅区域数组 |
| `tree --pid` | 270 B | AT-SPI 摘要统计 |

50ms budget 只拿到 ~10KB（大部分 UI 区域因预算被截断），1000ms 预算输出膨胀到 85KB。

### 内存与启动开销

| 指标 | 值 |
|---|---|
| Avg RSS | **421 KB** |
| Max RSS | **664 KB** |
| 进程 spawn（20 次采样） | 10.43 ms |
| 批量 10× `smart` | 63.5 ms/call |
| 批量 10× `smart --no-atspi` | 11.7 ms/call |

对于同时连接 D-Bus、AT-SPI、Niri IPC 并构建完整窗口+区域树的工具，**< 700 KB 的峰值 RSS 极其优秀**。

### 瓶颈分析

```
Total ~62ms (default smart query)
├── Process spawn + setup     ~10ms  ██████████░░░░░░░░░░░░░░░░░░░░
├── Niri IPC                  ~10ms  ██████████░░░░░░░░░░░░░░░░░░░░
├── AT-SPI init + bus connect ~10ms  ██████████░░░░░░░░░░░░░░░░░░░░
└── AT-SPI tree traversal     ~32ms  ████████████████████░░░░░░░░░░
```

在"无后台服务、无线程池、无缓存"的设计约束下，这个性能已很好。主要瓶颈是 AT-SPI 树遍历（52ms），但这是实现原生 UI 区域识别的必要代价。

## 项目结构

```text
src/main.zig            CLI 和参数解析
src/niri/client.zig     Unix Socket 与直接 JSON 解码
src/niri/types.zig      Niri 数据类型与矩形运算
src/atspi/api.zig       系统库 ABI 声明
src/atspi/bindings.zig  有预算的原生 UI 查询
src/merge.zig           窗口匹配、裁剪、几何去重和父子树
src/output.zig          流式 JSON 输出
src/root.zig            公共入口和测试
scripts/setup-accessibility.py  显式启用/撤销用户无障碍配置
```

普通构建使用仓库内的 ABI 声明，不需要 Python。更新系统 ABI 后可运行：

```bash
python3 scripts/generate-atspi-api.py
zig build test
```

---

<div align="center">

**License: [MIT](LICENSE)**

</div>
