# 电脑配置扫描

在 Windows 上采集本机硬件、系统和已装软件，写成一份 xlsx，再用网页或 PyQt 窗口查看。扫描脚本不依赖本机安装 Excel。

```text
Scan-ComputerConfiguration.ps1  →  xlsx
                                 ↘  网页控制台   http://127.0.0.1:7040
                                 ↘  PyQt 窗口    同一套页面
```

## 可以看什么

一份工作簿里按表分开，例如：

| 硬件 | 系统 |
| --- | --- |
| 处理器、内存、硬盘、显卡 | 服务、已装软件、开机启动 |
| 主板、显示器、电池、USB | 网络、卷、分区、更新补丁 |

网页里可以按表切换、筛选、分页，也可以把工作簿下载下来。汇总页用卡片，其余表用表格；列多的时候横向滚动，行多的时候纵向滚动。

## 启动

需要 Windows、Python 3.10 或更高版本，以及 PowerShell 5.1。开发依赖：

```bat
pip install -e .
```

PyQt 桌面端还需要已安装的 `PyQt5` 与 `PyQtWebEngine`（已写在 `pyproject.toml` 里）。

| 脚本 | 作用 |
| --- | --- |
| `start_web.bat` | 只启动本机网页，并打开浏览器。不弹出 PyQt 窗口 |
| `start_desktop.bat` | 用 PyQt 窗口打开同一套页面 |
| `run.bat` | 只跑扫描脚本，把 xlsx 写到 `output\` |
| `win-win-build.bat` | 在 Windows 上打出可在 Windows 上直接运行的包 |

网页和桌面端默认地址是 `http://127.0.0.1:7040`。服务只监听本机。

命令行等价形式：

```bat
python -m ccs_host web --host 127.0.0.1 --port 7040
python -m ccs_host desktop --ui --host 127.0.0.1 --port 7040
```

不带 `--ui` 时只开浏览器。打包后的程序也是这样：双击默认启动脚本打开网页，需要窗口时再加 `--ui`。

## 登录

默认账号写在 [`config/host.json`](config/host.json)：

```json
{
  "username": "ccs",
  "password": "Sbk12345"
}
```

改密码后，下次启动生效。删掉 `password`，或把它留空，这组默认密码就不再能登录。会话是本机 Cookie，约 7 天。

导出目录可以在页面上修改。应用后后端会重启，当前登录失效，需要重新登录。

## 打包

在 Windows 构建机上双击 `win-win-build.bat`。脚本使用官方 CPython，不使用 Conda。

优先得到一个带时间戳的单文件，例如 `dist\ConfigScan-YYYYMMDD-HHMMSS.exe`。单文件不可用时，改为一个没有 `_internal` 目录的 zip。`dist\` 里会带上：

- `start_web.bat`：打开浏览器
- `start_desktop.bat`：打开 PyQt 窗口

目标电脑不需要安装 Python、Node 或 Qt。

## 目录

```text
Scan-ComputerConfiguration.ps1   扫描脚本
lib/XlsxWriter.ps1               写 xlsx
config/host.json                 默认登录账号
src/ccs_host/                    网页与 PyQt 宿主
packaging/                       Windows 打包脚本
start_web.bat                    启动网页
start_desktop.bat                启动桌面端
win-win-build.bat                打包
```

扫描结果在 `output\`，不进入版本库。
