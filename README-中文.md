# OrCAD 17.2 TriExport · 1.0.0-rc8（英文界面）

本插件在 Capture 顶部 Help 右侧添加 **TriExport > Export Files...** 菜单。选择根目录和 PDF 原理图页后，选择 **Allegro 或 PADS** 网表格式，一次输出 **所选网表、合并 PDF、BOM CSV**。

rc8 增加 **Netlist format** 下拉框，默认 Allegro，切换后记住选择。一次只输出一种网表。结果目录仍恰好三个文件：Allegro 所需的三个 DAT 封装成一个 ZIP，PADS 则输出一个 ASC。
## 安装与更新

1. 阅读 [环境要求](ENVIRONMENT.md)，确认 Windows x64、Capture / Capture CIS 17.2、可用许可、PostScript 打印驱动和 Ghostscript。
2. 从 [GitHub Releases](https://github.com/yangzhaoxu411/orcad-triexport-17.2/releases) 下载 `OrCAD-TriExport-17.2-1.0.0-rc8.zip` 并完整解压。Source code 压缩包不含编译程序。
3. 保存工作并关闭 Capture，双击 `install.cmd`。不要只复制 EXE；安装器会校验整个 payload。
4. 重新打开 Capture，使用 **TriExport > Export Files...**。标题应为 **1.0.0-rc8**，并出现 **Netlist format** 下拉框。

未找到 Cadence 路径时运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CadenceRoot "C:\Cadence\SPB_17.2"
```

按实际安装位置修改路径。仅目录受保护时，以同一账户管理员权限运行安装器。脚本不会自动提权、关闭 Capture 或修改原理图。

安装位置：

- 插件：`%LOCALAPPDATA%\OrCADTriExport\17.2`
- 加载入口：`<Cadence根目录>\tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl`
- 设置与日志：`%LOCALAPPDATA%\OrCADTriExport\data-17.2`

已有安装可用 `-UpdateForNextLaunch` 在 Capture 运行时更新磁盘文件，但仍必须保存工作后重启 Capture。rc7 面板仍可按其声明的 Allegro 格式导出，但需要重启才显示新下拉框；更早未声明格式的面板会收到重启提示。

## 导出

1. 打开并保存目标 DSN。未保存的修改会阻止导出，插件不会代替用户保存。
2. 在 **Output root folder** 中选择已存在的目录。
3. 在 **Netlist format** 选择 **Allegro (ZIP)** 或 **PADS PowerPCB V3 (ASC)**，选择会立即保存。升级自旧版且尚未保存格式时默认 Allegro。
4. 在 **PDF pages** 中勾选所需页面，支持不连续多选、Select all、Clear all 和 Refresh。页面按列表顺序排列。
5. **Ghostscript** 选择 `gswin64c.exe`，默认 PDF 驱动为 `OrCADPS_17.2`。
6. 保留原图纸张尺寸或选择 A4/A3 横向，点击 **Export Files**。导出期间下拉框锁定，任务使用点击时的格式。

成功后新建一个结果目录：

```text
项目名_YYYYMMDD_HHMMSS/
    项目名_allegro.zip  # 选择 PADS 时为 项目名.asc，两者只生成一个
    项目名.pdf
    项目名.csv
```

目录里恰好有三个文件。历史结果不覆盖，中间打印数据和诊断日志留在单独的作业目录；失败不提交半套结果。PDF 页面勾选只影响 PDF，网表与 BOM 始终覆盖完整根设计。

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
- BOM 为带 UTF-8 BOM 的 CSV，包含 Item、Reference、Quantity、Value、PCB Footprint、Part Number、Manufacturer、Description、DNP / Assembly note。同位号多单元只计一次，DNP/DNI 保留为备注，不自动删除不装件。
- 面向完整基础设计，不按 CIS 活动装配变体裁剪网表/BOM。常规三文件 Capture 流程不等于 Design Entry HDL 的 Constraint Manager 多文件流程，也不代表所有设计约束已迁移。
- PDF 按原理图实例页输出，同一层次定义不按每个 occurrence 重复输出。外部 DSN、特殊层次、未使用视图及其他安装组合仍需单独验证。
- 导出期间若原 DSN 被保存成新版本，会停止提交，避免 PDF、网表和 BOM 版本混用。

## 故障与卸载

看不到 Netlist format 下拉框：保存并重启 Capture，确认标题为 rc8。确认安装到 17.2，不是其他主版本。

打印失败：检查驱动、Ghostscript 可执行文件和日志。本版保留打印前 DSN 选择、实际页回调核对及非空 PostScript 检查。打印日志与 Tcl 调用栈分别在 `pdf-print.log`、`capture-error.log`。

网表失败：检查 `diagnostic.log` 中 Cadence 原生错误；Allegro 分支日志也记录每个原生 DAT 的 SHA-256，ZIP 校验时与之核对。日志可能包含工程内容，不要直接上传公开仓库。

退出 Capture 后运行 `uninstall.cmd`。只删除本插件拥有的程序目录和加载入口，保留设置、日志、导出结果和 Ghostscript。

## 验证、构建和许可

已完成的验证与未覆盖范围见 [VALIDATION.md](VALIDATION.md)。构建步骤见 [README.md](README.md)。`src/TriExport.tcl` 负责界面及 Capture 接口，`src/worker.py` 负责原生网表打包、BOM、PDF 和三文件提交。

源码为 MIT 许可；第三方运行库许可随包提供。包内不包含 Cadence 软件、文档、工程库或用户资料。本项目不是 Cadence 官方产品。
