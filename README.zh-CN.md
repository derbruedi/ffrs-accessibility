# FINAL FANTASY RESONANCE 无障碍模组

[Deutsch](README.md) | [简体中文](README.zh-CN.md)

这是一个让 FINAL FANTASY RESONANCE 可以通过屏幕阅读器游玩的
无障碍模组，支持 NVDA、JAWS 等，通过 Prism 朗读。模组会朗读
菜单、对话、交谈、战斗和结算，并提供寻路功能，可以带角色前往
人物、宝箱、出口和任务目标。

模组通过 [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) 在游戏中运行。
它不会修改游戏文件，也不会绕过版权保护。

**状态：测试版。** 版本号中带 b 的版本是测试版。

## 安装

1. 从 [Releases](https://github.com/derbruedi/ffrs-accessibility/releases) 下载最新的 `FFRSAccess-Setup.exe`。
2. 关闭游戏并启动安装程序。它会查找 Steam 库中的游戏；在“语言”下拉框中选择语言，然后按 Enter 安装。
3. 安装程序启动时会检查 GitHub 上的新版本，并询问是否下载和安装。
4. 图形化安装程序会在安装后下载约 400 MB 的过场动画音频描述；Zip 脚本安装不下载该内容。

按键和详细说明见 [installer/Liesmich.zh-CN.txt](installer/Liesmich.zh-CN.txt)。
如果要在游戏中选择其他朗读语言，也可以修改模组目录中的 `language.txt`，然后重新启动游戏。

## 项目结构

- `mod/FFRSAccess/Scripts/main.lua`：UE4SS Lua 模组
- `native/ffrs_speech.cpp`：通过命名管道连接 Prism 的语音 DLL
- `installer/`：WinForms 安装程序（.NET Framework 4.8）、脚本安装器、打包和发布脚本
- `research/extract/`：从游戏数据中生成名称和路径图的工具（仓库不包含游戏数据）

## 参与翻译

语言包位于 `mod/FFRSAccess/Scripts/locales/`。译者指南：

- [English](docs/LOCALIZATION.md)
- [简体中文](docs/LOCALIZATION.zh-CN.md)
- [简体中文术语表](docs/GLOSSARY.zh-CN.md)

运行以下命令检查语言包：

    powershell -NoProfile -ExecutionPolicy Bypass -File tools/check_locales.ps1

## 发布新版本

1. 修改 `VERSION`（例如 `0.1.1b`）。
2. 运行 `installer\release.ps1`：构建安装程序，创建标签 `v<Version>`，并上传安装程序和 Zip。

## 许可证

UE4SS：MIT 许可证。Prism：MPL-2.0；组件许可证位于 `third_party/prism/LICENSES`。
