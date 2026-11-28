# pipeline_template.py — 汚いデータを分析用テーブルに変える汎用パイプライン。
# data-analysis-pipeline スキルの Stage 1〜4 の実装。
# 使い方：プロジェクトに pipeline.py としてコピーし、CONFIG を埋めて上から実行する。
# 一回きりの分析は単一ファイル・直線形が基本。生データは絶対に上書きしない。
# R 版（pipeline_template.R）と、同じ検証データで件数が完全一致すること。
import unicodedata
import pandas as pd
import numpy as np
from pathlib import Path

# ================= CONFIG（データごとにここだけ埋める） =================
CONFIG = {
    "input_csv": "00_raw/input.csv",          # 生データ（00_raw/ に置いたコピー）
    "out_dir": ".",
    "datetime_col": "datetime_raw",           # 日時列。無ければ None
    "category_mappings": {                    # 列 -> {表記ゆれ: 正規名}
        # "species_raw": {"シカ": "ニホンジカ", "sika deer": "ニホンジカ"},
    },
    "known_unknown": ["不明", "unknown", "?"],  # 元データが「不明」の意味で使うラベル
    "numeric_cols": [],                       # 数値に変換する列
    "dedupe_keys": None,                      # None = 行全体で重複判定。列リストでも可
    "post_dedupe_keys": None,                 # 正規化後にもう一度重複を見るキー（例 ["station", "species", "datetime"]）
    # イベント化（任意）：近接した記録を1イベントにまとめる
    "eventize": None,                         # {"group_keys": [...], "time_col": "datetime",
                                              #  "gap_minutes": 30, "anchor": "last_kept"}
    # 努力量テーブル（任意。率を出すなら必須）
    "effort": None,                           # {"csv": ..., "unit_col": ..., "value_col": ...,
                                              #  "warn_below": 100, "exclude_below": 20}
    "analysis_keys": ["station", "species"],  # 最終テーブルのグループキー
    "time_bucket": None,                      # None | "day" | "week" | "month"
}
# =====================================================================

cfg = CONFIG
out = Path(cfg["out_dir"]); out.mkdir(parents=True, exist_ok=True)
ledger = []            # 件数の台帳：（工程, 入力件数, 出力件数）
decisions = []         # 判断ログの行。数値は必ず計算結果から入れる（手で書かない）
excluded_frames = []   # 除外した行（理由コード付き）-> excluded_rows.csv に出す
procedure = []         # 手順書（人間がExcelで同じ手順を再現するための作業手順）

def mech(s):
    # 機械的な正規化だけ：全角半角・空白・大文字小文字を揃える。
    # 意味の解釈はしない（それは対応表の仕事）。半角カナ等はここで吸収される。
    if not isinstance(s, str):
        return s
    s = unicodedata.normalize("NFKC", s).strip()
    s = " ".join(s.split())
    return s.casefold()

def balance(stage, n_in, df_out):
    # 件数台帳に1行追加して表示する。後で decision_log に転記される。
    ledger.append((stage, n_in, len(df_out)))
    print(f"[{stage}] in={n_in} out={len(df_out)}")

def drop_rows(df, mask, step, code, detail=""):
    # 条件に当たった行を「理由コード付きで」除外台帳に移し、残りを返す。
    # 黙って消すことはしない。消えた行は excluded_rows.csv でいつでも見られる。
    gone = df[mask].copy()
    if len(gone):
        gone["excl_step"], gone["excl_code"], gone["excl_detail"] = step, code, detail
        excluded_frames.append(gone)
    return df[~mask]

# ---------- Stage 0 相当：00_raw/ を書き込み禁止にして原本を仕組みで守る ----------
# 入力のコピーが済んでいる前提で、00_raw/ 全体を読み取り専用にする。
# エディタの deny 設定ではこのスクリプト自身の書き込みは止められないが、
# ファイル権限なら止められる。再コピーするときは権限を戻してから行うこと。
# （入力パスが 00_raw/ の外を指している場合は何もしない）
raw_dir = Path(cfg["input_csv"]).parent
if raw_dir.name == "00_raw" and raw_dir.exists():
    for p in sorted(raw_dir.rglob("*"), key=lambda x: -len(x.parts)):
        p.chmod(0o555 if p.is_dir() else 0o444)
    raw_dir.chmod(0o555)
    decisions.append("00_raw/ locked read-only after copy (files 444 / dirs 555). [source: default]")
    print("[raw lock] 00_raw/ is now read-only")

