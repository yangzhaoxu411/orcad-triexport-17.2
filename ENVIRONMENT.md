# 环境要求

适用版本：OrCAD TriExport **1.0.0-rc11**。

## 运行安装包

| 依赖 | 要求与检查方法 |
| --- | --- |
| Windows | Windows 10/11 x64。编译的导出程序为 64 位；不支持 Windows 7、32 位 Windows、macOS 或 Linux |
| OrCAD | Capture / Capture CIS **17.2**，具有可用许可。安装器核对 `Capture.exe` 版本；其他主版本不在兼容范围 |
| 原生网表工具 | OrCAD 安装目录内存在 `tools/bin/pstswp.exe` 与 `tools/capture/allegro.cfg`，许可允许生成网表 |
| Tcl/Tk | 使用 Capture 自带运行时及 `capPdfUtil`、`CapPdfPrint` 等原生接口，不需要用户另装 Python 或 Tcl |
| PostScript 驱动 | Capture 可识别的 PostScript 打印机，默认名称 `OrCADPS_17.2`。通过 Cadence 安装程序配置；Microsoft Print to PDF 不能替代 PostScript 驱动 |
| Ghostscript | 单独安装，界面指向 `bin/gswin64c.exe`，不要选安装器 EXE。本次实测 10.08.0；也能选择 `gswin32c.exe`，但未进行该组合的实机验收 |
| PowerShell | Windows PowerShell 5.1 或以上。`install.cmd` / `uninstall.cmd` 调用系统 `powershell.exe` |
| 写入权限 | 当前用户 `%LOCALAPPDATA%`、OrCAD 的 `tools/capture/tclscripts/capAutoLoad`、选定导出目录均可写。仅安装目录受保护时才需要用同一账户管理员权限运行安装器 |
| 存储空间 | 必须容纳临时 DSN、PST、PostScript、PDF 和最终结果。空间随工程变化；本次 31 页工程的 PostScript 约 48 MB，最终 PDF 约 10 MB，不能只按三份最终文件大小预留空间 |

Ghostscript 官方下载：[ghostscript.com/releases/gsdnld.html](https://ghostscript.com/releases/gsdnld.html)。OrCAD、许可、打印驱动及 Ghostscript 均由使用者自行安装，不在本插件包中分发。

导出过程在本机完成，不需要联网，不会上传工程资料。CSV 可由 Excel、LibreOffice 或其他支持 UTF-8 BOM 的工具打开；生成 CSV 不需要安装这些软件。导出不需要启动 Allegro 或 PADS；实际导入需要目标 PCB 软件及匹配的封装库。Allegro 网表 ZIP 必须先解压，PADS ASC 不需要解压。

## 已实测的配置

以下是 2026-11-17 读取并于 2026-11-19 继续验证的配置，不代表所有补丁和系统组合均已验收：

| 项目 | 实际值 |
| --- | --- |
| 系统 | Windows 11 Enterprise x64，版本 10.0.26200 |
| Capture | OrCAD Capture CIS 17.2，EXE 文件版本 `17.2-2016` |
| Tcl | 8.6.0（Cadence 自带） |
| 打印驱动 | `OrCADPS_17.2` |
| Ghostscript | 10.08.0，`gswin64c.exe` |
| 图纸设置 | 原图纸尺寸（旧版 Original sheet size） |
| 验证结果 | rc9 通过原生数据库颜色/属性读取及五组双格式 BOM 筛选导出验证；PDF 复用已验证的打印数据，详情见 VALIDATION.md |

EXE 属性未提供更细的 Capture hotfix 编号，不据此推断具体 hotfix。Windows 10、其他驱动名称、A4/A3 强制纸张和其他 Ghostscript 版本尚未完成同等实机验证。

## 原理图数据要求

- 导出前先保存 DSN；检测到未保存修改时停止，插件不会代替用户保存。
- 每个物理元件须有合法、唯一的位号和 PCB Footprint。合法性由原生网表工具和目标 PCB 软件的封装库约束，Allegro 分支保留原生名称；PADS 分支还要求位号不超过 16 字符、网络名不超过 47 字符且名称符合其 ASCII 规则。插件不会自动猜测封装或静默改名。
- PDF 只包含勾选页，网表对应完整根设计，BOM 默认全量，启用规则后筛选；不自动套用 CIS 活动装配变体。
- Allegro 分支原样保留隐式电源、POWER_GROUP、层次和属性；PADS 分支展开普通隐藏电源脚，拒绝无法确定的 POWER_GROUP 重映射。外部 DSN、特殊层次结构和约束驱动流程未全面验证；报错时不会提交半套结果。
- 导出期间不要保存新的设计版本；原文件版本变化时会停止提交。

BOM 颜色和自定义属性筛选使用 Capture 17.2 自带数据库接口，无新增运行时依赖。颜色按器件保存的 ColorT ID 匹配，不映射为屏幕颜色名称。

## 从源码构建

普通用户下载 Release 安装 ZIP 即可；以下只适用于开发者：

- Windows x64 与 Windows PowerShell 5.1 或以上。
- CPython **3.12 x64**；已构建版本为 **3.12.14**。
- `requirements-build.txt` 固定的 `pypdf==6.21.4` 和 `pyinstaller==6.22.3`；PyInstaller 会安装其所需依赖。
- Tcl **8.6** 用于离线模拟测试。可使用 Cadence 自带 `tcltk/bin/tclsh.exe`，测试不会加载 Capture DLL 或打开原理图。
- 源码构建步骤见 [README.md](README.md)。首次下载 Python 依赖需要网络；已有依赖后构建不调用在线服务。

完整安装 ZIP 包含编译程序、Python 运行库、源码、测试、安装/卸载脚本、说明、许可和 `payload-sha256.json`。安装器会校验 payload 文件，压缩包整体校验值随 Release 单独提供。
