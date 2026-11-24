# data-analysis-skills

汚い実務データを、監査可能な分析用テーブルに変えるためのAIエージェント用スキル2点セット。
カメラトラップ（自動撮影カメラ）データの前処理パイプラインを一般化して作った。

Two agent skills for turning messy real-world tabular data into auditable
analysis tables, generalized from a camera-trap data pipeline.

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

## 検証について

パイプラインテンプレートは、欠陥を仕込んだ既知答え付きフィクスチャ
（重複行・表記ゆれ・3形式の日時・不明ラベル・バースト記録・努力量不足の単位）で
検証している：71行 → 重複除去68 → 正規化65 → 正規化後重複除去64 →
独立イベント59件、という期待値と完全一致することを確認済み。
R版テンプレート（tidyverse）は準備中で、公開前にPython版と完全一致させる。

## 参考にした公式スキル

- Anthropic, knowledge-work-plugins（data プラグイン：explore-data / validate-data）
- Anthropic, skills（xlsx）
- OpenAI, skills（jupyter-notebook）
- K-Dense-AI, scientific-agent-skills（exploratory-data-analysis）
- baratadiego, ecological-agent-skills（camera-trap-processing）

## ライセンス

MIT
