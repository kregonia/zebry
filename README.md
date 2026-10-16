# Zebry

Zig 0.16 编写的 Niri 截图辅助 CLI。通过 Niri IPC 获取窗口几何，按需通过 AT-SPI2
读取原生 UI 区域，输出包含 `children` 父子节点的 JSON。

当前实现优先控制查询开销：不连接浏览器调试接口，不使用浏览器扩展、截图视觉识别、
后台服务或线程池。普通浏览器默认只保留网页外框；Electron、Tauri/WebKitGTK 等桌面应用的文档节点则
继续通过 AT-SPI 遍历，让应用本身的按钮和输入框能够被识别。浏览器已公开的无障碍节点
可以用 `--include-web` 显式展开。

## 构建

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
普通构建不编译项目 C 源码或 C 头文件。AT-SPI 声明来自 `zig translate-c`，遍历和引用
管理全部用 Zig 实现。

默认构建需要系统 `libatspi`、`libglib-2.0`、`libgobject-2.0`；D-Bus 由 libatspi 间接
使用。Arch Linux/CachyOS 安装 `at-spi2-core glib2`；Debian/Ubuntu 安装
`libatspi2.0-dev libglib2.0-dev`；Fedora 安装 `at-spi2-core-devel glib2-devel`。
仅 Niri 的版本不需要这些可访问性库。

## 一键配置应用无障碍环境

环境配置由独立脚本显式执行，`zig build` 和 `zebry` 查询不会修改用户配置。脚本使用
Python 3，不需要 sudo，不会关闭或重启应用：

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

脚本设置 `ACCESSIBILITY_ENABLED=1`、`GNOME_ACCESSIBILITY=1`、`QT_ACCESSIBILITY=1`、
`QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`，写入用户 `environment.d`；为 Chrome、Chromium、
VS Code 和现有 Electron 参数文件加入 `--force-renderer-accessibility`。它还会更新
Niri 的环境配置（包括标准的分文件 include），加入登录时执行的一次性会话初始化脚本，
并更新用户 systemd/D-Bus 激活环境及 `org.a11y.Status.IsEnabled`。没有新增常驻进程。

现有应用必须**完全退出后重开**，已有终端/启动器也不会自动继承新环境；注销后重新登录
能统一刷新整个会话。生成的启动器可以在当前终端中明确传入环境和 Chromium 参数：

```bash
~/.local/bin/zebry-accessible-run discord
~/.local/bin/zebry-accessible-run code --new-window
```

Electron 没有统一的全局 flags 文件标准。独立打包的应用可能忽略 `electron-flags.conf`，
这时使用上面的启动器或配置应用自己的启动入口；不能保证任何应用都公开完整控件树。
全局开启 Chromium accessibility 也会增加应用本身维护树的开销。

脚本遵循 `HOME` 和 XDG 配置路径，原文件备份与安装状态位于
`$XDG_STATE_HOME/zebry/accessibility/state.json`（默认 `~/.local/state/...`）。重复启用不会
重复追加；关闭时检查安装后的内容，遇到用户后续编辑会报告冲突而不覆盖。`--no-session`
只修改持久文件，适用于离线配置；`--niri-config PATH` 可指定 Niri 根配置。Niri 校验失败时
会撤销本次文件修改。D-Bus 不支持删除激活环境项，关闭后需注销重新登录以清除原先不存在
的变量；已运行应用仍持有自己的环境。

## 使用

需要运行中的 Niri 设置 `NIRI_SOCKET`。

```bash
./zig-out/bin/zebry windows
./zig-out/bin/zebry outputs
./zig-out/bin/zebry workspaces
./zig-out/bin/zebry focused
./zig-out/bin/zebry focused --window-id 3
./zig-out/bin/zebry regions --window-id 3
./zig-out/bin/zebry regions --pid 1686
./zig-out/bin/zebry smart

# 已包含 AT-SPI 的构建也能在单次调用时完全跳过可访问性初始化
./zig-out/bin/zebry focused --no-atspi
./zig-out/bin/zebry smart --no-atspi

# 需要更完整的原生 UI 区域时放宽预算，最高 1000ms
./zig-out/bin/zebry focused --window-id 3 --budget-ms 200

# 可选：展开浏览器的 AT-SPI document web 节点（开销更高）
./zig-out/bin/zebry focused --window-id 3 --include-web --budget-ms 1000

# 限制递归深度，默认 16，最高 32
./zig-out/bin/zebry regions --window-id 3 --depth 12

# 诊断某个应用的窗口和已收集区域数量，不是完整原始树
./zig-out/bin/zebry tree --pid 1686
```

