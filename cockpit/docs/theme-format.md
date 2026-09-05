# Cockpit theme format (`cockpit-theme-1`)

A theme is **one JSON file**. It paints all three layers at once: the app UI,
the code-viewer syntax highlight, and the terminal palette.

- Import: Settings → Appearance → Theme → **Import…**
- Folder is `<data folder>/themes/` (same root as "Storage"), one file per
  theme, named by `id`. Copying a `.json` there also installs it.
- Export writes a **complete** file (every token, no `extends`): a starting
  point for hand-editing.

## Structure

```json
{
  "$schema": "https://raw.githubusercontent.com/jacobaraujo7/remote_pi/main/cockpit/docs/theme.schema.json",
  "id": "acme.aurora",
  "name": "Aurora",
  "author": "Acme",
  "version": "1.0.0",
  "extends": "cockpit",
  "variants": {
    "dark":  { "ui": {}, "syntax": {}, "terminal": {} },
    "light": { "ui": {}, "syntax": {}, "terminal": {} }
  }
}
```

| Field | Required | What |
|---|---|---|
| `id` | yes | Stable namespaced identity (`publisher.name`). This is what preferences store — renaming `name` does not lose the user's choice. Must not collide with a built-in (`cockpit`, `cockpit.2`, `violet`, `violet.2`, `midnight`, `rose`, `sun`, `flexoki`, `pantera`). |
| `name` | yes | What appears in the picker. |
| `author`, `version` | no | Metadata. |
| `extends` | no | Id of a built-in theme to inherit from. Today: `cockpit`, `cockpit.2`, `violet`, `violet.2`, `midnight`, `rose`, `sun`, `flexoki`, and `pantera`. Absent = inherit from `cockpit`. |
| `variants` | yes | At least one of `dark` / `light`. |

**Inheritance is the point.** Every undeclared token comes from the base, so a
useful theme can be five lines. A theme with only `dark` is also applied in
light mode (better than mixing half-light with half-dark).

## Colors

CSS-style hex: `#RGB`, `#RRGGBB`, or `#RRGGBBAA` — **alpha at the end**. Not
Dart's `0xAARRGGBB`.

## Tokens

### `ui` (25) — the interface

| Group | Tokens |
|---|---|
| Surfaces | `bg` (deepest background) · `panel` (pane/rail) · `panel2` (elevated: composer, cards) · `panel3` (hover / inline code) |
| Strokes | `border` (hairline) · `border2` (strong divider) |
| Text | `text` (primary) · `text2` (secondary) · `text3` (tertiary/placeholder) · `text4` (weak, idle icon) |
| Brand | `accent` · `accentSoft` (selection background, translucent) · `accentText` (text in the brand color) |
| State | `online` · `ok` · `error` · `warn` |
| Editing | `edited` · `editedBg` |
| Git | `gitStaged` · `gitUntracked` · `gitDeleted` · `gitConflict` |
| Overlay | `scrim` (dialog backdrop, translucent) · `shadow` (drop shadow) |

> Text **on** `accent` and `error` is not a token: it is derived from the color
> luminance. A light accent automatically gets dark text.

### `syntax` (12) — code highlighting

`background` · `base` · `comment` · `keyword` · `string` · `number` · `class` ·
`builtin` · `function` · `variable` · `meta` · `deletion`

> **`background` has a special default.** The code viewer, editor, and terminal
> are content inside the tab, so the three share the field: when the theme
> **does not** declare `syntax.background` (nor `terminal.background`), they
> follow **this** theme's `ui.panel` — not the base. Declare the field to
> escape that, if the code palette needs its own background.

### `terminal` (23) — the ANSI palette

`cursor` · `selection` · `foreground` · `background`, the 8 normal colors
(`black` `red` `green` `yellow` `blue` `magenta` `cyan` `white`), the matching
8 `bright*`, and `searchHitBackground` · `searchHitBackgroundCurrent` ·
`searchHitForeground`.

## Minimal real example

Swap only the brand and keep everything else from the native theme:

```json
{
  "$schema": "https://raw.githubusercontent.com/jacobaraujo7/remote_pi/main/cockpit/docs/theme.schema.json",
  "id": "acme.violet",
  "name": "Violet",
  "variants": {
    "dark":  { "ui": { "accent": "#8B5CF6", "accentSoft": "#8B5CF633", "accentText": "#C4B5FD" } },
    "light": { "ui": { "accent": "#7C3AED", "accentSoft": "#7C3AED22", "accentText": "#5B21B6" } }
  }
}
```

See [`theme.example.json`](./theme.example.json) for a commented file with
every group filled in.

## `$schema`

The schema lives **in the repository**, not on our own domain:

```
https://raw.githubusercontent.com/jacobaraujo7/remote_pi/main/cockpit/docs/theme.schema.json
```

Versioned with the code that implements it, so the site never serves one
version while the app understands another. Pinned to `main` on purpose: theme
authors want autocomplete for the current format.

Unlike `tasks.json` (which lives in the repo and can use a relative path), a
theme lives in an arbitrary data folder and is copied between machines — hence
the absolute URL.

The app **ignores** `$schema` when reading the theme; the field is only for the
editor. CI catches drift: `test/ui/theme_codec_test.dart` compares schema
tokens with what the codec serializes, the `extends` enum with registered
built-ins, and validates `theme.example.json` in this directory.

## Import errors

The parser points at the **field path** that broke (`variants.dark.ui.accent`),
so the diagnosis is never a bare "invalid file". An invalid file never reaches
the themes folder: validation runs before the copy.