# ---------- Stage 1：監査（読むだけ。データは一切いじらない） ----------
# keep_default_na=False が大事："" や "NA" を勝手に欠損にされると監査の件数が狂う。
raw = pd.read_csv(cfg["input_csv"], dtype=str, keep_default_na=False, encoding="utf-8-sig")
print(f"[raw] rows={len(raw)}")
audit_lines = [f"# audit — {cfg['input_csv']}", f"rows={len(raw)}, cols={len(raw.columns)}",
               f"exact_duplicate_rows={int(raw.duplicated().sum())}"]
for col in raw.columns:
    # 列ごとに：埋まっている割合、異なる値の数、上位の値。これが対応表作りの材料になる。
    s = raw[col]
    audit_lines.append(f"- {col}: fill={100*s.ne('').mean():.1f}% distinct={s.nunique()} "
                       f"top={s.value_counts().head(3).to_dict()}")
(out / "audit.md").write_text("\n".join(audit_lines), encoding="utf-8")
print("\n".join(audit_lines))

# ---------- Stage 2：クレンジング（計画どおりに実行し、毎回件数を出す） ----------
df = raw.copy()

# まず完全な重複行を落とす。何行落ちたかを判断ログに残す。
n0 = len(df)
if cfg["dedupe_keys"]:
    df = df.drop_duplicates(subset=cfg["dedupe_keys"])
else:
    df = df.drop_duplicates()
decisions.append(f"Dedupe ({cfg['dedupe_keys'] or 'exact rows'}): removed {n0 - len(df)} rows. [source: user]")
balance("dedupe", n0, df)
procedure.append(f"重複の削除：全データを選択し、[データ]→[重複の削除]（キー：{cfg['dedupe_keys'] or '全列'}）。→ この時点で {len(df)} 行になるはずです。")

# 日時をまとめて解析する。形式が混在していても format="mixed" で読む。
# 解析できなかった行は、黙って NaT にせず理由コード付きで隔離する。
if cfg["datetime_col"]:
    df["datetime"] = pd.to_datetime(df[cfg["datetime_col"]], format="mixed", errors="coerce")
    df = drop_rows(df, df["datetime"].isna(), "parse", "UNPARSED_DATETIME", cfg["datetime_col"])
    decisions.append(f"Datetime {cfg['datetime_col']}: mixed-format parse; failures quarantined to excluded_rows.csv. [source: user]")
    procedure.append(f"日時の統一：列「{cfg['datetime_col']}」を日時として解釈し、1つの書式に統一します。書式が複数混在する場合は形式ごとに作業列を分けて変換してください。解釈できない行は削除せず、別シート「除外」に理由（UNPARSED_DATETIME）とともに移します。→ この時点で {len(df)} 行になるはずです。")

# カテゴリ列の正規化：機械的正規化 -> 対応表で正規名に変換。
# 空欄は MISSING_CATEGORY、「不明」系は UNKNOWN_LABEL として分けて除外する。
# 対応表にも不明リストにも無いラベルが出たら、推測で捨てずに止まる（fail closed）。
for col, mapping in cfg["category_mappings"].items():
    canon_col = col.replace("_raw", "")
    lookup = {mech(k): v for k, v in mapping.items()}
    known_unknown = {mech(x) for x in cfg["known_unknown"]}
    n_before = len(df)
    df[canon_col] = df[col].map(mech).map(lookup)
    df = drop_rows(df, df[col].map(mech).eq(""), "normalize", "MISSING_CATEGORY", col)
    df = drop_rows(df, df[canon_col].isna() & df[col].map(mech).isin(known_unknown),
                   "normalize", "UNKNOWN_LABEL", col)
    unmapped = df.loc[df[canon_col].isna(), col].value_counts().to_dict()
    if unmapped:
        raise SystemExit(f"UNMAPPED labels in {col}: {unmapped} — add to mapping or known_unknown, then rerun.")
    decisions.append(f"Category {col} -> {canon_col}: mapping applied after NFKC/strip/casefold. [source: user]")
    balance(f"normalize {col}", n_before, df)
    procedure.append(f"「{col}」の表記統一：まず全角/半角・余分な空白・大文字小文字を揃えます。次に「対応表」シート（表記ゆれ→正規名）を用意し、XLOOKUP（なければ VLOOKUP）で正規名の列「{canon_col}」を追加します。空欄の行は理由 MISSING_CATEGORY、「不明」にあたる行は UNKNOWN_LABEL として「除外」シートへ移します。対応表に無い表記が出たら、推測で処理せず作業を止めて対応表を更新してください。→ この時点で {len(df)} 行になるはずです。")