`focused` 和 `regions --window-id` 先匹配目标应用及窗口，再遍历该窗口的区域。
Chrome 页面默认只保留 `document web` 外框；使用 `--include-web` 才会继续遍历其子节点，
但页面本身没有公开的 DOM/AX 节点无法由 Zebry 推导。
同 PID 下的其他窗口只读匹配所需的元数据。`regions --pid` 分别为该 PID 的各窗口
构建区域树，再拼接根节点。`smart` 查询 Niri 窗口列表中对应的应用，不遍历无关应用的树。

## 查询边界

AT-SPI 查询默认共用 **50ms 遍历预算**。每次调用最多访问 1024 个内部节点，单窗口
最多收集 128 个区域，递归深度默认 16。调用超时会随剩余预算动态调整，默认上限 50ms。
Zebry 进程内设置 `ATSPI_NO_CACHE=1`，避免依赖 AT-SPI registry 的批量 Cache.GetItems；
这会消除部分应用/Niri 的 `/org/a11y/atspi/cache` 警告，并改用按节点的直接查询。

预算检查发生在同步调用之间，正在进行的调用可能延后结束；libatspi 初始化、缓存加载、
Niri IPC 和 JSON 输出也有独立开销，因此 `--budget-ms` 不是整个命令的硬截止时间。
达到预算时保留已获得的区域并输出 `regions_truncated: true`；没有有效区域时回退为窗口矩形。
`--include-web` 只展开应用已经公开的 `document web` 无障碍节点，仍然不读取 DOM，
不连接浏览器调试端口。普通浏览器默认不展开网页内容；Electron、Tauri 和 WebKitGTK
桌面应用默认展开。`--no-atspi` 和 `-Datspi=false` 才会完全避开 D-Bus 查询。

Niri IPC 使用换行分隔的 JSON。直接解码到类型，跳过未知字段；融合流程只解析显示器
逻辑几何，不分配模式列表等额外信息。Socket 单次读写超时为 100ms，响应上限为 128KiB。

## JSON

`focused` 输出一个窗口或 `null`；`smart` 输出 `focused_window`、`visible_windows`、
`all_windows`；`regions` 输出区域数组。所有区域节点使用相同递归形状：

```json
{
  "name": "Tabs",
  "role": "page tab list",
  "bounds": {
    "logical": {"x": 0, "y": 0, "width": 800, "height": 40},
    "physical": {"x": 0, "y": 0, "width": 1000, "height": 50},
    "scale": 1.25
  },
  "children": [
    {
      "name": "Terminal",
      "role": "page tab",
      "bounds": {
        "logical": {"x": 8, "y": 0, "width": 300, "height": 34},
        "physical": {"x": 10, "y": 0, "width": 375, "height": 42},
        "scale": 1.25
      },
      "children": []
    }
  ]
}
```

父子关系按**逻辑矩形包含**计算，不是原始可访问性树关系。每个节点选择包含自己的最小
矩形为父节点。完全重合的矩形去重，相交但互不包含的区域保持同级。区域在缩放前裁剪到
窗口范围，过滤隐藏元素的无效坐标和无名全窗布局包裹层。

窗口级字段：

| 字段 | 含义 |
|---|---|
| `atspi_available` | 是否匹配到并成功查询 AT-SPI 窗口 |
| `regions_truncated` | 查询是否因时间、深度或数量限制而未完成 |
| `region_source` | `atspi2` 或 `bounding_box` |
| `bounds_estimated` | 是否因缺少合成器位置而沿用估算原点 |
| `geometry` | 窗口内容矩形，逻辑与物理坐标 |
| `visible_geometry` | 基于已知位置的视口交集 |

无有效内部区域时，`regions` 包含一个 `role: "window"`、`children: []` 的窗口矩形。
`atspi_available: true` 时也可能回退；例如预算耗尽或应用只公开无效组件几何。
如果应用没有注册 AT-SPI root，或调用持续超时，则 `atspi_available` 为 `false`，
`regions_truncated` 会标记查询不完整，最终回退到窗口 Bounding Box。

## 当前限制

- Niri 可能不给出 `tile_pos_in_workspace_view`。`pos_in_scrolling_layout` 只是列号和列内
  序号，无法独立还原滚动偏移。缺少位置时暂用 `(0,0)` 并标记 `bounds_estimated: true`；
  此时全局定位和可见性不可靠。
- 当前融合只使用第一个有逻辑几何的显示器，多显示器归属和物理坐标原点仍需完善。
- `shadow` 是 tile 与窗口尺寸差值，可能包含边框等装饰，不保证全部是透明 CSD 阴影。
- 未实现 layer-shell 几何、动画稳定检测和查询后的窗口二次验证。
- AT-SPI 是可选数据，游戏、部分终端或沙箱应用可能只返回窗口外框。不会自动改变应用的
  无障碍设置。网页内部任意 DOM 元素识别不在目标内；只有浏览器/应用已经通过 AT-SPI2
  公开的语义节点才会输出。使用 `--include-web` 可以请求展开这些已公开节点。

## 维护

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

License: MIT
