# macOS 从零开始一键构建指南

本文介绍如何在一台尚未配置嵌入式开发环境的 Mac 上准备 XiaoZhi 的构建环境，并生成可烧录的 ESP32 固件。项目最低支持 ESP-IDF v6.0.1，脚本默认安装并使用推荐的 ESP-IDF v6.1。

## 1. 最终会得到什么

执行一条命令：

```bash
./scripts/macos_build.sh
```

脚本会依次完成：

1. 检查 macOS 和 Apple Command Line Tools。
2. 在缺失时启动 Apple Command Line Tools 官方安装器。
3. 在缺失时运行 Homebrew 官方安装器。
4. 通过 Homebrew 安装 CMake、Ninja、ccache、dfu-util 和 Python 3.12。
5. 将 ESP-IDF v6.1 克隆到 `~/esp/esp-idf-v6.1`。
6. 根据板型安装对应芯片工具链和 ESP-IDF Python 环境。
7. 调用项目的标准入口 `scripts/build.py` 配置并编译固件。
8. 输出固件路径、文件大小和 SHA-256。

脚本不会修改 `.zshrc`、`.bash_profile` 等 shell 启动文件，也不会自动烧录设备。Homebrew、ESP-IDF 工具链和 Python 虚拟环境会写入用户目录；项目构建生成的 `build/`、`managed_components/`、`sdkconfig` 和 `dependencies.lock` 已被 Git 忽略。

默认构建配置如下：

| 项目 | 默认值 |
| --- | --- |
| 板型目录 | `bread-compact-wifi` |
| 固件变体 | `bread-compact-wifi` |
| 芯片 | ESP32-S3 |
| 屏幕 | SSD1306 128×32 |
| 语言 | `en-US` |
| 唤醒词 | Hi ESP |
| ESP-IDF | v6.1 |

## 2. 开始前的准备

建议准备：

- Apple Silicon 或 Intel Mac。
- 一个具有管理员权限的 macOS 账户；首次安装 Homebrew 时可能需要输入密码。
- 至少 15 GB 可用磁盘空间。多芯片工具链和多个构建目录会继续占用空间。
- 可访问 GitHub、Homebrew 和 Espressif Component Registry 的稳定网络。
- 如果后续需要烧录，准备支持数据传输的 USB 线。仅编译时不需要连接开发板。

脚本本身位于代码仓库中，因此需要先取得项目源码。全新 Mac 可以先运行：

```bash
xcode-select --install
```

在弹出的系统窗口中完成安装，然后执行：

```bash
git clone https://github.com/78/xiaozhi-esp32.git
cd xiaozhi-esp32
./scripts/macos_build.sh
```

也可以先通过浏览器下载项目 ZIP、解压并进入目录，再直接运行脚本；脚本会自行触发 Apple Command Line Tools 安装。安装窗口打开后，脚本会等待安装完成。

> Homebrew 官方安装器会展示将要执行的操作。它可能要求输入 macOS 登录密码；终端输入密码时不会显示字符，这是正常现象。

## 3. 最常用的构建命令

### 默认构建

```bash
./scripts/macos_build.sh
```

### 构建中文固件

`zh-CN` 会默认选择“你好小智”唤醒词：

```bash
./scripts/macos_build.sh --language zh-CN
```

### 构建 128×64 OLED 变体

```bash
./scripts/macos_build.sh \
  --board bread-compact-wifi \
  --name bread-compact-wifi-128x64 \
  --language zh-CN
```

### 只准备环境，不编译

```bash
./scripts/macos_build.sh --prepare-only
```

### 同时创建发布 ZIP

```bash
./scripts/macos_build.sh --language zh-CN --zip
```

ZIP 会生成到 `releases/`。普通本地烧录不需要 `--zip`。

## 4. 选择板型和构建选项

列出仓库支持的板型、变体和目标芯片：

```bash
./scripts/macos_build.sh --list-boards
```

构建指定板型时，`--board` 必须对应 `main/boards/` 下的目录，`--name` 必须对应该目录 `config.json` 中的 `build.name`：

```bash
./scripts/macos_build.sh \
  --board <板型目录> \
  --name <变体名称>
```

如果 `--name` 未提供，脚本会优先选择与板型目录同名的变体；只有一个变体时会直接选择它。如果存在多个变体且无法确定默认项，脚本会列出允许的名称并停止。

