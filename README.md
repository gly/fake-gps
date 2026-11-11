<p align="center">
  <img src="assets/icon_1024.png" alt="iOS Fake GPS 图标" width="160" height="160">
</p>

<h1 align="center">iOS Fake GPS</h1>

<p align="center">一款 Lockito 风格的 iPhone 定位模拟器 —— 纯净的 macOS 原生应用。</p>

<p align="center">
  <a href="https://github.com/orestislef/ios-fake-gps/releases/latest"><img src="https://img.shields.io/badge/download-macOS%20app-blue" alt="下载"></a>
  <a href="https://github.com/orestislef/ios-fake-gps/actions/workflows/ci.yml"><img src="https://github.com/orestislef/ios-fake-gps/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="许可证：MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20·%20Apple%20silicon-lightgrey" alt="平台">
  <img src="https://img.shields.io/badge/iOS-17%2B-black" alt="iOS 17+">
</p>

<p align="center">
  <a href="https://github.com/orestislef/ios-fake-gps/releases/latest"><b>⬇️ 下载 macOS 版</b></a>
  &nbsp;·&nbsp;
  <a href="#快速开始">快速开始</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/orestislef/ios-fake-gps/discussions">讨论区</a>
  &nbsp;·&nbsp;
  ⭐ 如果这个项目对你有帮助，欢迎点个 Star！
</p>

在**未越狱**的 iPhone 上设置固定位置，**或**播放移动路线（可调节速度、循环
和 GPS 抖动）。一切都通过原生 macOS 应用驱动 —— 只需用数据线把 iPhone 连上 Mac。

这是 Android 上 **Lockito** 的 iOS 对应版本。与 Android 不同，iOS 没有公开的
"模拟定位" API，所以安装在*手机上*的应用无法为其他应用伪造 GPS。本项目改用
Apple 的**开发者隧道**（developer tunnel）从连接的 Mac 端驱动定位 —— 与 Xcode
调试时模拟位置用的是同一机制。你设置的任何位置都会被设备上**所有应用**视为
系统级定位。

![macOS 应用：路线模式下的旧金山湾区，隧道已连接](docs/app.png)

> **请负责任地使用。** 本工具用于测试你自己的位置感知应用以及个人用途。
> 用它规避反作弊、实施欺诈或绕过基于位置的访问控制，违反相关服务条款，
> 也可能触犯法律。

## 快速开始

