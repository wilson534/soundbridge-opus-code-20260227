#!/usr/bin/env python3

import argparse
import json
from pathlib import Path
from typing import Any


def project_key_from_path(path: Path) -> str:
    return str(path.resolve()).replace("/", "-").replace(" ", "-")


def find_source_dir(explicit: str | None, cwd: Path) -> Path:
    if explicit:
        src = Path(explicit).expanduser()
        if not src.is_dir():
            raise FileNotFoundError(f"source dir not found: {src}")
        return src

    claude_projects = Path.home() / ".claude" / "projects"
    expected = claude_projects / project_key_from_path(cwd)
    if expected.is_dir():
        return expected

    name_hint = cwd.name.lower().split()[0]
    candidates = [p for p in claude_projects.iterdir() if p.is_dir() and name_hint in p.name.lower()]
    if not candidates:
        raise FileNotFoundError(
            f"no matching Claude project dir found under {claude_projects}; "
            "pass --source-dir explicitly"
        )
    return max(candidates, key=lambda p: p.stat().st_mtime)


def extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""

    chunks: list[str] = []
    for item in content:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                chunks.append(text.strip())
    return "\n\n".join(chunks).strip()


def parse_session(path: Path) -> dict[str, Any]:
    messages: list[dict[str, str]] = []
    session_summary = ""
    source_cwd = ""
    first_ts = ""
    last_ts = ""
    bad_lines = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                bad_lines += 1
                continue

            ts = obj.get("timestamp")
            if isinstance(ts, str):
                if not first_ts:
                    first_ts = ts
                last_ts = ts

            cwd = obj.get("cwd")
            if isinstance(cwd, str) and cwd and not source_cwd:
                source_cwd = cwd

            if obj.get("type") == "summary" and isinstance(obj.get("summary"), str):
                if not session_summary:
                    session_summary = obj["summary"].strip()

            if obj.get("type") not in {"user", "assistant"}:
                continue

            message = obj.get("message")
            if not isinstance(message, dict):
                continue

            role = message.get("role")
            if role not in {"user", "assistant"}:
                continue

            text = extract_text(message.get("content"))
            if not text:
                continue

            messages.append(
                {
                    "timestamp": ts if isinstance(ts, str) else "",
                    "role": role,
                    "text": text,
                }
            )

    return {
        "session_id": path.stem,
        "source_file": str(path),
        "source_cwd": source_cwd,
        "summary": session_summary,
        "first_timestamp": first_ts,
        "last_timestamp": last_ts,
        "message_count": len(messages),
        "messages": messages,
        "bad_lines": bad_lines,
        "source_bytes": path.stat().st_size,
    }


def write_markdown(session: dict[str, Any], out_file: Path) -> None:
    lines = [
        f"# Claude Session {session['session_id']}",
        "",
        f"- Source file: `{session['source_file']}`",
        f"- Source cwd: `{session['source_cwd'] or 'N/A'}`",
        f"- First timestamp: `{session['first_timestamp'] or 'N/A'}`",
        f"- Last timestamp: `{session['last_timestamp'] or 'N/A'}`",
        f"- Summary: `{session['summary'] or 'N/A'}`",
        f"- Extracted messages: `{session['message_count']}`",
        "",
    ]

    for m in session["messages"]:
        ts = m["timestamp"] or "N/A"
        lines.append(f"## {m['role'].upper()} [{ts}]")
        lines.append("")
        lines.append(m["text"])
        lines.append("")

    out_file.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Migrate Claude JSONL sessions into readable markdown transcripts.")
    parser.add_argument(
        "--source-dir",
        default=None,
        help="Claude project directory (default: auto-detect from current cwd under ~/.claude/projects)",
    )
    parser.add_argument(
        "--output-dir",
        default="migration/claude-history",
        help="Output directory inside this project",
    )
    args = parser.parse_args()

    cwd = Path.cwd()
    source_dir = find_source_dir(args.source_dir, cwd)
    output_dir = Path(args.output_dir)
    transcripts_dir = output_dir / "transcripts"
    transcripts_dir.mkdir(parents=True, exist_ok=True)

    session_files = sorted(source_dir.glob("*.jsonl"))
    if not session_files:
        raise FileNotFoundError(f"no .jsonl sessions found under: {source_dir}")

    sessions = [parse_session(p) for p in session_files]
    sessions.sort(key=lambda s: (s["last_timestamp"] or "", s["session_id"]))

    for s in sessions:
        write_markdown(s, transcripts_dir / f"{s['session_id']}.md")

    index_payload = {
        "source_dir": str(source_dir),
        "output_dir": str(output_dir.resolve()),
        "session_count": len(sessions),
        "total_messages": sum(s["message_count"] for s in sessions),
        "sessions": [
            {
                "session_id": s["session_id"],
                "source_file": s["source_file"],
                "source_cwd": s["source_cwd"],
                "summary": s["summary"],
                "first_timestamp": s["first_timestamp"],
                "last_timestamp": s["last_timestamp"],
                "message_count": s["message_count"],
                "source_bytes": s["source_bytes"],
                "bad_lines": s["bad_lines"],
                "transcript_file": str((transcripts_dir / f"{s['session_id']}.md").resolve()),
            }
            for s in sessions
        ],
    }
    (output_dir / "sessions_index.json").write_text(
        json.dumps(index_payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    readme = "\n".join(
        [
            "# Claude Sessions Migration",
            "",
            f"- Source: `{source_dir}`",
            f"- Sessions migrated: `{len(sessions)}`",
            f"- Extracted messages: `{index_payload['total_messages']}`",
            "",
            "## Output",
            f"- `sessions_index.json`: metadata index",
            "- `transcripts/*.md`: per-session readable transcript (user/assistant text only)",
            "",
            "## Re-run",
            "```bash",
            "python3 scripts/migrate_claude_sessions.py",
            "```",
        ]
    )
    (output_dir / "README.md").write_text(readme, encoding="utf-8")

    print(
        json.dumps(
            {
                "source_dir": str(source_dir),
                "output_dir": str(output_dir.resolve()),
                "session_count": len(sessions),
                "total_messages": index_payload["total_messages"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
