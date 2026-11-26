#!/usr/bin/env bash
# run_tests.sh — フックの発火／非発火テスト。
# 「発火すべき入力」と「発火してはいけない入力」の両方を確かめる。
set -u
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRE="$HOOKS_DIR/das_pre_tool_use.py"
POST="$HOOKS_DIR/das_post_tool_use.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

expect_contains() { # $1=label $2=output $3=needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    echo "PASS $1"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected to contain: $3; got: $2)"; fail=$((fail + 1))
  fi
}
expect_empty() { # $1=label $2=output
  if [ -z "$2" ]; then
    echo "PASS $1"; pass=$((pass + 1))
  else
    echo "FAIL $1 (expected no output; got: $2)"; fail=$((fail + 1))
  fi
}
run_pre() { printf '%s' "$1" | python3 "$PRE"; }
run_post() { printf '%s' "$1" | python3 "$POST"; }

# --- 準備 ---
mkdir -p "$WORK/proj/00_raw"
echo "a,b" > "$WORK/proj/00_raw/raw.csv"

# --- PreToolUse ---
out="$(run_pre "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/00_raw/raw.csv\",\"content\":\"x\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H2 deny: 既存の生データをWrite" "$out" '"permissionDecision": "deny"'

out="$(run_pre "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/00_raw/new.csv\",\"content\":\"x\"},\"cwd\":\"$WORK/proj\"}")"
expect_empty "H2 allow: 00_raw への新規作成（初回コピー）" "$out"

out="$(run_pre "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/decision_log.md\",\"content\":\"x\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H6 ask: 生成物の手編集" "$out" '"permissionDecision": "ask"'

out="$(run_pre "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat 00_raw/raw.csv\"},\"cwd\":\"$WORK/proj\"}")"
expect_empty "H2 allow: 00_raw の読み取り" "$out"

out="$(run_pre "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/a/b/ 00_raw/raw.csv\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H2 ask: sed -i で生データを編集" "$out" '"permissionDecision": "ask"'

out="$(run_pre "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cp $WORK/proj/00_raw/raw.csv $WORK/proj/copy.csv\"},\"cwd\":\"$WORK/proj\"}")"
expect_empty "H2 allow: 00_raw から外へのコピー" "$out"

long_py="$(python3 -c "print('x' * 320)")"
out="$(run_pre "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"python3 -c \\\"$long_py\\\"\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H7 note: 長いインラインコード" "$out" "additionalContext"

# --- PostToolUse ---
cat > "$WORK/proj/bad.py" <<'EOF'
import pandas as pd
df = pd.read_csv("in.csv", encoding="utf-8")
df = df.dropna()
df.to_csv("out.csv")
EOF
out="$(run_post "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/bad.py\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H1a: to_csv に utf-8-sig が無い" "$out" "H1a"
expect_contains "H8: read_csv が utf-8" "$out" "H8"
expect_contains "H3強: audit.md 無しで dropna" "$out" "H3（強）"

echo "# audit" > "$WORK/proj/audit.md"
out="$(run_post "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/bad.py\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H3弱: audit.md 有りで dropna" "$out" "H3: 行を落とす処理"

cat > "$WORK/proj/good.py" <<'EOF'
import pandas as pd
df = pd.read_csv("in.csv", encoding="utf-8-sig")
df.to_csv("out.csv", encoding="utf-8-sig")
EOF
out="$(run_post "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/good.py\"},\"cwd\":\"$WORK/proj\"}")"
expect_empty "正常なコードには警告しない" "$out"

python3 -c "print('x = 1\n' * 600, end='')" > "$WORK/proj/long.py"
out="$(run_post "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$WORK/proj/long.py\"},\"cwd\":\"$WORK/proj\"}")"
expect_contains "H6: 500行超の一括書き込み" "$out" "H6"

# --- H1b: Bash 後の CSV バイト検査 ---
mkdir -p "$WORK/bashtest"
printf 'a,b\n1,2\n' > "$WORK/bashtest/nobom.csv"
printf '\xef\xbb\xbfa,b\n1,2\n' > "$WORK/bashtest/withbom.csv"
printf 'a,b\n1,2\n' > "$WORK/bashtest/data.tsv"
out="$(run_post "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true\"},\"cwd\":\"$WORK/bashtest\"}")"
expect_contains "H1b: BOM無しCSVを検出" "$out" "nobom.csv"
if printf '%s' "$out" | grep -qF "withbom.csv"; then
  echo "FAIL H1b: BOM付きCSVに警告した"; fail=$((fail + 1))
else
  echo "PASS H1b: BOM付きCSVは警告しない"; pass=$((pass + 1))
fi
if printf '%s' "$out" | grep -qF "data.tsv"; then
  echo "FAIL H1b: TSVに警告した"; fail=$((fail + 1))
else
  echo "PASS H1b: TSVは対象外"; pass=$((pass + 1))
fi
out="$(run_post "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true\"},\"cwd\":\"$WORK/bashtest\"}")"
expect_empty "H1b: 同じファイルには再警告しない" "$out"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
