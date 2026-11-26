# CHANGELOG

## 2026-11-26 — 3点セット化とフック同梱

- `data-analysis-llm-practice` を追加（データ分析でLLMをどう使うかの作法：
  役割分担、仕様先行と計画合意、指示パターン、検証の分離、機械的照合）。
  3つの案（Claude Opus／Gemini／Muse）を統合し、合意ラウンドを経て確定した。
  統合の方針：素材に無い要素は入れない、出典の無いルールは追加しない。
- `data-analysis-llm-practice/scripts/collate.sh` を同梱（機械的照合 C1〜C3 の
  実行スクリプト。BOM／CRLF／最終行の改行なし等、素のループの弱点に対策済み）。
- `hooks/` を追加。スキルのルールのうち機械的に判定できるもの
  （生データの上書き禁止、BOM付きUTF-8、dropna の警告など）を Claude Code の
  フックで強制する。導入は任意（プロジェクトの settings に取り込む）。
- `scripts/check_xrefs.sh` を追加。スキル間の相互参照（節名・Stage番号）が
  実在するかを grep で確かめる。
- `data-analysis-check` に YAML frontmatter（name/description）を追加
  （メタデータの修正。本文は変更なし）。
- README に3スキルの使い分けと連携フロー、外部依存、フックの導入手順を追記。

## 2026-11-24 — 2点セットで初公開

- `data-analysis-pipeline`（7ステージの前処理パイプライン＋Python/Rテンプレート）
- `data-analysis-check`（定義固定と11項目の検証表）
- パイプラインテンプレートは、欠陥を仕込んだ既知答え付きフィクスチャで検証済み
  （71行 → 68 → 65 → 64 → 独立イベント59件。R版と全セル一致）。
