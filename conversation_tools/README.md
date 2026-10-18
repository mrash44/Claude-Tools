# Claude conversation organizer

Sorts your Claude conversations into groups and builds a searchable `index.html` that links back to each chat, plus a Markdown transcript of each one in a folder per group.

The script runs only on your machine. It cannot rearrange the claude.ai sidebar, because claude.ai has no API for that. It reads your data export instead.

## Use

1. Get your data: claude.ai → Settings → Privacy → **Export data**. The download link arrives by email.
2. Run (Python 3.9+, no installs needed — `winget install Python.Python.3.12` if you don't have it):

```powershell
python organize_conversations.py $HOME\Downloads\data-2026-10-18.zip
start organized\index.html
```

For Claude Code sessions instead: `python organize_conversations.py --claude-code`

## How groups are chosen

1. **`overrides.json`**: `{"<conversation id>": "Group"}`. These always win. Copy lines from `organized/groups.json` and edit the group names to pin or fix conversations.
2. **`rules.json`**: `{"Group": ["keyword", ...]}`, matched against each conversation's title and opening messages. The group with the most keyword hits wins. Edit it to suit your own topics.
3. **`--auto`**: Claude (Haiku) suggests a group for anything still unmatched. It reuses your rule names where they fit. This needs `$env:ANTHROPIC_API_KEY` and sends each unmatched conversation's title and opening ~300 characters to the API. Add `--reuse` on later runs to keep the previous results without paying again.
4. Anything left over goes to **Unsorted**.

`--out DIR` changes the output folder (default `./organized`).

> The `organized/` output contains your full conversation text. Don't commit it. This repo's `.gitignore` already ignores it.
