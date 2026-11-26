#!/usr/bin/env bash
# collate.sh — data-analysis-llm-practice の機械的照合 C1〜C3 をまとめて実行する。
#
# 使い方: collate.sh <元ファイル> <一覧TSV>
#   一覧TSVの形式: 行番号<TAB>字句<TAB>説明（3列目以降は任意）
#
# やること:
#   C1 元ファイルを一時退避し、sha256 を記録する
#   C2 一覧の各字句が、元ファイルのその行に実在するかを1件ずつ照合する
#   C3 終了時に sha256 を再計算し、元ファイルが変わっていないことを確かめる
# 件数台帳（入力行数 = OK + NG）を最後に出し、NG があれば exit 1。
#
# 注意（SKILL.md と同じ限界）: これは「一覧に載ったものが実在するか」
# （誤検出）しか確かめられない。載らなかったもの（見落とし）は検出できない。
#
# 素の C2 ループの弱点への対策:
#   - 一覧TSV先頭の BOM と CRLF の CR を除去する（偽のNG防止）
#   - 行番号が数値でない行・空行は NG として数える（黙って飛ばさない）
#   - 最終行に改行が無くても処理する
set -u

if [ $# -ne 2 ]; then
  echo "usage: collate.sh <source_file> <list.tsv>" >&2
  exit 2
fi
SRC="$1"
LIST="$2"
[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 2; }
[ -f "$LIST" ] || { echo "list not found: $LIST" >&2; exit 2; }

# C1: 退避と sha256 記録
BACKUP="$(mktemp)"
cp "$SRC" "$BACKUP"
HASH_BEFORE="$(sha256sum "$SRC" | awk '{print $1}')"

ok=0
ng=0
total=0
first=1
# 最終行に改行が無くても読むため || [ -n ... ] を付ける
while IFS=$'\t' read -r line token _rest || [ -n "${line:-}${token:-}${_rest:-}" ]; do
  # 先頭行の BOM を除去
  if [ "$first" -eq 1 ]; then
    line="${line#$'\xef\xbb\xbf'}"
    first=0
  fi
  # CR を除去（CRLF対策）
  line="${line%$'\r'}"
  token="${token%$'\r'}"
  total=$((total + 1))
  # 空行・字句なし・行番号が数値でない行は NG として数える
  if [ -z "${line}" ] || [ -z "${token}" ] || ! printf '%s' "$line" | grep -qE '^[0-9]+$'; then
    echo "NG  ${line:-?}  ${token:-（空）}  （形式不正）"
    ng=$((ng + 1))
    continue
  fi
  if sed -n "${line}p" "$SRC" | grep -qF -- "$token"; then
    echo "OK  ${line}  ${token}"
    ok=$((ok + 1))
  else
    echo "NG  ${line}  ${token}"
    ng=$((ng + 1))
  fi
done < "$LIST"

# C3: 元ファイル不変の確認
HASH_AFTER="$(sha256sum "$SRC" | awk '{print $1}')"
if [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then
  echo "元ファイル不変（sha256 一致）"
else
  echo "警告: 元ファイルが照合中に変化しました" >&2
  ng=$((ng + 1))
fi
rm -f "$BACKUP"

echo "台帳: 入力 ${total} = OK ${ok} + NG ${ng}"
if [ "$total" -ne $((ok + ng)) ]; then
  echo "警告: 件数台帳が合いません" >&2
  exit 1
fi
[ "$ng" -eq 0 ]
