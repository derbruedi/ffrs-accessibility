# 添加新语言

FINAL FANTASY RESONANCE 无障碍模组的 Lua 部分和安装程序共用 UTF-8 语言包。

## 文件

- `mod/FFRSAccess/Scripts/locales/de-DE.lang` 是参考语言，必须保持完整。
- 每种语言增加一个 BCP-47 代码文件，例如 `fr-FR.lang`。
- 文件名、`[meta] code` 和安装目录名必须一致。
- 文件使用 UTF-8 无 BOM，LF 或 CRLF 换行均可。

## 格式

语言包包含 `[meta]`、`[installer]` 和 `[mod]`：

    [meta]
    code = fr-FR
    native_name = Français
    fallback = de-DE

    [installer]
    installer.install = &Installer

    [mod]
    category.quest = Objectif de quête

规则：

- 键名使用小写点分标识符。
- 每行只在第一个 `=` 处分割，后面的 `=` 属于值。
- 去除行首空白后，`#` 开头表示注释。
- 换行、制表符和反斜杠分别写成 `\n`、`\t`、`\\`。
- 使用 `{name}`、`{distance}` 等命名占位符。
- 所有语言必须与 `de-DE.lang` 保持相同的键和占位符。
- 数量相关文本使用 `.one` 和 `.other`，由 `T.plural` / `LocaleCatalog.N` 选择。

## 工作流程

1. 复制 `de-DE.lang`，修改为目标语言代码。
2. 翻译值，不要修改键和占位符。
3. 运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/check_locales.ps1`。
4. 启动安装程序并选择新语言。
5. 将 `language.txt` 设为新语言代码，启动游戏测试菜单、对话、战斗和寻路。
6. 如有能力，同时添加 `README.<code>.md` 和 `installer/Liesmich.<code>.txt`。
7. 中文术语参考 `docs/GLOSSARY.zh-CN.md`，保持前后一致。

## 游戏文本

游戏提供的 NPC、道具、任务和地图名称跟随游戏语言。不要把游戏数据复制进语言包，只翻译模组自己产生的文本。

## 运行时选择

安装程序会把所选语言写入 `FFRSAccess/language.txt`。模组也接受 `auto`；文件缺失时会依次尝试当前 Unreal 语言、`LANG`、`LC_ALL`，最后回退到 `de-DE`。

修改后重新启动游戏生效。
