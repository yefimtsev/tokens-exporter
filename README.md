# tokens-exporter

Converts Figma design token JSON files into compact YAML or Markdown — sized for LLM context windows, not human eyeballs.

Feed it one or more `.tokens.json` exports and get back a stripped-down representation with only the categories you care about. Multiple files are merged as named themes.

## Install

**Mint** (recommended):

```
mint install yefimtsev/tokens-exporter
```

**From source:**

```
make install          # installs to ~/.local/bin
PREFIX=/usr/local make install
```

## Usage

```
# list what's inside a token file
tokens-exporter Light.tokens.json --list

# export specific categories as YAML
tokens-exporter Light.tokens.json -c color -c spacing

# export everything, strip constant fields
tokens-exporter Light.tokens.json --all --compact

# merge light + dark themes into one file
tokens-exporter Light.tokens.json Dark.tokens.json --all -o tokens.yaml

# markdown output
tokens-exporter Light.tokens.json --all -f md
```

## Options

| Flag | What it does |
|------|-------------|
| `--list` | Print available categories with token counts |
| `-c, --category` | Pick categories to export (repeatable) |
| `--all` | Export every category |
| `--compact` | Detect and strip fields that are constant across all tokens |
| `-f, --format` | `yaml` (default) or `md` |
| `-o, --output` | Write to file instead of stdout |

## Why

Design token JSON files are bloated with metadata, extensions, and nested structures that burn through LLM tokens for no reason. This tool strips all of that down to the actual values — names, colors, sizes — in a format an LLM can parse without wasting half its context window on `$extensions` blocks.
