# OrCAD TriExport 17.2

适用于 **OrCAD Capture / Capture CIS 17.2** 的 Windows 扩展，提供英文操作界面。一次导出 Allegro 原生网表 ZIP、原理图 PDF 和 BOM，成功结果目录严格只有三个文件。

当前版本：**1.0.0-rc7**（候选版本）。

## 下载与安装

从本仓库的 [Releases](https://github.com/yangzhaoxu411/orcad-triexport-17.2/releases) 下载 `OrCAD-TriExport-17.2-1.0.0-rc7.zip`，完整解压，保存工作并关闭 Capture，然后双击 `install.cmd`。重新启动 Capture 后，使用顶部 **Help** 右侧的 **TriExport > Export Files...**。

GitHub 自动生成的 **Source code** 压缩包只有源码，不含运行所需的编译程序。普通用户请下载上述安装 ZIP；校验值位于同一 Release 的 `.zip.sha256.txt` 文件。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10/11 **x64**；本次实测 Windows 11 x64 |
| OrCAD | 已安装并有可用许可的 Capture / Capture CIS **17.2**，包含原生网表工具与 Tcl/Tk PDF 接口 |
| PDF 打印驱动 | 已安装且可用的 PostScript 驱动，默认 `OrCADPS_17.2` |
| PDF 转换器 | 单独安装 Ghostscript，选择 `gswin64c.exe`；本次实测 **10.08.0** |
| 安装脚本 | Windows PowerShell **5.1** 或以上；启动脚本使用系统 `powershell.exe` |
| 目录权限 | 能写入插件自动加载目录、当前用户 LocalAppData 和导出根目录 |
| Python / Excel / Allegro PCB Editor | 运行安装包不需要 Python；导出不需要 Excel 或 Allegro PCB Editor |

完整依赖路径、已验证环境、构建要求与兼容边界见 [ENVIRONMENT.md](ENVIRONMENT.md)。本包不包含 OrCAD、打印驱动或 Ghostscript。

## 使用

1. 在 Capture 中打开并保存目标 DSN。
2. 打开 **TriExport > Export Files...**，选择 **Output root folder**。
3. 多选要放入 PDF 的页面，支持不连续选择；设置 Ghostscript 路径和打印驱动。
4. 点击 **Export Files**，等待成功提示。

每次成功导出会新建独立目录：

```text
output-root/
  design_YYYYMMDD_HHMMSS/
    design_allegro.zip  # Allegro 原生三个 PST 文件
    design.pdf    # 勾选页面合并为一份 PDF
    design.csv    # UTF-8 BOM 编码的物料表
```

页面勾选只控制 PDF；网表和 BOM 始终覆盖完整根设计。不会覆盖历史结果，也不会在结果目录内留下中间打印数据或日志。

## 在 Allegro 中导入

先将 `design_allegro.zip` 解压到一个独立文件夹，确认该目录直接包含 `pstchip.dat`、`pstxprt.dat` 和 `pstxnet.dat`。在 Allegro PCB Editor 中使用 **File > Import > Logic**，选择 **Design Entry CIS (Capture)**，将 **Import directory** 指向该目录，再执行导入。不要直接选择 ZIP，也不要更改三个 DAT 文件的名称。

导入需要 Allegro 可用许可及匹配的封装库；本插件不会生成 PCB 布局或替代封装库。

## 验证与限制

rc7 已运行本机 Cadence 原生网表工具和编译后的导出程序，验证 31 页与 2 页输出及网表 ZIP 原字节保留。PDF/BOM 输入使用此前成功的 Capture 打印作业，并确认保存的 DSN 哈希一致。此前 rc6 已在 Capture 窗口内验证完整及非连续页面导出。新版当前会话需重启加载；详细区分见验证记录。

Allegro PCB Editor 应用内导入及目标封装库匹配尚未验证。本版不重写原生网表或自动修改封装，也不支持按 CIS 装配变体裁剪网表/BOM；POWER_GROUP 和隐式电源属性随原生 PST 保留，由 Allegro 解释。具体范围见 [验证记录](VALIDATION.md) 和 [详细使用说明](README-中文.md)。

## 源码构建

需要 Windows x64、Python **3.12 x64**、项目固定版本依赖及 Tcl **8.6**。在项目目录运行：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-build.txt
.\build.ps1 -Python .\.venv\Scripts\python.exe -Tclsh "C:\Cadence\SPB_17.2\tcltk\bin\tclsh.exe"
```

按实际安装位置修改 Tcl 路径。构建会执行离线测试、打包、自检，产物在 `release/`；不会启动 Capture 或安装插件。真实原理图和本机测试日志不属于源码仓库。

## 文档与许可

- [详细安装、使用、卸载与故障排查](README-中文.md)
- [环境要求及已验证配置](ENVIRONMENT.md)
- [更新记录](CHANGELOG.md)
- [验证范围](VALIDATION.md)

源码使用 [MIT License](LICENSE.txt)。安装包内第三方运行库许可位于 `payload/THIRD_PARTY/`。本项目不是 Cadence 或 Siemens 官方产品。
