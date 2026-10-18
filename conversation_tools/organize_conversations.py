#!/usr/bin/env python3
"""Sort Claude conversations into groups and build a browsable index.

Sources:
  claude.ai   the data export (Settings > Privacy > Export data): the .zip, or
              the conversations.json inside it
  Claude Code session transcripts in ~/.claude/projects (--claude-code)

Grouping, in priority order:
  1. overrides.json   {"<conversation id>": "Group"}  - your manual fixes, always win
  2. rules.json       {"Group": ["keyword", ...]}     - matched against title + opening text
  3. --auto           Claude suggests a group for anything still unmatched
                      (needs ANTHROPIC_API_KEY)
  4. "Unsorted"

Output (--out, default ./organized):
  index.html          grouped, searchable list linking back to each chat
  groups.json         id -> group for every conversation (copy lines into overrides.json to pin them)
  <Group>/<title>.md  full transcript of each conversation

Standard library only. Examples:
  python organize_conversations.py data-2026-10-18.zip
  python organize_conversations.py conversations.json --auto
  python organize_conversations.py --claude-code --rules my_rules.json
"""
import argparse
import html
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNSORTED = "Unsorted"
SNIPPET_CHARS = 600
AUTO_MODEL = "claude-haiku-5-5"
AUTO_BATCH = 100


# ---------- loading ----------

def _text_of(content):
    """Flatten a message's content (string or list of blocks) to plain text."""
    if isinstance(content, str):
        return content
    parts = []
    for block in content or []:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(parts)


def load_claude_ai(path):
    path = Path(path)
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist() if n.endswith("conversations.json"))
            raw = json.loads(z.read(name))
    else:
        raw = json.loads(path.read_text(encoding="utf-8"))

    convos = []
    for c in raw:
        messages = []
        for m in c.get("chat_messages", []):
            text = m.get("text") or _text_of(m.get("content"))
            if text.strip():
                messages.append({"role": "user" if m.get("sender") == "human" else "assistant", "text": text})
        convos.append({
            "id": c["uuid"],
            "title": c.get("name") or "(untitled)",
            "created": c.get("created_at", ""),
            "updated": c.get("updated_at", ""),
            "url": f"https://claude.ai/chat/{c['uuid']}",
            "messages": messages,
        })
    return convos


def load_claude_code(root):
    convos = []
    for f in sorted(Path(root).expanduser().glob("*/*.jsonl")):
        messages, title, cwd, times = [], None, "", []
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("type") == "summary" and not title:
                title = e.get("summary")
            if e.get("type") not in ("user", "assistant") or e.get("isMeta"):
                continue
            cwd = cwd or e.get("cwd", "")
            if e.get("timestamp"):
                times.append(e["timestamp"])
            text = _text_of((e.get("message") or {}).get("content"))
            if text.strip() and not text.lstrip().startswith("<"):  # skip command/system wrappers
                messages.append({"role": e["type"], "text": text})
        if not messages:
            continue
        first_user = next((m["text"] for m in messages if m["role"] == "user"), "")
        convos.append({
            "id": f.stem,
            "title": title or first_user.strip().splitlines()[0][:80] or f.stem,
            "created": min(times) if times else "",
            "updated": max(times) if times else "",
            "url": "",
            "project": cwd or f.parent.name,
            "messages": messages,
        })
    return convos


# ---------- grouping ----------

def snippet(c):
    opening = "\n".join(m["text"] for m in c["messages"][:2])
    return f"{c['title']}\n{opening}"[:SNIPPET_CHARS]


def apply_rules(convos, rules, assigned):
    compiled = {g: [re.compile(rf"(?<!\w){re.escape(k)}(?!\w)", re.I) for k in kws] for g, kws in rules.items()}
    for c in convos:
        if c["id"] in assigned:
            continue
        text = snippet(c)
        # The group with the most keyword hits wins; ties go to the earlier group in the file.
        best, best_hits = None, 0
        for group, patterns in compiled.items():
            hits = sum(1 for p in patterns if p.search(text))
            if hits > best_hits:
                best, best_hits = group, hits
        if best:
            assigned[c["id"]] = best


