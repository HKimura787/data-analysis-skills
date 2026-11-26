#!/usr/bin/env python3
"""data-analysis-skills PostToolUse hook.

Warnings only (never blocks; the file is already written). Each warning is
returned as additionalContext so it reaches the model, not just the screen.

- H1a/H8 (data-analysis-pipeline principle 8): static check of written code.
  * to_csv( without utf-8-sig -> created CSVs must be UTF-8 with BOM.
  * R write_csv(/write.csv( without write_excel_csv / UTF-8-BOM -> same.
  * read_csv( with encoding="utf-8" (not -sig) -> inputs must be read
    BOM-tolerantly, otherwise the first column name silently gains a BOM.
- H3 (llm-practice rule 6 / pipeline anti-patterns): dropna-like calls are
  legal only with counts and reasons printed. If the project has no audit.md
  yet (pipeline Stage 1 output), the warning is strong: destructive
  preprocessing may be running before profiling.
- H6: a single Write of a very long .py/.R/.sql file earns a soft note
  (early brake against 2,000-line god objects, llm-practice source #8).
- H1b: after a Bash run, newly written *.csv files (outside 00_raw/, .tsv
  excluded) are byte-checked for the BOM. Each (path, mtime) is warned once.

Input: hook JSON on stdin. Output: hook JSON on stdout (or nothing).
Only stdlib is used.
"""
import json
import os
import sys

DROP_PATTERNS = (".dropna(", "na.omit(", "drop_na(", "complete.cases(", "drop_nulls(")
LONG_FILE_LINES = 500
STATE_PATH = os.path.expanduser("~/.cache/das-hooks/state.json")


def emit_context(text):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": text,
        }
    }, ensure_ascii=False))


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def check_code_file(path, cwd):
    warnings = []
    content = read_file(path)
    if not content:
        return warnings
    low = content
    if "to_csv(" in low and "utf-8-sig" not in low:
        warnings.append(
            "H1a: to_csv( がありますが utf-8-sig の指定がありません。"
            "作成するCSVはBOM付きUTF-8が標準です（pipeline 原則8）。"
        )
    if ("write_csv(" in low or "write.csv(" in low) and "write_excel_csv" not in low and "UTF-8-BOM" not in low:
        warnings.append(
            "H1a: write_csv/write.csv がありますが BOM付き出力（write_excel_csv / fileEncoding=\"UTF-8-BOM\"）"
            "になっていません（pipeline 原則8）。"
        )
    if 'encoding="utf-8"' in low or "encoding='utf-8'" in low or 'encoding = "utf-8"' in low:
        warnings.append(
            "H8: encoding=\"utf-8\" で読み込んでいます。入力CSVはBOM付きがありうるので "
            "utf-8-sig で読んでください（pipeline 原則8：入力はBOM耐性で読む）。"
        )
    if any(p in low for p in DROP_PATTERNS):
        if os.path.exists(os.path.join(cwd, "audit.md")):
            warnings.append(
                "H3: 行を落とす処理（dropna等）があります。落とした件数と理由をその場で出力し、"
                "手順書に残してください（pipeline の Anti-patterns）。"
            )
        else:
            warnings.append(
                "H3（強）: 行を落とす処理（dropna等）がありますが、このプロジェクトにはまだ "
                "audit.md（pipeline Stage 1 監査の出力）がありません。プロファイリングより先に "
                "破壊的な前処理をしていないか確認してください（llm-practice 鉄則6：順序の強制）。"
            )
    if path.endswith((".py", ".R", ".sql")) and content.count("\n") + 1 > LONG_FILE_LINES:
        warnings.append(
            "H6: %d 行のファイルを一括で書きました。巨大な単一オブジェクトは設計パターンの"
            "見落としを招きます（llm-practice 出典#8）。分割できないか検討してください。"
            % (content.count("\n") + 1)
        )
    return warnings


def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
    except Exception:
        pass


def check_new_csvs(cwd):
    warnings = []
    state = load_state()
    seen = state.get("csv_mtimes", {})
    changed = False
    for root, dirs, files in os.walk(cwd):
        dirs[:] = [d for d in dirs if d not in (".git", "00_raw", "__pycache__")]
        depth = root[len(cwd):].count(os.sep)
        if depth > 3:
            dirs[:] = []
            continue
        for name in files:
            if not name.lower().endswith(".csv"):
                continue
            path = os.path.join(root, name)
            try:
                mtime = os.path.getmtime(path)
            except Exception:
                continue
            key = path
            if seen.get(key) == mtime:
                continue
            seen[key] = mtime
            changed = True
            try:
                with open(path, "rb") as fh:
                    head = fh.read(3)
            except Exception:
                continue
            if head != b"\xef\xbb\xbf":
                warnings.append(
                    "H1b: %s にBOMがありません。作成CSVはBOM付きUTF-8が標準です"
                    "（pipeline 原則8）。スクリプト側の出力指定（utf-8-sig 等）を直してください。" % path
                )
    if changed:
        state["csv_mtimes"] = seen
        save_state(state)
    return warnings


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input", {}) or {}
    cwd = data.get("cwd") or os.getcwd()
    warnings = []

    if tool in ("Write", "Edit"):
        path = tool_input.get("file_path", "") or ""
        if path.endswith((".py", ".R", ".ipynb", ".sql")):
            warnings += check_code_file(path, cwd)
    elif tool == "Bash":
        warnings += check_new_csvs(cwd)

    if warnings:
        emit_context("data-analysis-skills フック警告:\n- " + "\n- ".join(warnings))
    sys.exit(0)


if __name__ == "__main__":
    main()