1. 从 [**Releases**](https://github.com/orestislef/ios-fake-gps/releases) 页面
   下载对应你 Mac 芯片的 zip 并解压：
   - **FakeGPS-macos-arm64.zip** —— M 系列芯片（M1/M2/M3/M4）
   - **FakeGPS-macos-x86_64.zip** —— Intel 芯片
2. 把 **FakeGPS.app** 拖进**应用程序（Applications）**文件夹。
3. 仅首次启动需要：macOS 会提示"来自身份不明的开发者"（应用未经公证）。
   **右键点击应用 → 打开**并确认。如果仍然无法打开，运行一次：
   ```bash
   xattr -dr com.apple.quarantine /Applications/FakeGPS.app
   ```
4. 打开应用。一个简短的**设置清单**会引导你完成剩余步骤 —— 插上 iPhone、
   启动隧道、连接。

就这么简单。引擎已打包在应用内，**无需安装 Python 或其他任何东西**，
完全不用碰终端。

### 设置清单会要求做什么

以下是 Apple 要求人工完成的仅有步骤 —— 无需下载任何东西：

- **连接 iPhone** —— 用 USB 数据线插上，点按**信任**，并打开**开发者模式**
  （设置 ▸ 隐私与安全性 ▸ 开发者模式）。设备一被识别，应用就会显示 ✓。
- **启动安全隧道** —— 一个按钮；每个会话会要求输入一次 Mac 密码
  （隧道以 root 运行，这是 Apple 的要求）。
- **连接** —— 将应用与设备链接。完成。

## 功能

- **默认中国大陆地图** —— 打开即显示中国全境，并自动居中到 Mac 的当前位置。
- **一键回到当前位置** —— 地图右下角的定位按钮，随时把地图居中回 Mac 所在地。
- **简体中文搜索** —— 直接输入中文地名 / 地址即可搜索。
- **传送** —— 点击地图或搜索选择位置，点侧边栏的「立即更新」才会应用到设备。
- **记住上次位置** —— 下次启动时默认选中上次「立即更新」的位置。
- **随机偏移** —— 可选开关：每次选择在点击位置 100 米范围内随机取一个点
  （圆内均匀分布）。
- **退出自动复位** —— 断开连接或退出应用时会自动恢复手机的真实位置，
  绝不会把你留在假位置上。

## 工作原理

```
macOS 应用 (SwiftUI + MapKit)             内置引擎                    iPhone
  搜索 / 放置路径点 / 路线 ─────────▶  pymobiledevice3  ──隧道──▶   所有应用
  速度 · 循环 · 抖动         ◀─────────  LocationSimulation  (DDI)   看到的都是假 GPS
  负责移动插值                           （冻结打包在 .app 内）
```

- **应用**负责地图、路线编辑和移动插值，因此速度 / 暂停 / 循环 / 抖动
  全部在 Mac 端控制。
- **引擎**是一个小型 Python 程序（基于
  [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 构建），
  冻结为独立二进制文件打包在 `FakeGPS.app` 内 —— Mac 上无需安装 Python。
  它保持一条开发者连接常开，逐个应用坐标。
- 一个小型**隧道守护进程**（由应用以 root 身份启动）打开开发者隧道并挂载
  Developer Disk Image。iOS 17+ 必需。

## 系统要求

- Mac（Apple silicon 或 Intel），macOS 14 或更新版本。
- **iOS 17 或更新版本**的 iPhone，配有 USB 数据线并开启**开发者模式**。

## 开发者 —— 从源码构建

应用是一个 Swift Package（`macapp/`）加一个 Python 引擎（`sidecar/`）。

### 前置条件

- macOS 14 或更新版本，**Apple silicon**
- [Xcode](https://developer.apple.com/xcode/)（或其 Command Line Tools），用于 Swift
- Python 3（系统自带的 `/usr/bin/python3` 即可），用于引擎 venv

### 1. 配置 Python 引擎（一次性）

安装到 `~/.ios-fake-gps`，而**不是** `~/Documents`，因为 root 隧道守护进程
无法读取受 TCC 保护的文件夹：

```bash
./setup.sh
```

它会创建 venv、安装 `pymobiledevice3` 并复制引擎脚本。如果中途失败
（网络慢时大文件下载可能超时），检查
`~/.ios-fake-gps/venv/bin/pip list` —— 若缺少 `pymobiledevice3`，
重新运行 `./setup.sh`，或直接手动安装：

```bash
~/.ios-fake-gps/venv/bin/pip install -r sidecar/requirements.txt
cp sidecar/gpsd_helper.py sidecar/fakegps_runtime.py ~/.ios-fake-gps/
```

### 2. 从源码运行应用

```bash
cd macapp && swift run        # 或在 Xcode 中打开 macapp/Package.swift 后运行
```

> **注意：** **首次** `swift build` 可能需要几分钟（要编译完整的调试模块
> 缓存）；之后的增量编译只需几秒。如果看起来卡住了，其实还在编译 ——
> 耐心等待即可。

窗口打开后，按应用内的清单操作：插上 iPhone（USB + 信任 + 开发者模式），
按**启动隧道**（会要求输入管理员密码），然后**连接**。

### 3. 构建可分发的应用（可选）

生成内置引擎、可双击打开的应用及发布 zip：

```bash
./scripts/build_app.sh        # 构建引擎 + 应用 -> dist/FakeGPS.app + zip
```

需要先在 venv 中安装 **PyInstaller**（`setup.sh` 不会安装它）：

```bash
~/.ios-fake-gps/venv/bin/pip install pyinstaller
```

构建出的应用未经公证，移入 `/Applications` 后需清除一次隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/FakeGPS.app
```

### 分架构打包（支持 Intel）

本机打包只能产出当前架构的包：M 系列机器出 arm64，Intel 机器出 x86_64
（`build_app.sh` 自动按 `uname -m` 命名产物）。由于 PyInstaller 不支持
交叉编译，Intel 包必须在 Intel 机器上构建。仓库内置了
[GitHub Actions workflow](.github/workflows/build.yml)，会在两种架构的
云构建机上各打一个包：

- `macos-14`（Apple silicon）→ `FakeGPS-macos-arm64.zip`
- `macos-13`（Intel）→ `FakeGPS-macos-x86_64.zip`

手动触发（workflow_dispatch）或推送 `v*` 标签即可，产物在 Actions Artifacts。

> **注意：** Gitee 没有免费的 macOS 云构建机。若仓库托管在 Gitee，
> 可将仓库镜像到 GitHub 后使用该 workflow，或在 Intel Mac 上手动打包。

### 重新生成图标

```bash
~/.ios-fake-gps/venv/bin/python scripts/make_icon.py
iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
```

### 项目结构

```
ios-fake-gps/
├── macapp/Sources/FakeGPS/   macOS 应用（SwiftUI + MapKit）
├── sidecar/                  Python 引擎 + 运行时入口
├── scripts/                  build_runtime.sh、build_app.sh、make_icon.py
├── assets/                   应用图标
└── docs/                     截图
```

## 命令行使用（可选）

应用内的引擎也可以直接在终端使用。先启动隧道：

```bash
sudo "/Applications/FakeGPS.app/Contents/Resources/runtime/fakegps-runtime" tunneld
```

然后用应用内置的 `pymobiledevice3` 列出设备：

```bash
"/Applications/FakeGPS.app/Contents/Resources/runtime/fakegps-runtime" sidecar --list
```

## 故障排查

- **应用打不开（"身份不明的开发者"）** —— 右键 → 打开，或运行
  `xattr -dr com.apple.quarantine /Applications/FakeGPS.app`。
- **隧道启动失败** —— 确认已输入管理员密码；守护进程需要 root。
  日志位于 `/tmp/ios-fake-gps-tunneld.log`。
- **一直检测不到 iPhone** —— 检查数据线，在手机上点按**信任**，并确认
  **开发者模式**已开启（然后重启手机）。
- **"无法打开 LocationSimulation"** —— 开发者模式未开启，或 Developer Disk
  Image 尚未挂载；隧道启动后等几秒再试。

## 限制

- Mac 必须保持连接（USB；初次 USB 配对后 Wi-Fi 也可用）。
- 隧道以 root 运行，因此每个会话会要求一次密码 —— 这是 Apple 的硬性要求，
  无法去除（这也是它没法上 App Store、以及任何纯设备端应用做不到的原因）。
- 它只修改上报的位置；不会伪造 Wi-Fi 或基站信号，因此少数交叉校验这些
  信号的应用可能会察觉不一致。

## 参与贡献

欢迎贡献 —— 见 [CONTRIBUTING.md](CONTRIBUTING.md) 和
[行为准则](CODE_OF_CONDUCT.md)。安全问题报告请见 [SECURITY.md](SECURITY.md)。

## 许可与使用

基于 [MIT 许可证](LICENSE) 发布。请阅读[免责声明](DISCLAIMER.md)：
本工具仅用于合法测试和个人用途 —— 不得用于欺诈、规避反作弊/反欺诈系统
或欺骗第三方。