完整参数：

```text
--board BOARD                 板型目录
--name VARIANT               config.json 中的准确变体名
--language LOCALE            例如 zh-CN、en-US
--wake-word MODEL            模型名、nihaoxiaozhi、hiesp 或 disabled
--build-options-json JSON     板型语义化构建选项
--idf-path PATH              自定义 ESP-IDF 路径
--zip                        创建发布 ZIP
--list-boards                列出板型后退出
--prepare-only               只安装环境
--skip-system-packages       不安装系统和 Homebrew 依赖
```

例如关闭唤醒词：

```bash
./scripts/macos_build.sh --language zh-CN --wake-word disabled
```

传递板型构建选项时，JSON 外层使用单引号，防止 shell 展开双引号：

```bash
./scripts/macos_build.sh \
  --board bread-compact-wifi \
  --name bread-compact-wifi \
  --build-options-json '{"display_model":"OLED_SSD1306_128X64","wifi_provisioning":"blufi"}'
```

某个变体允许的键、类型和取值可通过机器可读清单查询：

```bash
python3 scripts/build.py --list-boards --json
```

## 5. 构建产物

成功后主要文件位于 `build/`：

| 文件 | 用途 |
| --- | --- |
| `build/merged-binary.bin` | 合并镜像，从 Flash 地址 `0x0` 烧录 |
| `build/xiaozhi.bin` | 应用分区固件，用于 OTA 或分区级烧录 |
| `build/generated_assets.bin` | 字体、语言和唤醒词等资源分区 |
| `build/bootloader/bootloader.bin` | Bootloader |
| `build/partition_table/partition-table.bin` | 分区表 |
| `build/flash_args` | ESP-IDF 生成的完整烧录参数 |

脚本末尾会打印主要二进制文件的 SHA-256。分发固件时应同时记录板型、变体、语言、项目版本和哈希，避免烧录到不兼容的硬件。

## 6. 烧录和串口监视

一键脚本只负责编译。需要烧录时，重新打开终端并激活同一套 ESP-IDF 环境：

```bash
export PATH="$(brew --prefix python@3.12)/libexec/bin:$PATH"
source "$HOME/esp/esp-idf-v6.1/export.sh"
cd /path/to/xiaozhi-esp32
```

查看串口：

```bash
ls /dev/cu.*
```

指定串口烧录并打开日志：

```bash
idf.py -p /dev/cu.usbmodemXXXX flash monitor
```

将 `/dev/cu.usbmodemXXXX` 替换为实际端口。退出监视器使用 `Ctrl+]`。如果板卡没有自动进入下载模式，按住 BOOT，再短按 RESET，然后松开 BOOT 后重试。不同板卡的按键逻辑可能不同，应以板卡文档为准。

也可以直接烧录合并镜像：

```bash
python -m esptool --chip esp32s3 write-flash 0x0 build/merged-binary.bin
```

上例芯片参数仅适用于 ESP32-S3。其他板型应使用其 `config.json` 中的 `target`，或直接使用 `idf.py flash`，由当前构建配置自动选择目标。

## 7. 脚本做了哪些环境处理

### Apple Command Line Tools

它提供 Git、Clang 和 macOS SDK。若系统中不存在，脚本调用：

```bash
xcode-select --install
```

系统安装器属于图形界面，必须由用户确认，无法完全静默安装。默认等待时间为 30 分钟；如需调整：

```bash
XIAOZHI_CLT_WAIT_SECONDS=3600 ./scripts/macos_build.sh
```

### Homebrew 基础包

脚本安装以下包：

```bash
brew install cmake ninja ccache dfu-util python@3.12
```

固定使用 Python 3.12 可以避免系统 Python 变化导致 ESP-IDF 虚拟环境路径和第三方包兼容性不稳定。脚本只为本次进程调整 `PATH`，不会永久修改 shell 配置。

### ESP-IDF 和工具链

默认 SDK 路径：

```text
~/esp/esp-idf-v6.1
```

芯片交叉编译器、调试器和 Python 虚拟环境默认位于：

```text
~/.espressif/
```

脚本读取板型 `config.json` 的 `target`，再执行：

```bash
./install.sh <target>
source export.sh
python3 scripts/build.py <board> --name <variant>
```