# 数値列の変換。変換できなかった値は NaN になる（件数は監査側で確認する）。
for col in cfg["numeric_cols"]:
    df[col] = pd.to_numeric(df[col], errors="coerce")

# 正規化の後にもう一度重複を見る。日時形式や表記ゆれが違うだけの同一記録は、
# 生の文字列の重複検査では残ってしまうため、ここで初めて捕まえられる。
if cfg["post_dedupe_keys"]:
    n0 = len(df)
    df = df.drop_duplicates(subset=cfg["post_dedupe_keys"])
    decisions.append(f"Post-normalize dedupe on {cfg['post_dedupe_keys']}: removed {n0 - len(df)} rows (same record in different raw formats). [source: user]")
    balance("post-dedupe", n0, df)
    procedure.append(f"正規化後の重複削除：キー列 {cfg['post_dedupe_keys']} で再度 [重複の削除] を行います（書式違いで残った同一記録をここで落とします）。→ この時点で {len(df)} 行になるはずです。")

# 洗ったデータを別ファイルに書く。生データには触らない。
df.to_csv(out / "clean.csv", index=False, encoding="utf-8-sig")  # BOM付きUTF-8が標準（Excelで文字化けしない）
print(f"[clean] rows={len(df)}")

# ---------- Stage 3/4：イベント化（任意）＋ 分析テーブル ----------
work = df
ev = cfg["eventize"]
if ev:
    gap = pd.Timedelta(minutes=ev["gap_minutes"])

    # 指定した間隔で何イベントになるか数えるだけの関数。感度分析にも使う。
    def count_events(frame, gap_td):
        n = 0
        for _, g in frame.sort_values(ev["group_keys"] + ["datetime"]).groupby(ev["group_keys"]):
            last = None
            for ts in g["datetime"]:
                if last is None or (ts - last) >= gap_td:
                    n += 1; last = ts
        return n

    # 本番のイベント化：グループ内で時刻順に見て、直前の「採用イベント」から
    # gap 以上空いた記録だけを採用する（anchor = last_kept）。
    kept_idx = []
    for _, g in work.sort_values(ev["group_keys"] + ["datetime"]).groupby(ev["group_keys"]):
        last = None
        for idx, ts in g["datetime"].items():
            if last is None or (ts - last) >= gap:
                kept_idx.append(idx); last = ts
    n_events = len(kept_idx)
    # 閾値を半分と2倍にしたら件数がどう変わるかも並べて出す（結論が閾値次第か分かる）。
    sens = {f"{ev['gap_minutes']//2}min": count_events(work, gap / 2),
            f"{ev['gap_minutes']*2}min": count_events(work, gap * 2)}
    decisions.append(f"Eventization: group={ev['group_keys']}, gap={ev['gap_minutes']}min, anchor=last_kept -> "
                     f"{len(work)} records to {n_events} events (collapsed {len(work) - n_events}). "
                     f"Sensitivity: {sens}. [source: default]")
    work = work.loc[kept_idx]
    print(f"[eventize] events={n_events} sensitivity={sens}")
    procedure.append(f"イベント化：{ev['group_keys']} の順→日時の順に並べ替えます。「直前に採用した行からの経過（分）」の列を作り、先頭の行か、経過が {ev['gap_minutes']} 分以上の行だけを残します。→ この時点で {n_events} 件になるはずです。")