def call_claude(prompt, api_key):
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=json.dumps({
            "model": AUTO_MODEL,
            "max_tokens": 8000,
            "messages": [{"role": "user", "content": prompt}],
        }).encode(),
        headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        body = json.load(r)
    return "".join(b.get("text", "") for b in body["content"] if b["type"] == "text")


def apply_auto(convos, assigned, known_groups):
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.exit("--auto needs the ANTHROPIC_API_KEY environment variable.")
    todo = [c for c in convos if c["id"] not in assigned]
    groups = list(known_groups)
    for i in range(0, len(todo), AUTO_BATCH):
        batch = todo[i:i + AUTO_BATCH]
        print(f"  auto-grouping {i + 1}-{i + len(batch)} of {len(todo)}...", file=sys.stderr)
        items = "\n".join(f"[{n}] {snippet(c)[:300]!r}" for n, c in enumerate(batch))
        prompt = (
            "Sort these chat conversations into topic groups. Reuse an existing group whenever one fits; "
            "otherwise create a short, broad group name (1-3 words, Title Case). Aim for roughly 5-15 groups "
            "overall, not one per conversation.\n\n"
            f"Existing groups: {json.dumps(groups)}\n\n"
            f"Conversations (index, then title and opening text):\n{items}\n\n"
            'Reply with only a JSON object mapping each index to a group, like {"0": "Cooking", "1": "Work"}.'
        )
        reply = call_claude(prompt, api_key)
        match = re.search(r"\{.*\}", reply, re.S)
        mapping = json.loads(match.group(0)) if match else {}
        for n, c in enumerate(batch):
            group = str(mapping.get(str(n), "")).strip()
            if group:
                assigned[c["id"]] = group
                if group not in groups:
                    groups.append(group)


# ---------- output ----------

def safe_name(s, limit=80):
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", s).strip(" .")
    return (s[:limit] or "untitled").rstrip(" .")


def write_markdown(c, path):
    lines = [f"# {c['title']}", ""]
    meta = [f"- Created: {c['created'][:10]}", f"- Updated: {c['updated'][:10]}"]
    if c["url"]:
        meta.append(f"- Link: {c['url']}")
    if c.get("project"):
        meta.append(f"- Project: {c['project']}")
    lines += meta + [""]
    for m in c["messages"]:
        lines += [f"## {'You' if m['role'] == 'user' else 'Claude'}", "", m["text"], ""]
    path.write_text("\n".join(lines), encoding="utf-8")


