# Adding a language

FINAL FANTASY RESONANCE Zugang uses shared UTF-8 language packs for the Lua mod and the installer.

## Files

- `mod/FFRSAccess/Scripts/locales/de-DE.lang` is the reference language and must stay complete.
- Add one file per language using a BCP-47 code, for example `fr-FR.lang`.
- The file name, `[meta] code`, and the install folder name must match.
- Files must be UTF-8 without BOM and use LF or CRLF line endings.

## Format

A pack contains `[meta]`, `[installer]`, and `[mod]` sections:

    [meta]
    code = fr-FR
    native_name = Français
    fallback = de-DE

    [installer]
    installer.install = &Installer

    [mod]
    category.quest = Objectif de quête

Rules:

- Keys are lower-case dot-separated identifiers.
- Split each entry at the first `=`; later `=` characters belong to the value.
- `#` starts a comment only at the beginning of a trimmed line.
- Escape newlines, tabs, and backslashes as `\n`, `\t`, and `\\`.
- Use named placeholders such as `{name}` and `{distance}`.
- Every pack must keep exactly the same keys and placeholders as `de-DE.lang`.
- Count-dependent text uses `.one` and `.other` keys. `T.plural` / `LocaleCatalog.N` select them.

## Workflow

1. Copy `de-DE.lang` to a new language code.
2. Translate values, but keep keys and placeholders unchanged.
3. Run `powershell -NoProfile -ExecutionPolicy Bypass -File tools/check_locales.ps1`.
4. Start the installer and select the new language.
5. Run the game with `language.txt` set to the new code and test menus, dialogue, battle, and pathfinder.
6. Add a translated `README.<code>.md` and `installer/Liesmich.<code>.txt` when available.
7. Keep project-specific terms consistent with `docs/GLOSSARY.zh-CN.md` when translating Chinese.

## Game text

Game-provided NPC, item, quest, and map names follow the language selected in the game. Do not copy game data into language packs. Only translate text produced by the mod.

## Runtime selection

The installer writes the selected code to `FFRSAccess/language.txt`. The mod also accepts `auto`; if that file is missing, it tries the current Unreal culture, `LANG`, `LC_ALL`, and then falls back to `de-DE`.

Changes take effect after restarting the game.
