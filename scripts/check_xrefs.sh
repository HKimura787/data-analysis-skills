#!/usr/bin/env bash
# check_xrefs.sh — 3スキル間の相互参照が実在するか grep で確かめる。
# llm-practice は check の節名と pipeline の Stage 番号に依存している。
# 参照先を改名・並べ替えしたら、このスクリプトが落ちることで気づける。
# 使い方: リポジトリのルートで bash scripts/check_xrefs.sh
set -u
cd "$(dirname "$0")/.."
fail=0

check() { # check <file> <pattern> <label>
  if grep -qF -- "$2" "$1"; then
    echo "OK   $3"
  else
    echo "NG   $3  -- not found in $1: $2"
    fail=1
  fi
}

CHECK=data-analysis-check/SKILL.md
PIPE=data-analysis-pipeline/SKILL.md
LLM=data-analysis-llm-practice/SKILL.md

# llm-practice -> check
check "$CHECK" "## ゼロベース再実装チェック" "llm-practice -> check: ゼロベース再実装チェック節"
check "$CHECK" "## 手順2：集計後に検証表を出す" "llm-practice -> check: 検証表（手順2）"
check "$CHECK" "別AI照合と真値テスト" "llm-practice -> check: 項目11（真値テスト）"
# llm-practice -> pipeline
check "$PIPE" "## Stage 0" "llm-practice -> pipeline: Stage 0（grain）"
check "$PIPE" "## Stage 1 — Audit" "llm-practice -> pipeline: Stage 1 監査"
check "$PIPE" "## Stage 6 — Verification" "llm-practice -> pipeline: Stage 6"
check "$PIPE" "Zero-base re-implementation" "llm-practice -> pipeline: Stage 6 内のゼロベース再実装"
# pipeline -> check
check "$PIPE" "data-analysis-check" "pipeline -> check: スキル名の言及"
# llm-practice 自身の内部参照
check "$LLM" "scripts/collate.sh" "llm-practice: collate.sh への言及"

if [ "$fail" -eq 0 ]; then
  echo "相互参照チェック: すべて一致"
else
  echo "相互参照チェック: 不一致あり" >&2
fi
exit "$fail"
