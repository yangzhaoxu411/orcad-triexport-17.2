# OrCAD 17.2 TriExport · 1.0.0-rc11（中文界面）

本插件在 Capture 顶部 Help 右侧添加 **TriExport > Export Files...** 菜单。选择根目录和 PDF 原理图页后，选择 **Allegro 或 PADS** 网表格式，一次输出 **所选网表、合并 PDF、BOM CSV**。

rc11 重做界面：左侧为导出概览、PDF 页面、BOM 筛选、环境设置四个入口；底部固定显示范围摘要、导出状态及主操作。名称和原生菜单保留英文，窗口内容使用中文，避免 Capture 原生菜单的中文编码问题。选择的格式、纸张与已保存 BOM 规则保持兼容。

## 安装与更新

1. 阅读 [环境要求](ENVIRONMENT.md)，确认 Windows x64、Capture / Capture CIS 17.2、可用许可、PostScript 打印驱动和 Ghostscript。
2. 从 [GitHub Releases](https://github.com/yangzhaoxu411/orcad-triexport-17.2/releases) 下载 `OrCAD-TriExport-17.2-1.0.0-rc11.zip` 并完整解压。Source code 压缩包不含编译程序。
3. 保存工作并关闭 Capture，双击 `install.cmd`。不要只复制 EXE；安装器会校验整个 payload。
4. 重新打开 Capture，使用 **TriExport > Export Files...**。标题应为 **1.0.0-rc11**，并出现左侧四项导航。

未找到 Cadence 路径时运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CadenceRoot "C:\Cadence\SPB_17.2"
```

按实际安装位置修改路径。仅目录受保护时，以同一账户管理员权限运行安装器。脚本不会自动提权、关闭 Capture 或修改原理图。

安装位置：

- 插件：`%LOCALAPPDATA%\OrCADTriExport\17.2`
- 加载入口：`<Cadence根目录>\tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl`
- 设置与日志：`%LOCALAPPDATA%\OrCADTriExport\data-17.2`

已有安装可用 `-UpdateForNextLaunch` 在 Capture 运行时更新磁盘文件，但仍必须保存工作后重启 Capture。更新后需要重启才能加载英文菜单和新版中文界面，请确认标题为 rc11。

## 导出

1. 打开并保存目标 DSN；未保存的修改会阻止导出。
2. 打开 **TriExport > Export Files...**，在 **导出概览** 选择根目录和网表类型。Allegro 输出 ZIP，PADS 输出 ASC，切换后自动记忆。
3. 进入 **PDF 页面**，搜索名称并勾选图纸。“选中列表内页面 / 清空列表内选择”只处理当前搜索结果；清空搜索后显示全部页。刷新同一设计会保留原有选择，新出现的页面不自动加入。
4. 在页面底部选择原图纸尺寸或 A4/A3 横向。
5. 需要筛选器件时进入 **BOM 筛选**；默认导出全部器件。
6. 首次使用时进入 **环境设置**，选择 Ghostscript 的 gswin64c.exe，检查驱动（默认 OrCADPS_17.2），点击 **保存并检查环境**。
7. 核对底部摘要后点击 **一键导出 3 个文件**。缺少目录、PDF 页或规则时会定位到对应页面；运行时锁定设置并显示进度。
8. 成功后点击 **打开结果目录**。失败不会提交半套文件。

成功后新建一个结果目录：

```text
项目名_YYYYMMDD_HHMMSS/
    项目名_allegro.zip  # 选择 PADS 时为 项目名.asc，两者只生成一个
    项目名.pdf
    项目名.csv
```

目录里恰好有三个文件。历史结果不覆盖，中间打印数据和诊断日志留在单独的作业目录；失败不提交半套结果。PDF 页面勾选只影响 PDF，网表覆盖完整根设计，BOM 默认全量，也可单独筛选。

## BOM 筛选规则

1. 进入 **BOM 筛选**，选择 **导出全部器件** 或 **按规则筛选**。切换为全部器件会保留规则，但暂不应用。
2. 点击 **按颜色排除**、**按属性排除** 或 **添加规则**，每次只编辑一条规则。
3. 操作选择 **排除** 或 **纳入**；字段可选位号、值、PCB 封装、器件料号、制造商、描述、DNP/DNI、器件颜色和自定义属性。
4. 自定义属性显示名称输入框，例如 Assembly Status；颜色显示参考器件位号及“读取颜色”；为空/非空无需填写匹配值。
5. 点击 **添加规则** 或 **保存修改**即保存生效。取消只放弃当前弹窗的修改，已保存的其他规则不受影响。
6. 选中列表内规则后可编辑或删除；双击也可编辑。最多 100 条规则。删除最后一条时自动恢复全部器件。

颜色规则：输入同颜色器件位号（例如 R1），点击 **读取颜色**，再保存规则。只读取已保存设计，不修改颜色。颜色条件只提供等于/不等于；读取不会改变已选择的条件。匹配 Capture 保存的器件颜色编号，不包括屏幕 RGB、选中高亮、引脚或文字颜色。参考器件各单元颜色不一致时换一个参考位号；名为 Color 的自定义属性使用“自定义属性”。

文本条件支持等于、不等于、包含、不包含、通配匹配、为空、非空，忽略大小写及首尾空格。通配匹配中 * 表示任意长度，? 表示单个字符，[AB] 表示 A 或 B；不执行正则表达式或脚本。

组合方式：没有纳入规则时先纳入全部器件；有纳入规则时，**纳入规则匹配方式** 可选 满足任一或全部满足。任何排除规则命中都排除。每条规则只要命中该物理器件的任一单元即命中；同位号整体纳入/排除并只计一次，“全部满足”可由不同单元分别满足不同规则。

例子：`排除 / 位号 / 通配匹配 / R*` 排除全部 R 开头位号；`排除 / 自定义属性 / Assembly Status / 等于 / Not fitted` 排除该状态的器件。`DNP / DNI` 使用插件现有 DNP、DNI、Do Not Populate、Do Not Stuff 的首个非空值；需要精确指定其中一个属性时使用 自定义属性。

缺少的自定义属性按空值处理，为空 同时匹配不存在、空字符串或纯空格；不等于 也可能命中空值。实际读取错误会停止导出，不伪装成空值。器件全部被排除时 CSV 只有表头，成功提示显示 BOM 数量 0，仍生成三份文件。

先检查完整设计与网表的 BOM 对应关系，再筛选，因此筛选不能绕过位号缺失、多单元基础属性矛盾或网表错误。成功提示分别显示 BOM 导出数、排除数、完整网表器件数，诊断日志记录排除位号。规则仅影响 BOM，网表和 PDF 保持其独立范围。

## 在 Allegro PCB Editor 导入网表

1. 将 `项目名_allegro.zip` 解压到独立目录。该目录根层必须直接包含：
   - `pstchip.dat`
   - `pstxprt.dat`
   - `pstxnet.dat`
2. 在 Allegro PCB Editor 打开目标板，选择 **File > Import > Logic**。
3. 选择 Capture 对应的 **Design Entry CIS (Capture)** 来源，将 **Import directory** 指向上述目录。
4. 执行导入并检查 Allegro 日志，确保目标封装库中的封装名称及引脚与原理图匹配。

ZIP 是交付容器，不能直接当网表导入。三个 DAT 的文件名不要更改。本插件不会启动 Netrev 创建或修改 PCB，也不会生成布局或封装库。

## 在 PADS 中使用

选择 **PADS PowerPCB V3 (ASC)** 后，网表为单个 `.asc`，文件头为 `!PADS-POWERPCB-V3.0-MILS!`。在支持该网表格式的 PADS 中导入，使用匹配的封装库。

此分支恢复原 PADS 转换和检查：位号最长 16 字符、网络名最长 47 字符，位号/网络不允许仅大小写不同；名称须符合支持的 ASCII 字符集。带空格、中文或 `?` 的封装名会报错，不会静默改名。普通隐藏电源脚按原生属性展开，无法确定的 POWER_GROUP 重映射会报错。Allegro 分支不套用这些 PADS 限制。

## 格式与边界

- 调用 Capture 17.2 原生 `pstswp.exe` 和 `allegro.cfg`，仅把独立临时 DSN 副本交给网表工具。工具可以更新副本中的打包信息，原始 DSN 始终接受哈希校验。
- Allegro 分支将原生 DAT 逐字节存入 ZIP，包括原编码、换行、隐式电源、POWER_GROUP、层次及属性；PADS 分支独立转换成 ASC。
- 插件只做原生文件类型、完整性、物理元件、连接和 BOM 一致性检查。封装仍须在目标 Allegro 库中有效，不会自动改名或猜测。
- BOM 为带 UTF-8 BOM 的 CSV，包含 Item、Reference、Quantity、Value、PCB Footprint、Part Number、Manufacturer、Description、DNP / Assembly note。同位号多单元只计一次，DNP/DNI 默认保留为备注；启用匹配的排除规则后可从 BOM 删除不装件。
- 面向完整基础设计，不自动读取 CIS 活动装配变体；BOM 仅按用户保存的筛选规则裁剪。常规三文件 Capture 流程不等于 Design Entry HDL 的 Constraint Manager 多文件流程，也不代表所有设计约束已迁移。
- PDF 按原理图实例页输出，同一层次定义不按每个 occurrence 重复输出。外部 DSN、特殊层次、未使用视图及其他安装组合仍需单独验证。
- 导出期间若原 DSN 被保存成新版本，会停止提交，避免 PDF、网表和 BOM 版本混用。

## 故障与卸载

看不到新版四项导航：保存并重启 Capture，确认标题为 rc11。确认安装到 17.2，不是其他主版本。

打印失败：检查驱动、Ghostscript 可执行文件和日志。本版保留打印前 DSN 选择、实际页回调核对及非空 PostScript 检查。打印日志与 Tcl 调用栈分别在 `pdf-print.log`、`capture-error.log`。

网表失败：检查 `diagnostic.log` 中 Cadence 原生错误；Allegro 分支日志也记录每个原生 DAT 的 SHA-256，ZIP 校验时与之核对。日志可能包含工程内容，不要直接上传公开仓库。

退出 Capture 后运行 `uninstall.cmd`。只删除本插件拥有的程序目录和加载入口，保留设置、日志、导出结果和 Ghostscript。

## 验证、构建和许可

已完成的验证与未覆盖范围见 [VALIDATION.md](VALIDATION.md)。构建步骤见 [README.md](README.md)。`src/WorkspaceUI.tcl` 负责工作区界面，`src/TriExport.tcl` 负责 Capture 接口，`src/worker.py` 负责原生网表打包、BOM、PDF 和三文件提交。

源码为 MIT 许可；第三方运行库许可随包提供。包内不包含 Cadence 软件、文档、工程库或用户资料。本项目不是 Cadence 官方产品。