`install.sh` 可以安全重复执行：已安装且版本一致的工具会被复用。后续构建一般只需增量编译。

## 8. 使用已有 ESP-IDF

可通过参数指定 SDK：

```bash
./scripts/macos_build.sh \
  --idf-path /absolute/path/to/esp-idf \
  --board bread-compact-wifi
```

也可以设置环境变量：

```bash
XIAOZHI_IDF_PATH=/absolute/path/to/esp-idf ./scripts/macos_build.sh
```

脚本接受 ESP-IDF v6.0.1 或更高版本；ESP32-S31 要求 v6.1 或更高版本。ESP-IDF 5.x 会被明确拒绝。如果指定路径已存在但不是有效的 ESP-IDF checkout，脚本不会覆盖它。

已经自行准备完所有依赖时，可跳过 Homebrew 安装步骤：

```bash
./scripts/macos_build.sh \
  --skip-system-packages \
  --idf-path /absolute/path/to/esp-idf
```

此模式仍会检查构建必需的 `git`、`python3`、`cmake` 和 `ninja` 是否可用；缺少仅用于编译缓存的 `ccache` 或部分 DFU 烧录场景使用的 `dfu-util` 时会给出警告，但不会阻止编译。

## 9. 常见问题

### Apple Command Line Tools 一直等待

先确认系统安装窗口是否被其他窗口遮挡。也可以终止脚本，手动执行：

```bash
xcode-select --install
xcode-select -p
```

第二条命令能够输出路径后重新运行一键脚本。

### 安装 Homebrew 或下载 ESP-IDF 失败

检查 GitHub 和 Homebrew 地址是否可访问，并确认代理环境变量在当前终端有效：

```bash
env | grep -E '^(HTTP|HTTPS|ALL)_PROXY='
```

网络恢复后直接重试。若 ESP-IDF 目标目录是一次失败留下的非完整目录，请先将该目录重命名保存，再重新运行；脚本不会主动删除或覆盖非空目录。

### ESP-IDF Python 虚拟环境不存在

直接重跑脚本。它会再次调用 ESP-IDF 的 `install.sh`，补齐与 Python 3.12 对应的环境，然后重新激活。

### 板型存在多个变体

按报错中给出的名称补充 `--name`，或者运行：

```bash
./scripts/macos_build.sh --list-boards
```

不要通过改写已有板型引脚来适配不同硬件；应选择正确变体或新增具有唯一身份的板型。板型身份会影响 OTA 兼容性。

### 切换芯片后出现旧配置问题

始终通过本脚本或 `scripts/build.py` 构建。构建入口会检测目标芯片并处理原有构建状态。不要假设 `build/` 和 `sdkconfig` 仍属于上一次板型。

### 磁盘空间不足

查看主要目录占用：

```bash
du -sh build managed_components ~/.espressif ~/esp/esp-idf-v6.1 2>/dev/null
```

`build/` 是可重新生成的构建输出；删除任何目录前应确认路径准确。`~/.espressif` 包含下载的工具链，删除后下次会重新下载。

### 编译成功但设备工作异常

成功编译只证明软件能够生成固件，不等于完成硬件验证。烧录后仍需检查录音、播放、唤醒、屏幕、按键、网络连接、重连和供电情况；涉及摄像头、AEC 或 4G 的板卡还需验证相应功能。

## 10. 不使用脚本的等价手动流程

以下命令展示脚本的核心流程，适合排障或需要完全手工控制的场景：

```bash
xcode-select --install

# 安装 Homebrew 后
brew install cmake ninja ccache dfu-util python@3.12
export PATH="$(brew --prefix python@3.12)/libexec/bin:$PATH"

mkdir -p "$HOME/esp"
git clone --branch v6.1 --depth 1 --recursive --shallow-submodules \
  https://github.com/espressif/esp-idf.git \
  "$HOME/esp/esp-idf-v6.1"

cd "$HOME/esp/esp-idf-v6.1"
./install.sh esp32s3
source export.sh

cd /path/to/xiaozhi-esp32
idf.py --version
python3 scripts/build.py bread-compact-wifi \
  --name bread-compact-wifi \
  --language zh-CN
```

如果构建其他板型，应先从该板型的 `config.json` 确认目标芯片，再将 `install.sh esp32s3` 中的参数替换成实际 `target`。
