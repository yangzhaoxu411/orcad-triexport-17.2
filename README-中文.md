# OrCAD 17.2 TriExport · 1.0.0-rc6（英文界面）

本插件用于 Windows 10/11 x64 上的 OrCAD Capture / Capture CIS **17.2**。安装后，通过 Capture 顶部 Help 右侧的 **TriExport > Export Files...** 菜单，选择导出根目录、勾选 PDF 原理图页面，生成 PADS 网表、一个合并 PDF 和 BOM。

安装前请阅读 [环境要求](ENVIRONMENT.md)。从 [GitHub Releases](https://github.com/yangzhaoxu411/orcad-triexport-17.2/releases) 下载完整安装 ZIP；自动生成的 Source code 压缩包不含编译运行库。

rc6 修复 `TypeError in method 'DboBaseObjectToDboLib'`：本机 Capture 17.2 的 `GetSelectedPMItems` 返回工程树路径字符串（例如 `.\design.dsn`），不是 Dbo 对象指针。此前 rc5 对该返回值做了错误的对象转换；现改为路径归一化、大小写无关的设计路径核对，并再次确认活动设计。仍在每次打印前通过 `SelectPMItem` 选择当前 DSN，避免编辑器或工程树残留选中项影响打印。

保留 rc4 的网表副本修复：先创建并校验独立的临时 DSN 副本，仅将副本传给 `pstswp.exe`。工具可在副本中保存打包信息，原工程继续接受版本校验；用户在导出期间保存了真正的新版本时，仍会停止提交。界面继续使用英文。

包含 rc3 的 PDF 初始化与回调修复，打印结束或失败时恢复原生回调、选项与临时状态。

**这是候选版本。** 2026-11-17 已在真实 Capture 17.2 会话验证完整 31 页导出和两张不连续页面导出。两次均得到且仅得到 `.asc`、`.pdf`、`.csv` 三个文件；网表含 963 个物理元件、627 个网络，BOM 位号与网表一致。已渲染检查两张所选页面，并确认它们与完整 PDF 对应页面逐像素一致、原始 DSN 哈希未变化。详细记录见 [VALIDATION.md](VALIDATION.md)。尚未完成 PADS 应用内导入验收；非法封装名等工程数据问题仍会明确报错。安装或更新后需保存工作并重启 Capture 才会加载新版本。

## 安装

1. 将 ZIP 完整解压到任意目录，不要只复制其中的 EXE。
2. 保存工作并关闭 Capture。双击 `install.cmd`。脚本自动寻找 **17.2**，校验文件版本和程序包哈希，不安装到 25.1。
3. 安装完成后重新打开 Capture 17.2。顶部菜单中应在 **Help 右侧**出现 **TriExport**，点击其中 **Export Files...** 打开面板。窗口标题应包含 **1.0.0-rc6**。它是顶层菜单入口，不是另起一排工具栏图标。

找不到安装位置时，在解压目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -CadenceRoot "D:\cadence17.2\Cadence\SPB_17.2"
```

若 Cadence 安装目录受保护，安装器会报告权限错误；使用同一 Windows 账户以管理员身份运行 `install.cmd`。脚本不会自动提权、关闭进程或改动原理图。

安装位置：

- 插件程序：`%LOCALAPPDATA%\OrCADTriExport\17.2`。
- 自动加载文件：`<17.2安装根目录>\tools\capture\tclscripts\capAutoLoad\zzTriExport.tcl`。
- 设置和诊断记录：`%LOCALAPPDATA%\OrCADTriExport\data-17.2`。

更新会检查插件所有权标记；遇到不属于本插件的同名文件会停止，不覆盖其他扩展。设置与程序分开存放。

已有安装可使用 `install.ps1 -UpdateForNextLaunch` 在不关闭 Capture 的情况下替换磁盘文件；导出进程正在运行时仍会拒绝更新。此选项不会重新加载当前会话中的代码，必须先保存工作并自行重启 Capture，才能使用新版本。

## 运行依赖

- 可用的 OrCAD Capture 17.2 许可，安装内包含 `pstswp.exe` 和 `allegro.cfg`。
- 可用的 PostScript 打印驱动，默认名称 **OrCADPS_17.2**。由 Cadence 提供；本包不安装打印驱动。
- 单独安装的 **Ghostscript**。插件自动寻找常见安装目录，也可以手动选择 `bin\gswin64c.exe` 或 `bin\gswin32c.exe`。不能选择 `gs10080w64.exe` 等安装程序。下载入口：[Ghostscript 官方下载页](https://ghostscript.com/releases/gsdnld.html)。
- **使用插件不需要安装 Python**。包内的 `payload\bin` 包含导出程序及其运行库，必须一起保留。

## 导出

1. 打开目标工程，选中目标设计，并先保存 DSN。插件遇到未保存修改会停止，不代替用户保存。
2. 打开 **TriExport > Export Files...**，在 **Output root folder** 中选择存在的导出根目录。
3. 勾选需要合并到 PDF 的页，支持任意非连续多选；**Select all**（全选）、**Clear all**（全不选）、**Refresh**（刷新）用于批量操作。PDF 按所选页面在列表中的顺序排列，不按鼠标点击先后排列；原生打印顺序由回调核对。
4. 首次使用时确认 Ghostscript 路径和 PDF 驱动。可保持原图纸张尺寸，或统一为 A4/A3 横向。点击导出时插件会选中工程管理器中的 DSN；PDF 仍按插件内勾选的页面生成。
5. 点击 **Export Files**。等待成功提示，其中会显示结果目录。

例如选定 `D:\交付`，成功后得到：

```text
D:\交付\项目名_20261117_153000\
    项目名.asc
    项目名.pdf
    项目名.csv
```

**每次新增一个结果文件夹，里面且仅里面有三个文件。** 不覆盖之前的结果，不删除导出根目录中原有内容。中间 PST、PostScript、日志不会混入结果文件夹；失败时不提交半套交付文件。同秒多次导出会自动增加序号。

页面勾选仅控制 PDF；网表和 BOM 对应完整根设计。PDF 包含页面书签，不生成额外属性 PDF，也不保留原生器件属性悬浮链接。网表和 BOM 以保存时的设计版本为准，导出期间保存了新版本会停止提交。

## 格式与当前边界

- 网表采用 PADS PowerPCB V3 单文件 ASCII `.asc`，包含器件位号、PCB Footprint 和展平连接。利用 Cadence 原生生成器产生的 PST 做转换；支持标准隐式电源引脚。不会输出 Allegro 的三个 `.dat` 给用户。
- 本版要求有合法 PCB Footprint、唯一物理位号、PADS 兼容名称。位号最多 16 字符，网络名最多 47 字符；中文、空白或不支持的符号会报错，不会静默截断或改名。BGA 字母数字引脚可保留。
- POWER_GROUP 重映射、无法确定的隐式电源连接等情况会停止，不能把不明确的电源网络当作正确结果。网表只承载连接与封装，不转移布局、差分约束、线宽规则或铜皮设置。
- BOM 是 **带 UTF-8 BOM 的 CSV**，可由 Excel 打开。列为 Item、Reference、Quantity、Value、PCB Footprint、Part Number、Manufacturer、Description 和 DNP / Assembly note。同位号多单元只计一次；不同位号按这些物料属性分组。
- 缺少非必填物料属性时留空。常见料号别名包括 `Part Number`、`PartNumber`、`MPN`、`Manufacturer Part Number`；优先读取第一个非空字段。DNP/DNI 作为备注保留，**不自动删除不装件**。
- 本版面向完整基础设计，**不支持按 CIS 装配变体自动裁剪 BOM/网表**。请勿将“活动变体”的显示状态理解为已按变体导出。
- PDF 按“原理图实例页”打印，同一层次原理图定义只导出一次。不会按每个层次 occurrence 重复输出同一页。若回调、PostScript 和 PDF 页数不一致，会停止，避免生成错页 PDF。
- 当前只枚举活动 DSN 中的原理图视图；外部 DSN 层次、设计中的未使用视图和特殊层次结构需要单独验证。勾选页没有出现在实际打印结果中时会明确报错。

## 故障排查和卸载

缺少菜单或无法打开：确认运行的是 17.2，已重启，自动加载文件位于上述 17.2 目录；Capture Session Log 和 `%LOCALAPPDATA%\OrCADTriExport\data-17.2\startup-error.log` 会保留加载/打开错误详情。若依然看到中文或乱码菜单，说明旧会话尚未重新启动。

导出失败：对话框会给出原因与日志路径。作业文件位于 `data-17.2\jobs\<时间及随机标识>`，可能包含 BOM 属性和 PostScript，请按原理图资料保管；关闭插件后可自行删除不再需要的作业文件夹。诊断记录保留在结果根目录之外，不会自动发送给任何服务。

rc3 的 `pdf-print.log` 记录打印机、打印选项、原生命令返回值、实际页序以及临时文件大小。错误会区分“未调用输出动作”“PostScript 缺失或为空”“没有页面回调”和“驱动输出不是 PostScript”，不再将这些情况统一指向驱动或许可。`capture-error.log` 保留 Tcl 调用栈。若仍失败，请提供该次作业目录中的这两个日志；无需发送原理图或 PostScript。

rc4 的 `diagnostic.log` 记录原 DSN 在网表生成前后的 SHA-256 和副本在打包后的 SHA-256。原文件在运行期间变化时仍停止；副本被 Cadence 更新则是正常情况。若提示 `Invalid PADS ... PCB Footprint for U...`，请核对对应元件的 PCB Footprint 属性和目标 PADS 库中的名称；插件不会猜测封装或静默改名。

rc6 的 `pdf-print.log` 中，`Selected PM paths` 记录选中的工程树路径，`Verified PDF design` 表示路径和活动设计均通过核对。若仍出现 `DboBaseObjectToDboLib` 类型错误，请确认窗口标题已为 `1.0.0-rc6`；旧会话中的 rc5 代码不会因仅替换磁盘文件而自动更新。

关闭 Capture 后，双击解压目录中的 `uninstall.cmd`。卸载只删除带本插件标记的程序目录和加载文件，保留所有已导出文件、设置、诊断记录及 Ghostscript。已完成的实机验证和剩余验证范围见 `VALIDATION.md`。

## 源码与离线构建

`src/TriExport.tcl` 是菜单、界面及 Capture 接口；`src/worker.py` 是 PST → PADS、BOM、PDF 及输出提交逻辑。`src/zzTriExport.tcl` 是轻量自动加载入口。

在独立 Python 3.12 x64 构建环境安装 `requirements-build.txt` 后运行：

```powershell
.\build.ps1 -Python "C:\build-venv\Scripts\python.exe" -Tclsh "D:\cadence17.2\Cadence\SPB_17.2\tcltk\bin\tclsh.exe"
```

Tcl 测试只加载本项目的模拟接口，不加载 Capture DLL、Tk 窗口或设计文件。打包采用显式文件清单，不包含开发临时目录、Cadence 文档/库或用户工程。

源码按 MIT 许可提供，第三方运行库许可随包附带。本项目不是 Cadence 或 Siemens 官方产品。
