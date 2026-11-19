# OrCAD 17.2 TriExport · 1.0.0-rc10（中文界面）

本插件在 Capture 顶部 Help 右侧添加 **三文件导出 > 导出文件…** 菜单。选择根目录和 PDF 原理图页后，选择 **Allegro 或 PADS** 网表格式，一次输出 **所选网表、合并 PDF、BOM CSV**。

rc10 将菜单、主界面、BOM 筛选、纸张选项和提示改为中文，沿用已保存的导出格式和筛选规则。**BOM 器件筛选…** 支持位号、颜色、常用属性和自定义属性筛选。**网表格式** 继续支持 Allegro/PADS 并记住选择。一次只输出一种网表。结果目录仍恰好三个文件：Allegro 所需的三个 DAT 封装成一个 ZIP，PADS 则输出一个 ASC。
## 安装与更新

1. 阅读 [环境要求](ENVIRONMENT.md)，确认 Windows x64、Capture / Capture CIS 17.2、可用许可、PostScript 打印驱动和 Ghostscript。
2. 从 [GitHub Releases](https://github.com/yangzhaoxu411/orcad-triexport-17.2/releases) 下载 `OrCAD-TriExport-17.2-1.0.0-rc10.zip` 并完整解压。Source code 压缩包不含编译程序。
3. 保存工作并关闭 Capture，双击 `install.cmd`。不要只复制 EXE；安装器会校验整个 payload。
4. 重新打开 Capture，使用 **三文件导出 > 导出文件…**。标题应为 **1.0.0-rc10**，并出现 **BOM 器件筛选…** 按钮。

未找到 Cadence 路径时运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CadenceRoot "C:\Cadence\SPB_17.2"
```

按实际安装位置修改路径。仅目录受保护时，以同一账户管理员权限运行安装器。脚本不会自动提权、关闭 Capture 或修改原理图。

安装位置：

- 插件：`%LOCALAPPDATA%\OrCADTriExport\17.2`
- 加载入口：`<Cadence根目录>\tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl`
- 设置与日志：`%LOCALAPPDATA%\OrCADTriExport\data-17.2`

已有安装可用 `-UpdateForNextLaunch` 在 Capture 运行时更新磁盘文件，但仍必须保存工作后重启 Capture。更新后需要重启才能加载中文菜单和界面，请确认标题为 rc10。

## 导出

1. 打开并保存目标 DSN。未保存的修改会阻止导出，插件不会代替用户保存。
2. 在 **导出根目录** 中选择已存在的目录。
3. 在 **网表格式** 选择 **Allegro (ZIP)** 或 **PADS PowerPCB V3 (ASC)**，选择会立即保存。升级自旧版且尚未保存格式时默认 Allegro。
4. 在 **PDF 页面** 中勾选所需页面，支持不连续多选、全选、全不选 和 刷新。页面按列表顺序排列。
5. **Ghostscript** 选择 `gswin64c.exe`，默认 PDF 驱动为 `OrCADPS_17.2`。
6. 如需筛选 BOM，打开 **BOM 器件筛选…** 设置并保存规则。关闭规则编辑器后再导出。
7. 保留原图纸张尺寸或选择 A4/A3 横向，点击 **开始导出**。导出期间下拉框锁定，任务使用点击时的格式。

成功后新建一个结果目录：

```text
项目名_YYYYMMDD_HHMMSS/
    项目名_allegro.zip  # 选择 PADS 时为 项目名.asc，两者只生成一个
    项目名.pdf
    项目名.csv
```

目录里恰好有三个文件。历史结果不覆盖，中间打印数据和诊断日志留在单独的作业目录；失败不提交半套结果。PDF 页面勾选只影响 PDF，网表覆盖完整根设计，BOM 默认全量，也可单独筛选。

## BOM 筛选规则

1. 点击 **BOM 器件筛选…**。默认关闭筛选，升级旧设置也保持全量 BOM。
2. 操作选 **排除**（排除）或 **纳入**（纳入）。字段可选 位号、值、PCB 封装、器件料号、制造商、描述、不装属性（DNP / DNI）、器件颜色、自定义属性。
3. 自定义属性须填写 **自定义属性名称**，例如 `Assembly Status`；属性名按 Capture 不区分大小写的有效属性接口读取。属性和值可输入中文。
4. 条件支持等于、不等于、包含、不包含、通配匹配、为空、非空。通配匹配中 `*` 匹配任意长度，`?` 匹配一个字符，`[AB]` 匹配 A 或 B；没有正则表达式或脚本执行功能。所有文本比较忽略大小写和首尾空格。
5. 点击 **添加规则** 添加规则；选中现有规则后可 **更新选中规则** 或 **删除选中规则**。**清空输入** 只清空编辑输入，不删除列表。
6. **保存筛选规则** 保存列表，下次自动恢复；**取消** 丢弃本次修改。尚未点击 添加规则 / 更新选中规则 的输入不会加入列表。最多 100 条规则。

颜色规则：在 **参考器件位号** 输入同颜色器件的位号（例如 `R1`），点 **读取颜色**，自动填入 器件颜色 / 等于 / 颜色编号，选排除 后点 添加规则。此时只读取已保存设计，不修改颜色。支持 等于 / 不等于；匹配的是 Capture 保存的器件颜色，不是屏幕 RGB、选中高亮、引脚或文字颜色。参考器件不同单元颜色不一致时要求换一个参考位号；同名的自定义 `Color` 属性必须使用 自定义属性。

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

看不到 BOM 器件筛选 按钮：保存并重启 Capture，确认标题为 rc10。确认安装到 17.2，不是其他主版本。

打印失败：检查驱动、Ghostscript 可执行文件和日志。本版保留打印前 DSN 选择、实际页回调核对及非空 PostScript 检查。打印日志与 Tcl 调用栈分别在 `pdf-print.log`、`capture-error.log`。

网表失败：检查 `diagnostic.log` 中 Cadence 原生错误；Allegro 分支日志也记录每个原生 DAT 的 SHA-256，ZIP 校验时与之核对。日志可能包含工程内容，不要直接上传公开仓库。

退出 Capture 后运行 `uninstall.cmd`。只删除本插件拥有的程序目录和加载入口，保留设置、日志、导出结果和 Ghostscript。

## 验证、构建和许可

已完成的验证与未覆盖范围见 [VALIDATION.md](VALIDATION.md)。构建步骤见 [README.md](README.md)。`src/TriExport.tcl` 负责界面及 Capture 接口，`src/worker.py` 负责原生网表打包、BOM、PDF 和三文件提交。

源码为 MIT 许可；第三方运行库许可随包提供。包内不包含 Cadence 软件、文档、工程库或用户资料。本项目不是 Cadence 官方产品。
