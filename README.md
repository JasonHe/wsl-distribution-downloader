# WSL Distribution Downloader

Interactive single-file Windows batch script for downloading official WSL distribution packages from Microsoft's `DistributionInfo.json`.

This project is designed for fresh Windows installations: double-click `download.bat`, select distributions with the keyboard, and the script downloads verified packages into `dist`.

## Features

- Single `download.bat` entry point.
- No required preinstalled third-party tools.
- Automatically creates `dist` and `tmp`.
- Automatically downloads and updates `aria2c` from the official GitHub Release.
- Detects system architecture and selects the matching x64 or ARM64 package URL.
- Downloads modern WSL packages with SHA-256 verification.
- Supports legacy Store/Appx packages with a clear warning when SHA-256 is unavailable.
- Uses aria2's native download progress display.
- Skips already downloaded modern packages when SHA-256 matches.
- Cleans temporary files while keeping `tmp\bin\aria2c.exe`.
- Handles `Ctrl+C` and cleans up the active aria2 process.
- Prevents multiple script instances from running in the same folder.

## Requirements

- Windows 10/11.
- Windows PowerShell.
- Internet access.

The script does not require Git, 7-Zip, tar, or preinstalled aria2.

## Usage

1. Download or clone this repository.
2. Double-click `download.bat`.
3. Use the keyboard menu:
   - `Up` / `Down`: move
   - `Space`: select or unselect
   - `Enter`: continue
4. Select modern WSL distributions first.
5. Optionally select legacy Store/Appx packages on the second page.
6. Downloaded files are saved to `dist`.

## Output Layout

```text
download.bat
dist\
tmp\
  bin\
    aria2c.exe
    version.txt
```

Only `dist` is meant to contain final downloaded packages.

`tmp` is used during execution. After completion, the script keeps only `tmp\bin` so aria2 does not need to be downloaded again.

## Modern vs Legacy Packages

The Microsoft WSL JSON contains two distribution groups:

- `ModernDistributions`
- `Distributions`

Modern entries include package URLs and SHA-256 hashes. These files are verified after download and can be safely skipped on later runs when the hash matches.

Legacy entries are Store/Appx packages. They do not provide SHA-256 hashes in the JSON, so the script can download them but cannot verify them. The menu shows a warning before selecting legacy packages.

## File Naming

The output file name is based on `FriendlyName` from the JSON:

- Spaces are replaced with underscores.
- Invalid Windows filename characters are replaced.
- The original source extension is preserved.
- Architecture suffixes such as `_x64` or `_arm64` are not added because the script already selects the correct URL by architecture.

Example:

```text
Debian GNU/Linux -> Debian_GNU_Linux.wsl
AlmaLinux OS 8   -> AlmaLinux_OS_8.wsl
```

## Safety Notes

- Modern packages are verified with SHA-256.
- Legacy packages are not SHA-256 verified because the source JSON does not provide hashes.
- If a modern package exists and passes verification, it is skipped.
- If a modern package exists but fails verification, it is downloaded again.
- If a legacy package exists, it may be overwritten because no hash is available.
- If `Ctrl+C` is pressed during download, the active aria2 process is stopped.

## 中文说明

# WSL 发行版下载器

这是一个交互式单文件 Windows 批处理脚本，用于从 Microsoft 的 `DistributionInfo.json` 下载官方 WSL 发行版包。

项目目标是适合全新 Windows 系统使用：双击 `download.bat`，通过键盘选择发行版，最终文件会下载到 `dist`。

## 功能

- 单文件入口：`download.bat`。
- 不要求预装第三方工具。
- 自动创建 `dist` 和 `tmp`。
- 自动从 aria2 官方 GitHub Release 下载并更新 `aria2c`。
- 自动判断系统架构，并选择对应的 x64 或 ARM64 下载地址。
- 下载现代 WSL 包并进行 SHA-256 校验。
- 支持旧版 Store/Appx 包，并在无法校验时给出明确提示。
- 使用 aria2 原生下载进度显示。
- 现代包如果已存在且 SHA-256 一致，会自动跳过。
- 清理临时文件，只保留 `tmp\bin\aria2c.exe`。
- 支持 `Ctrl+C` 中断，并清理当前 aria2 进程。
- 防止同一目录下多个脚本实例同时运行。

## 系统要求

- Windows 10/11。
- Windows PowerShell。
- 可以访问互联网。

脚本不要求预装 Git、7-Zip、tar 或 aria2。

## 使用方法

1. 下载或克隆本仓库。
2. 双击 `download.bat`。
3. 使用键盘菜单：
   - `Up` / `Down`：移动
   - `Space`：选择或取消选择
   - `Enter`：继续
4. 第一页选择现代 WSL 发行版。
5. 第二页可选旧版 Store/Appx 包。
6. 下载完成的文件会保存到 `dist`。

## 输出目录

```text
download.bat
dist\
tmp\
  bin\
    aria2c.exe
    version.txt
```

`dist` 用于保存最终下载结果。

`tmp` 用于运行过程中的临时文件。脚本完成后只保留 `tmp\bin`，避免下次重复下载 aria2。

## 现代包和旧版包的区别

Microsoft WSL JSON 中有两类发行版信息：

- `ModernDistributions`
- `Distributions`

现代包包含下载地址和 SHA-256，因此脚本会在下载后进行校验，并能在后续运行中根据校验结果跳过已下载文件。

旧版包通常是 Store/Appx/AppxBundle 包。JSON 中没有提供 SHA-256，因此脚本可以下载，但无法进行 hash 校验。选择旧版包前，菜单会显示风险提示。

## 文件命名

输出文件名来自 JSON 中的 `FriendlyName`：

- 空格替换为下划线。
- Windows 文件名非法字符会被替换。
- 保留源文件原始扩展名。
- 不再添加 `_x64` 或 `_arm64` 后缀，因为脚本已经根据系统架构选择了正确 URL。

示例：

```text
Debian GNU/Linux -> Debian_GNU_Linux.wsl
AlmaLinux OS 8   -> AlmaLinux_OS_8.wsl
```

## 安全说明

- 现代包会进行 SHA-256 校验。
- 旧版包因为 JSON 没有提供 SHA-256，所以无法校验。
- 现代包存在且校验通过时，会跳过下载。
- 现代包存在但校验失败时，会重新下载。
- 旧版包存在时，可能会被覆盖，因为无法判断文件是否正确。
- 下载过程中按 `Ctrl+C`，脚本会停止当前 aria2 进程。
