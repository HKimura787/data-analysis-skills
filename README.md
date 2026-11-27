# data-analysis-skills

汚い実務データを、監査可能な分析用テーブルに変えるためのAIエージェント用スキル3点セット。
分野を問わず、集計・変換・検証を伴うデータ分析全般に使えるよう一般化してある。

Three agent skills for turning messy real-world tabular data into auditable
analysis tables, plus a practice
skill for delegating analysis work to LLMs without letting them compute.

## 3スキルの使い分け

| スキル | 対象 | 中心の問い |
|---|---|---|
| data-analysis-pipeline | データ（汚い表→分析表） | どの順で、何を記録しながら加工するか |
| data-analysis-check | 数値結果（集計・変換の正しさ） | この数値は正しいか |
| data-analysis-llm-practice | LLMという作業者 | LLMに何を任せ、どう指示し、出力をどの経路で確かめるか |

連携の流れ：llm-practice で「計画合意・役割分担・検証の分離」の枠を作る →
pipeline で加工する → check で数値を検証する → LLM生成の一覧・抽出結果は
llm-practice の機械的照合（C1〜C3）を通す → 人間が理由付きで受理する。

llm-practice は他の2つと層が違う（横串の行動規範）。3つ全部を毎回使う
必要はなく、データ加工だけなら pipeline＋check で足りる。

外部依存：統計手法の選択・検定は `statistical-analysis` スキルに、
ベイズモデリングは `pymc` に渡す設計で、それらはこのリポジトリには
含まれない（無ければその段は手動で行う）。

## スキル

### data-analysis-pipeline

CSV/Excel/TSV の汚いデータを、仕様→監査→クレンジング→正規化→分析テーブル化→
分析・図化→検証 の7ステージで処理する手順と、単一ファイルのテンプレート
（`templates/pipeline_template.py`、pandas）。

設計原則：

- 生データは絶対に上書きしない（`00_raw/` にコピーを置く）
- コードより前に「手順書（仕様）」を人間が承認する
- カテゴリ正規化は対応表で明示し、未知ラベルは推測せず止まる（fail closed）
- 各工程で件数の台帳を付け、合わない差分は説明できない限り先に進まない
- 除外した行は理由コード付きで `excluded_rows.csv` に残す
- 変換は「人間がExcelの手作業（並べ替え・フィルタ・対応表の引き当て・ピボット）で
  再現できる操作」だけにし、照合件数入りの手順書 `procedure.md` を必ず同封する
- 一回きりの分析は単一ファイル・直線形の「使い捨て」コード。pandas / tidyverse の
  公式 example のようなベタ書きで、何をやっているか分かるコメントを付ける

### data-analysis-check

集計・分析結果を報告する前に通す検証プロトコル。定義の固定（手順書ゲート）から、
11項目の検証表（件数・合計・範囲・単位・分母・欠損・版・中間表・トレーサビリティ・
独立再計算・別AI照合と真値テスト）まで。パイプラインの最終ステージ（検証）で使う。

### data-analysis-llm-practice

データ分析の仕事をLLM／AIエージェントに任せるときの作法。LLMに計算させず
判断と説明だけを任せる役割分担、実行前の仕様引き出しと計画合意、再利用できる
指示パターン（要件化・反論・SQLレビュー・ETLデバッグ・根本原因・テストケース）、
生成と検証の分離、LLMが作った一覧・中間表への機械的照合（同梱スクリプト
`scripts/collate.sh`）、文脈資料と定義の管理、LLM利用特有の失敗パターン。
根拠は実務者の公開事例10件（Reddit 8件＋note 2件）で、SKILL.md 内に出典と
「根拠の強さ」の区別を明記している。パイプラインのような既知答え付き
フィクスチャでの検証は無い（運用報告と小規模な単発実験が根拠）。

## フック（任意）

`hooks/` に、スキルのルールのうち機械的に判定できるものを Claude Code の
フックで強制するスクリプトを同梱している：生データ（`00_raw/`）の上書き禁止、
作成CSVのBOMチェック、`dropna()` の検出警告、生成物ログの手編集への確認など。
導入は任意で、プロジェクトの `.claude/settings.json` に取り込む形。
詳細と限界は `hooks/README.md` を参照。

推奨セットアップ：生データはコピー直後に OS の権限でも守ると決定的になる
（フックはツールの呼び出しを止める層、権限は全経路を止める層）。

```bash
chmod -R a-w 00_raw
```

## 検証について

パイプラインテンプレートは、欠陥を仕込んだ既知答え付きフィクスチャ
（重複行・表記ゆれ・3形式の日時・不明ラベル・バースト記録・努力量不足の単位）で
検証している：71行 → 重複除去68 → 正規化65 → 正規化後重複除去64 →
独立イベント59件、という期待値と完全一致することを確認済み。
R版テンプレート（tidyverse、`templates/pipeline_template.R`）でも同じ
フィクスチャで検証し、clean テーブルの全行・分析テーブルの全値・除外理由
コードが Python 版と完全一致することを確認済み（2026-11-24）。
なお R 版は UTF-8 ロケールが前提で、C ロケールでは日本語ラベルが化けるため
起動時に停止するガード入り。

## 参考にした公式スキル

- Anthropic, knowledge-work-plugins（data プラグイン：explore-data / validate-data）
- Anthropic, skills（xlsx）
- OpenAI, skills（jupyter-notebook）
- K-Dense-AI, scientific-agent-skills（exploratory-data-analysis）
- baratadiego, ecological-agent-skills（camera-trap-processing）

## ライセンス

MIT
