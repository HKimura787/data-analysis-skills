#!/usr/bin/env python3
"""data-analysis-skills PreToolUse hook.

Enforces, mechanically, rules from the three skills:
- H2 (data-analysis-pipeline principle 1): never overwrite raw data.
  Write/Edit to an EXISTING file under a 00_raw/ directory is denied.
  New files are allowed (the initial copy into 00_raw/ is a required step).
  Bash commands that look like they write into 00_raw/ are surfaced as "ask".
- H6 (pipeline principle 5): generated logs (decision_log.md, procedure.md,
  audit.md) must be produced by the script, never hand-typed. Hand edits via
  Write/Edit are surfaced as "ask".
- H7 (data-analysis-llm-practice step 3): long code/SQL should be written to
  a file so a human can read it, not buried in a Bash one-liner. Long inline
  code in Bash only earns a context note (never a denial).

Input: hook JSON on stdin. Output: hook JSON on stdout (or nothing = allow).
Only stdlib is used.
"""
import json
import os
import re
import sys

GENERATED_LOGS = {"decision_log.md", "procedure.md", "audit.md"}
RAW_SEGMENT = "/00_raw/"
WRITE_VERBS = re.compile(r"(>>?\s*\S*00_raw|sed\s+-i|tee\s|truncate\s|mv\s|rm\s)")


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))


def decision(decision_value, reason):
    emit({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision_value,
            "permissionDecisionReason": reason,
        }
    })
    sys.exit(0)


def context_note(text):
    emit({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": text,
        }
    })
    sys.exit(0)


def is_raw_path(path):
    norm = path.replace("\\", "/")
    return RAW_SEGMENT in norm or norm.startswith("00_raw/") or "/00_raw" in norm


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input", {}) or {}

    if tool in ("Write", "Edit", "NotebookEdit"):
        path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if path and is_raw_path(path):
            if os.path.exists(path):
                decision(
                    "deny",
                    "data-analysis-skills H2: 既存の生データ (%s) への上書きは禁止です"
                    "（data-analysis-pipeline 原則1「生データは絶対に上書きしない」）。"
                    "新しいファイル名で書き出すか、00_raw/ の外に出力してください。" % path,
                )
            sys.exit(0)  # new file in 00_raw/ = the initial copy; allowed
        if os.path.basename(path) in GENERATED_LOGS:
            decision(
                "ask",
                "data-analysis-skills H6: %s はスクリプトが生成する成果物です"
                "（pipeline 原則5：台帳の値はスクリプトが計算したものだけを書く）。"
                "手編集ではなく、スクリプトを直して再実行することを検討してください。" % path,
            )
        sys.exit(0)

    if tool == "Bash":
        cmd = tool_input.get("command", "") or ""
        if "00_raw" in cmd:
            if re.search(r"\bcp\b", cmd):
                # cp INTO 00_raw/ is the required initial copy; only ask when
                # it would overwrite an existing file there.
                import shlex
                try:
                    parts = shlex.split(cmd)
                except Exception:
                    parts = cmd.split()
                if "cp" in parts:
                    args = [p for p in parts[parts.index("cp") + 1:] if not p.startswith("-")]
                    if len(args) >= 2:
                        dest = args[-1]
                        if "00_raw" in dest:
                            for src in args[:-1]:
                                target = os.path.join(dest, os.path.basename(src)) if os.path.isdir(dest) else dest
                                if os.path.exists(target):
                                    decision(
                                        "ask",
                                        "data-analysis-skills H2: 00_raw/ 内の既存ファイル %s を "
                                        "cp で上書きしようとしています。生データの上書きでないか確認してください。" % target,
                                    )
                            sys.exit(0)  # fresh copy into 00_raw/; allowed
            if WRITE_VERBS.search(cmd):
                decision(
                    "ask",
                    "data-analysis-skills H2: 00_raw/ への書き込みに見えるコマンドです。"
                    "生データの上書きでないか確認してください（読み取りや初回コピーは問題ありません）。",
                )
        # H7: long inline code / SQL in Bash -> suggest writing it to a file.
        if re.search(r"(python3?\s+-c|python3?\s+-?\s*<<|psql\s+.*-c|sqlite3\s+\S+\s+\")", cmd) and len(cmd) > 300:
            context_note(
                "data-analysis-skills H7: 長いコード/SQL を Bash に直接書いています。"
                "data-analysis-llm-practice 手順3のとおり、人が読めるようファイルに出力してから実行してください。"
            )
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
