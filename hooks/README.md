# hooks — スキルのルールのうち、機械的に判定できるものを強制する

スキル本文はLLMへの文章の指示で、読み飛ばされることがある。このディレクトリの
フックは、3スキルのルールのうち**機械的に真偽が判定できるものだけ**を
Claude Code のフックで強制する。意味の判断が要るルール（例：報告に検証表が
あるか）はフックにしていない。

## 何が入っているか

| ファイル | 役割 |
|---|---|
| `das_pre_tool_use.py` | PreToolUse（Write/Edit/NotebookEdit/Bash） |
| `das_post_tool_use.py` | PostToolUse（Write/Edit/Bash） |
| `settings.example.json` | `.claude/settings.json` に取り込む設定例 |
| `tests/run_tests.sh` | フックの発火／非発火テスト |

## ルールごとの挙動

| # | ルール（出典） | 挙動 |
|---|---|---|
| H2 | 既存の生データ（`00_raw/` 配下）を Write/Edit で上書き | **deny（ブロック）** |
| H2 | `00_raw/` へ書くように見える Bash（リダイレクト、`sed -i`、既存ファイルへの `cp` 等） | ask（確認） |
| H6 | 生成物（`decision_log.md`、`procedure.md`、`audit.md`）の手編集 | ask（確認） |
| H7 | 長いコード/SQL を Bash に直接書く | 警告（文脈に差し込む） |
| H1a | `to_csv(` に `utf-8-sig` が無い／R の書き出しが BOM 付きでない | 警告 |
| H8 | `read_csv` を `encoding="utf-8"` で読む（BOM耐性でない） | 警告 |
| H1b | Bash 実行後に新規作成された `*.csv` の BOM 無し（`00_raw/` 配下と `.tsv` は除く） | 警告（同一ファイル・同一更新時刻では1回だけ） |
| H3 | `dropna(` 等の行削除。`audit.md` が無いプロジェクトでは強い警告 | 警告 |
| H6' | 500行を超える `.py`/`.R`/`.sql` の一括書き込み | 警告 |

deny にするのは「実物のルールに例外が無く、判定の誤検知がほぼ無い」ものだけ
（H2 の Write/Edit）。それ以外は、人の画面ではなくモデルの文脈に届く警告にする。

## 導入

プロジェクトの `.claude/settings.json` に `settings.example.json` の内容を
取り込み、スクリプトのパスを自分の環境に書き換える。ユーザー単位
（`~/.claude/settings.json`）に入れると、分析と無関係なリポジトリでも
警告が出るので、プロジェクト単位を推奨する。

## 限界（正直なところ）

- スクリプト内部からの上書き（例：パイプラインの CONFIG で出力先を
  `00_raw` に誤指定）はフックでは防げない。決定的に守るには、コピー直後に
  OS の権限で読み取り専用にするのがよい：`chmod -R a-w 00_raw`
  （フックはツールの呼び出しを止める層、権限は全経路を止める層）。
- Bash の書き込み判定は正規表現による推定で、完全ではない。だから Bash 側は
  deny ではなく ask にしている。
- H1b の状態ファイルは `~/.cache/das-hooks/state.json`。

## テスト

```bash
bash hooks/tests/run_tests.sh
```

「発火すべき入力」と「発火してはいけない入力」（`00_raw/` への初回コピー、
`.tsv` の出力など）の両方を確かめる。