INDEX_TEMPLATE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Conversations</title>
<style>
:root{{--bg:#faf9f5;--fg:#1f1e1d;--muted:#6b6a65;--line:#e5e3dc;--accent:#c96442;--card:#fff}}
@media (prefers-color-scheme:dark){{:root{{--bg:#1f1e1d;--fg:#eceae4;--muted:#a3a19a;--line:#3a3936;--accent:#e08a6a;--card:#2a2927}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}}
main{{max-width:880px;margin:0 auto;padding:24px 16px}}
h1{{font-size:22px;margin:0 0 4px}} .sub{{color:var(--muted);margin:0 0 16px}}
input{{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg);font:inherit}}
details{{background:var(--card);border:1px solid var(--line);border-radius:10px;margin:12px 0;padding:4px 14px}}
summary{{cursor:pointer;font-weight:600;padding:8px 0}} summary span{{color:var(--muted);font-weight:400}}
ul{{list-style:none;margin:0;padding:0 0 8px}} li{{display:flex;gap:12px;justify-content:space-between;padding:6px 0;border-top:1px solid var(--line)}}
a{{color:var(--accent);text-decoration:none}} a:hover{{text-decoration:underline}}
.meta{{color:var(--muted);font-size:13px;white-space:nowrap}} .hidden{{display:none}}
</style></head><body><main>
<h1>Claude Conversations</h1>
<p class="sub">{total} conversations in {ngroups} groups</p>
<input id="q" type="search" placeholder="Filter by title or group..." autofocus>
{sections}
</main><script>
const q=document.getElementById('q');
q.addEventListener('input',()=>{{const t=q.value.toLowerCase();
document.querySelectorAll('details').forEach(d=>{{const g=d.dataset.group.includes(t);let n=0;
d.querySelectorAll('li').forEach(li=>{{const show=g||li.dataset.title.includes(t);li.classList.toggle('hidden',!show);if(show)n++;}});
d.classList.toggle('hidden',n===0);if(t)d.open=true;}});}});
</script></body></html>
"""


def write_index(by_group, out):
    sections = []
    for group, items in by_group:
        rows = []
        for c, md in items:
            link = c["url"] or md
            extra = f" · {html.escape(Path(c['project']).name)}" if c.get("project") else ""
            rows.append(
                f'<li data-title="{html.escape(c["title"].lower())}">'
                f'<span><a href="{html.escape(link)}">{html.escape(c["title"])}</a> '
                f'<a class="meta" href="{html.escape(md)}">(transcript)</a></span>'
                f'<span class="meta">{c["updated"][:10]}{extra}</span></li>'
            )
        sections.append(
            f'<details open data-group="{html.escape(group.lower())}"><summary>{html.escape(group)} '
            f'<span>({len(items)})</span></summary><ul>{"".join(rows)}</ul></details>'
        )
    total = sum(len(i) for _, i in by_group)
    (out / "index.html").write_text(
        INDEX_TEMPLATE.format(total=total, ngroups=len(by_group), sections="\n".join(sections)), encoding="utf-8")


# ---------- main ----------

def read_json(path, default):
    path = Path(path)
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else default


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", nargs="?", help="claude.ai export .zip or conversations.json")
    ap.add_argument("--claude-code", nargs="?", const="~/.claude/projects", metavar="DIR",
                    help="read Claude Code sessions instead (default ~/.claude/projects)")
    ap.add_argument("--rules", default=HERE / "rules.json", help="keyword rules (default: rules.json beside this script)")
    ap.add_argument("--overrides", default=HERE / "overrides.json", help="manual id -> group pins")
    ap.add_argument("--auto", action="store_true", help="ask Claude to group anything the rules miss")
    ap.add_argument("--reuse", action="store_true",
                    help="keep groups from the previous run's groups.json (no repeat --auto cost)")
    ap.add_argument("--out", default="organized", help="output folder (default ./organized)")
    args = ap.parse_args()

    if bool(args.export) == bool(args.claude_code):
        ap.error("give either an export file or --claude-code")
    convos = load_claude_code(args.claude_code) if args.claude_code else load_claude_ai(args.export)
    print(f"Loaded {len(convos)} conversations.", file=sys.stderr)

    out = Path(args.out)
    rules = read_json(args.rules, {})
    assigned = dict(read_json(args.overrides, {}))
    if args.reuse:
        for cid, group in read_json(out / "groups.json", {}).items():
            assigned.setdefault(cid, group)
    apply_rules(convos, rules, assigned)
    if args.auto:
        apply_auto(convos, assigned, list(rules) + sorted(set(assigned.values())))

    grouped = {}
    for c in convos:
        grouped.setdefault(assigned.get(c["id"], UNSORTED), []).append(c)

    out.mkdir(parents=True, exist_ok=True)
    by_group = []
    for group in sorted(grouped, key=lambda g: (g == UNSORTED, g.lower())):
        folder = out / safe_name(group)
        folder.mkdir(exist_ok=True)
        items, used = [], set()
        for c in sorted(grouped[group], key=lambda c: c["updated"], reverse=True):
            name = safe_name(c["title"])
            if name.lower() in used:
                name = f"{name} ({c['id'][:8]})"
            used.add(name.lower())
            write_markdown(c, folder / f"{name}.md")
            items.append((c, urllib.parse.quote(f"{folder.name}/{name}.md")))
        by_group.append((group, items))

    (out / "groups.json").write_text(
        json.dumps({c["id"]: assigned.get(c["id"], UNSORTED) for c in convos}, indent=2), encoding="utf-8")
    write_index(by_group, out)

    for group, items in by_group:
        print(f"  {group:<30} {len(items)}", file=sys.stderr)
    print(f"Open {out.resolve() / 'index.html'}", file=sys.stderr)


if __name__ == "__main__":
    main()