# 時間バケット（週・月など）を使う場合は期間列を作り、キーに加える。
if cfg["time_bucket"] and cfg["datetime_col"]:
    freq = {"day": "D", "week": "W", "month": "M"}[cfg["time_bucket"]]
    work = work.assign(period=work["datetime"].dt.to_period(freq).astype(str))
    keys = cfg["analysis_keys"] + ["period"]
else:
    keys = cfg["analysis_keys"]
# 注意：groupby は「観測されなかった組合せ」の行を作らない。
# 行が無い＝未観測であって、0（観測して不在）とは違う。0埋めは観測が分かっている組合せだけにすること。
table = work.groupby(keys).size().rename("n").reset_index() if keys else work.assign(n=1)
procedure.append(f"集計：ピボットテーブルで {keys} ごとの件数を数えます。行が無い組合せは「未観測」であって 0 ではありません（観測して不在の場合だけ 0）。")

# 努力量テーブルがある場合は結合して率を出す。
# 努力量が下限未満の単位は率の表から外す（分母が小さいと率が跳ねるため）。
eff_cfg = cfg["effort"]
if eff_cfg:
    eff = pd.read_csv(eff_cfg["csv"], encoding="utf-8-sig")
    eff["flag"] = np.where(eff[eff_cfg["value_col"]] < eff_cfg["warn_below"],
                           f"FLAG < {eff_cfg['warn_below']}", "")
    table = table.merge(eff, left_on=keys[0], right_on=eff_cfg["unit_col"], how="left")
    table["rate_per_unit"] = (table["n"] / table[eff_cfg["value_col"]]).round(3)
    excluded_units = eff.loc[eff[eff_cfg["value_col"]] < eff_cfg["exclude_below"], eff_cfg["unit_col"]].tolist()
    if excluded_units:
        decisions.append(f"Effort: units below {eff_cfg['exclude_below']} excluded from rate table: {excluded_units}. [source: default]")
        table = table[~table[keys[0]].isin(excluded_units)]
    procedure.append(f"率の計算：努力量表をキー「{eff_cfg['unit_col']}」で引き当てて結合し、率 = 件数 ÷ {eff_cfg['value_col']} を計算します。{eff_cfg['value_col']} が {eff_cfg['exclude_below']} 未満の単位は、分母が小さく率が不安定なため表から除きます（警告のみは {eff_cfg['warn_below']} 未満）。")
    eff.to_csv(out / "effort_table.csv", index=False, encoding="utf-8-sig")

table.to_csv(out / "analysis_table.csv", index=False, encoding="utf-8-sig")
print(f"[analysis table] rows={len(table)}")
print(table.head(20).to_string(index=False))

# ---------- 出力：除外台帳と判断ログ ----------
# 除外した行は理由コード付きで全部出す。後から「なぜこの行が無いのか」に答えられるように。
if excluded_frames:
    pd.concat(excluded_frames).to_csv(out / "excluded_rows.csv", index=False, encoding="utf-8-sig")
lines = ["# decision_log", *[f"- {d}" for d in decisions], "", "## count ledger"]
lines += [f"- {s}: in={i} out={o}" for s, i, o in ledger]
lines += [f"- raw rows={len(raw)}, clean rows={len(df)}, excluded rows total="
          f"{sum(len(f) for f in excluded_frames)} (see excluded_rows.csv)"]
(out / "decision_log.md").write_text("\n".join(lines), encoding="utf-8")

# 手順書を出す。人間が Excel 等の手作業で同じ結果を再現するための手順で、
# 各ステップに「この時点で○行になるはず」という照合ポイントを付ける。
proc = ["# 手順書（手作業で再現する場合）", "",
        f"入力ファイル：{cfg['input_csv']}（生データは変更しない。作業用コピーを作ってから始める）",
        "各ステップの末尾の行数が、スクリプト実行時の件数と一致するか確認しながら進めてください。", ""]
proc += [f"{i}. {s}" for i, s in enumerate(procedure, 1)]
proc += ["", "除外した行はすべて excluded_rows.csv に理由コード付きで残っています。"]
(out / "procedure.md").write_text("\n".join(proc), encoding="utf-8")
print("\n".join(lines))
print("[done] audit.md / clean.csv / analysis_table.csv / decision_log.md / procedure.md written to", out)
