# BaoCode Codex Windows x64 构建

此分支在原 BaoCode Windows 界面中增加本机 Codex App Server 后端，保留
Claude。安装包不会打包 Codex 凭据，也不包含 Codex CLI。使用 Codex 前先单独
安装官方 Windows Codex CLI，在本机完成登录，并确认 `codex --version`
可用（安装或调整 PATH 后重新启动 BaoCode）。如果只找到 npm 的命令脚本或无 PATH 入口，
设置环境变量 `BAOCODE_CODEX_PATH` 为官方 `codex.exe` 的绝对路径后重启。

## Windows 本机编译

需要 x64 Windows、Flutter stable **3.47.5**、带「使用 C++ 的桌面开发」
工作负载的 Visual Studio 和 Windows SDK、Rust（rustup），以及 Inno Setup 6。
确认 `flutter doctor -v` 的 Windows/Visual Studio 检查通过。在源码目录中
打开 PowerShell：

```powershell
flutter pub get
flutter test test/kernel_test.dart --plain-name "Codex adapter"
flutter test test/codex_catalog_test.dart
dart run tool/build_windows.dart --arch x64 --remote-release 2.0.2.35-d0c299e2b113 --disable-upstream-updates
```

安装包输出到 `build/installers/BaoCode-<版本>-setup.exe`。
`--remote-release` 固定使用 BaoCode v2.0.2 的官方远程组件清单，不重新构建
SSH 远程组件；这一项不会为远程项目启用 Codex 后端。构建脚本还会从官方
Microsoft 发布获取并校验它打包的 OpenSSH 组件。

## GitHub Actions（只生成构建附件）

将源码放到你控制的仓库。在 Actions 页面选择 **BaoCode Codex Windows installer**
并手动启动（工作流须先存在于仓库默认分支），或者在已经允许 Actions 的仓库推送
`codex-app-server-windows` 分支触发构建。工作流只上传
`baocode-codex-windows-x64-installer` 附件（EXE 和 SHA-256），不创建发布、
不改更新服务器，也不需要签名密钥。该工作流不等同于 Windows 真机界面和
Codex 登录验收；使用安装包后请用一个本地测试项目打开新聊天并选择 Codex。

这个构建沿用上游 Windows 安装器的应用身份，不是独立的并行安装版。如果
已有官方 BaoCode，安装自编译版前先备份设置与会话。自编译包没有上游
代码签名，Windows 可能显示发布者未验证的提示。

自编译包关闭上游自动更新，避免被官方 BaoCode 安装包覆盖。
