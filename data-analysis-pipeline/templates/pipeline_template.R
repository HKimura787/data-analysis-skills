# pipeline_template.R — 汚いデータを分析用テーブルに変える汎用パイプライン（R版）。
# data-analysis-pipeline スキルの Stage 1〜4 の実装。Python 版（pipeline_template.py）の双子で、
# 同じ検証データ（欠陥を仕込んだフィクスチャ）で件数が完全一致すること。
# 使い方：プロジェクトに pipeline.R としてコピーし、CONFIG を埋めて上から実行する。
# 一回きりの分析は単一ファイル・直線形が基本。tidyverse の example のようなベタ書きにする。
# 生データは絶対に上書きしない。
library(readr)
library(dplyr)
library(lubridate)
library(stringi)

# 文字コードの前提：UTF-8 ロケールで実行すること。C ロケールだと日本語ラベルが
# バイト列に化けて対応表と一致しなくなるため、ここで止める（fail closed）。
# 例：LANG=C.UTF-8 Rscript pipeline.R
if (!isTRUE(l10n_info()[["UTF-8"]])) {
  stop("UTF-8 locale required: run with e.g. LANG=C.UTF-8 Rscript pipeline.R")
}

# ================= CONFIG（データごとにここだけ埋める） =================
CONFIG <- list(
  input_csv    = "00_raw/input.csv",        # 生データ（00_raw/ に置いたコピー）
  out_dir      = ".",
  datetime_col = "datetime_raw",            # 日時列。無ければ NULL
  category_mappings = list(                 # 列 -> 表記ゆれと正規名の対応表
    # species_raw = c("シカ" = "ニホンジカ", "sika deer" = "ニホンジカ")
  ),
  known_unknown = c("不明", "unknown", "?"), # 元データが「不明」の意味で使うラベル
  numeric_cols = c(),                       # 数値に変換する列
  dedupe_keys = NULL,                       # NULL = 行全体で重複判定。列名のベクトルでも可
  post_dedupe_keys = NULL,                  # 正規化後にもう一度重複を見るキー
  eventize = NULL,                          # list(group_keys=..., gap_minutes=30) で有効化
  effort = NULL,                            # list(csv=..., unit_col=..., value_col=...,
                                            #      warn_below=100, exclude_below=20)
  analysis_keys = c("station", "species"),  # 最終テーブルのグループキー
  time_bucket = NULL                        # NULL | "day" | "week" | "month"
)
# =====================================================================

cfg <- CONFIG
dir.create(cfg$out_dir, showWarnings = FALSE, recursive = TRUE)
ledger <- list()          # 件数の台帳：（工程, 入力件数, 出力件数）
decisions <- c()          # 判断ログの行。数値は必ず計算結果から入れる（手で書かない）
procedure <- c()          # 手順書（人間がExcelで同じ手順を再現するための作業手順）
excluded_frames <- list() # 除外した行（理由コード付き）-> excluded_rows.csv に出す

mech <- function(s) {
  # 機械的な正規化だけ：全角半角・空白・大文字小文字を揃える。
  # 意味の解釈はしない（それは対応表の仕事）。半角カナ等はここで吸収される。
  s <- stri_trans_nfkc(s)
  s <- trimws(s)
  s <- gsub("\\s+", " ", s)
  tolower(s)
}

balance <- function(stage, n_in, df_out) {
  # 件数台帳に1行追加して表示する。後で decision_log に転記される。
  ledger[[length(ledger) + 1]] <<- c(stage, n_in, nrow(df_out))
  cat(sprintf("[%s] in=%d out=%d\n", stage, n_in, nrow(df_out)))
}

drop_rows <- function(df, mask, step, code, detail = "") {
  # 条件に当たった行を「理由コード付きで」除外台帳に移し、残りを返す。
  # 黙って消すことはしない。消えた行は excluded_rows.csv でいつでも見られる。
  gone <- df[mask, ]
  if (nrow(gone) > 0) {
    gone$excl_step <- step; gone$excl_code <- code; gone$excl_detail <- detail
    excluded_frames[[length(excluded_frames) + 1]] <<- gone
  }
  df[!mask, ]
}

# ---------- Stage 1：監査（読むだけ。データは一切いじらない） ----------
# na = character() が大事："" や "NA" を勝手に欠損にされると監査の件数が狂う。
raw <- read_csv(cfg$input_csv, col_types = cols(.default = col_character()),
                na = character())
cat(sprintf("[raw] rows=%d\n", nrow(raw)))
audit_lines <- c(sprintf("# audit — %s", cfg$input_csv),
                 sprintf("rows=%d, cols=%d", nrow(raw), ncol(raw)),
                 sprintf("exact_duplicate_rows=%d", sum(duplicated(raw))))
for (col in names(raw)) {
  # 列ごとに：埋まっている割合、異なる値の数、上位の値。これが対応表作りの材料になる。
  s <- raw[[col]]
  top <- sort(table(s), decreasing = TRUE)
  top_txt <- paste(sprintf("%s:%d", names(head(top, 3)), head(top, 3)), collapse = ", ")
  audit_lines <- c(audit_lines,
                   sprintf("- %s: fill=%.1f%% distinct=%d top={%s}",
                           col, 100 * mean(s != ""), length(unique(s)), top_txt))
}
writeLines(audit_lines, file.path(cfg$out_dir, "audit.md"))
cat(paste(audit_lines, collapse = "\n"), "\n")

# ---------- Stage 2：クレンジング（計画どおりに実行し、毎回件数を出す） ----------
df <- raw

# まず完全な重複行を落とす。何行落ちたかを判断ログに残す。
n0 <- nrow(df)
if (!is.null(cfg$dedupe_keys)) {
  df <- distinct(df, across(all_of(cfg$dedupe_keys)), .keep_all = TRUE)
} else {
  df <- distinct(df)
}
decisions <- c(decisions, sprintf("Dedupe (%s): removed %d rows. [source: user]",
                                  if (is.null(cfg$dedupe_keys)) "exact rows"
                                  else paste(cfg$dedupe_keys, collapse = ", "), n0 - nrow(df)))
balance("dedupe", n0, df)
procedure <- c(procedure, sprintf("重複の削除：全データを選択し、[データ]→[重複の削除]（キー：%s）。→ この時点で %d 行になるはずです。",
                                  if (is.null(cfg$dedupe_keys)) "全列"
                                  else paste(cfg$dedupe_keys, collapse = ", "), nrow(df)))

# 日時をまとめて解析する。形式が混在していても orders を複数渡せば要素ごとに読む。
# 解析できなかった行は、黙って NA にせず理由コード付きで隔離する。
if (!is.null(cfg$datetime_col)) {
  df$datetime <- parse_date_time(df[[cfg$datetime_col]],
                                 orders = c("ymd HM", "ymd HMS", "d b Y HM", "d b Y HMS"),
                                 tz = "UTC")
  df <- drop_rows(df, is.na(df$datetime), "parse", "UNPARSED_DATETIME", cfg$datetime_col)
  decisions <- c(decisions, sprintf("Datetime %s: mixed-format parse; failures quarantined to excluded_rows.csv. [source: user]",
                                    cfg$datetime_col))
  procedure <- c(procedure, sprintf("日時の統一：列「%s」を日時として解釈し、1つの書式に統一します。書式が複数混在する場合は形式ごとに作業列を分けて変換してください。解釈できない行は削除せず、別シート「除外」に理由（UNPARSED_DATETIME）とともに移します。→ この時点で %d 行になるはずです。",
                                    cfg$datetime_col, nrow(df)))
}

# カテゴリ列の正規化：機械的正規化 -> 対応表で正規名に変換。
# 空欄は MISSING_CATEGORY、「不明」系は UNKNOWN_LABEL として分けて除外する。
# 対応表にも不明リストにも無いラベルが出たら、推測で捨てずに止まる（fail closed）。
for (col in names(cfg$category_mappings)) {
  mapping <- cfg$category_mappings[[col]]
  canon_col <- sub("_raw", "", col)
  lookup <- setNames(unname(mapping), mech(names(mapping)))
  known_unknown <- mech(cfg$known_unknown)
  n_before <- nrow(df)
  m <- mech(df[[col]])
  df[[canon_col]] <- unname(lookup[m])
  df <- drop_rows(df, m == "", "normalize", "MISSING_CATEGORY", col)
  m <- mech(df[[col]])
  df <- drop_rows(df, is.na(df[[canon_col]]) & (m %in% known_unknown),
                  "normalize", "UNKNOWN_LABEL", col)
  unmapped <- table(df[[col]][is.na(df[[canon_col]])])
  if (length(unmapped) > 0) {
    stop(sprintf("UNMAPPED labels in %s: %s — add to mapping or known_unknown, then rerun.",
                 col, paste(sprintf("%s:%d", names(unmapped), unmapped), collapse = ", ")))
  }
  decisions <- c(decisions, sprintf("Category %s -> %s: mapping applied after NFKC/strip/casefold. [source: user]",
                                    col, canon_col))
  balance(sprintf("normalize %s", col), n_before, df)
  procedure <- c(procedure, sprintf("「%s」の表記統一：まず全角/半角・余分な空白・大文字小文字を揃えます。次に「対応表」シート（表記ゆれ→正規名）を用意し、XLOOKUP（なければ VLOOKUP）で正規名の列「%s」を追加します。空欄の行は理由 MISSING_CATEGORY、「不明」にあたる行は UNKNOWN_LABEL として「除外」シートへ移します。対応表に無い表記が出たら、推測で処理せず作業を止めて対応表を更新してください。→ この時点で %d 行になるはずです。",
                                    col, canon_col, nrow(df)))
}

# 数値列の変換。変換できなかった値は NA になる（件数は監査側で確認する）。
for (col in cfg$numeric_cols) {
  df[[col]] <- suppressWarnings(as.numeric(df[[col]]))
}

# 正規化の後にもう一度重複を見る。日時形式や表記ゆれが違うだけの同一記録は、
# 生の文字列の重複検査では残ってしまうため、ここで初めて捕まえられる。
if (!is.null(cfg$post_dedupe_keys)) {
  n0 <- nrow(df)
  df <- distinct(df, across(all_of(cfg$post_dedupe_keys)), .keep_all = TRUE)
  decisions <- c(decisions, sprintf("Post-normalize dedupe on [%s]: removed %d rows (same record in different raw formats). [source: user]",
                                    paste(cfg$post_dedupe_keys, collapse = ", "), n0 - nrow(df)))
  balance("post-dedupe", n0, df)
  procedure <- c(procedure, sprintf("正規化後の重複削除：キー列 [%s] で再度 [重複の削除] を行います（書式違いで残った同一記録をここで落とします）。→ この時点で %d 行になるはずです。",
                                    paste(cfg$post_dedupe_keys, collapse = ", "), nrow(df)))
}

# 洗ったデータを別ファイルに書く。生データには触らない。
write_csv(df, file.path(cfg$out_dir, "clean.csv"))
cat(sprintf("[clean] rows=%d\n", nrow(df)))

# ---------- Stage 3/4：イベント化（任意）＋ 分析テーブル ----------
work <- df
ev <- cfg$eventize
if (!is.null(ev)) {
  gap_sec <- ev$gap_minutes * 60

  # 指定した間隔で何イベントになるか数えるだけの関数。感度分析にも使う。
  count_events <- function(frame, gap_s) {
    frame <- arrange(frame, across(all_of(c(ev$group_keys, "datetime"))))
    grp <- interaction(frame[ev$group_keys], drop = TRUE)
    n <- 0
    for (idx in split(seq_len(nrow(frame)), grp)) {
      last <- NULL
      for (i in idx) {
        ts <- frame$datetime[i]
        if (is.null(last) || as.numeric(difftime(ts, last, units = "secs")) >= gap_s) {
          n <- n + 1; last <- ts
        }
      }
    }
    n
  }

  # 本番のイベント化：グループ内で時刻順に見て、直前の「採用イベント」から
  # gap 以上空いた記録だけを採用する（anchor = last_kept）。
  work <- arrange(work, across(all_of(c(ev$group_keys, "datetime"))))
  grp <- interaction(work[ev$group_keys], drop = TRUE)
  kept <- rep(FALSE, nrow(work))
  for (idx in split(seq_len(nrow(work)), grp)) {
    last <- NULL
    for (i in idx) {
      ts <- work$datetime[i]
      if (is.null(last) || as.numeric(difftime(ts, last, units = "secs")) >= gap_sec) {
        kept[i] <- TRUE; last <- ts
      }
    }
  }
  n_events <- sum(kept)
  # 閾値を半分と2倍にしたら件数がどう変わるかも並べて出す（結論が閾値次第か分かる）。
  sens_half <- count_events(work, gap_sec / 2)
  sens_double <- count_events(work, gap_sec * 2)
  decisions <- c(decisions, sprintf("Eventization: group=[%s], gap=%dmin, anchor=last_kept -> %d records to %d events (collapsed %d). Sensitivity: %dmin=%d, %dmin=%d. [source: default]",
                                    paste(ev$group_keys, collapse = ", "), ev$gap_minutes,
                                    nrow(work), n_events, nrow(work) - n_events,
                                    ev$gap_minutes %/% 2, sens_half, ev$gap_minutes * 2, sens_double))
  work <- work[kept, ]
  cat(sprintf("[eventize] events=%d sensitivity: %dmin=%d, %dmin=%d\n",
              n_events, ev$gap_minutes %/% 2, sens_half, ev$gap_minutes * 2, sens_double))
  procedure <- c(procedure, sprintf("イベント化：%s の順→日時の順に並べ替えます。「直前に採用した行からの経過（分）」の列を作り、先頭の行か、経過が %d 分以上の行だけを残します。→ この時点で %d 件になるはずです。",
                                    paste(ev$group_keys, collapse = ", "), ev$gap_minutes, n_events))
}

# 時間バケット（週・月など）を使う場合は期間列を作り、キーに加える。
# 週は Python 版に合わせて「月曜〜日曜」を "開始日/終了日" の文字列にする。
keys <- cfg$analysis_keys
if (!is.null(cfg$time_bucket) && !is.null(cfg$datetime_col)) {
  if (cfg$time_bucket == "week") {
    week_start <- floor_date(as.Date(work$datetime), "week", week_start = 1)
    work$period <- sprintf("%s/%s", week_start, week_start + 6)
  } else if (cfg$time_bucket == "day") {
    work$period <- as.character(as.Date(work$datetime))
  } else if (cfg$time_bucket == "month") {
    work$period <- format(as.Date(work$datetime), "%Y-%m")
  }
  keys <- c(keys, "period")
}
# 注意：count() は「観測されなかった組合せ」の行を作らない。
# 行が無い＝未観測であって、0（観測して不在）とは違う。0埋めは観測が分かっている組合せだけにすること。
table_out <- count(work, across(all_of(keys)), name = "n")
procedure <- c(procedure, sprintf("集計：ピボットテーブルで [%s] ごとの件数を数えます。行が無い組合せは「未観測」であって 0 ではありません（観測して不在の場合だけ 0）。",
                                  paste(keys, collapse = ", ")))

# 努力量テーブルがある場合は結合して率を出す。
# 努力量が下限未満の単位は率の表から外す（分母が小さいと率が跳ねるため）。
eff_cfg <- cfg$effort
if (!is.null(eff_cfg)) {
  eff <- read_csv(eff_cfg$csv)
  eff$flag <- ifelse(eff[[eff_cfg$value_col]] < eff_cfg$warn_below,
                     sprintf("FLAG < %d", eff_cfg$warn_below), "")
  table_out <- left_join(table_out, eff, by = setNames(eff_cfg$unit_col, keys[1]))
  table_out$rate_per_unit <- round(table_out$n / table_out[[eff_cfg$value_col]], 3)
  excluded_units <- eff[[eff_cfg$unit_col]][eff[[eff_cfg$value_col]] < eff_cfg$exclude_below]
  if (length(excluded_units) > 0) {
    decisions <- c(decisions, sprintf("Effort: units below %d excluded from rate table: [%s]. [source: default]",
                                      eff_cfg$exclude_below, paste(excluded_units, collapse = ", ")))
    table_out <- table_out[!table_out[[keys[1]]] %in% excluded_units, ]
  }
  procedure <- c(procedure, sprintf("率の計算：努力量表をキー「%s」で引き当てて結合し、率 = 件数 ÷ %s を計算します。%s が %d 未満の単位は、分母が小さく率が不安定なため表から除きます（警告のみは %d 未満）。",
                                    eff_cfg$unit_col, eff_cfg$value_col, eff_cfg$value_col,
                                    eff_cfg$exclude_below, eff_cfg$warn_below))
  write_csv(eff, file.path(cfg$out_dir, "effort_table.csv"))
}

write_csv(table_out, file.path(cfg$out_dir, "analysis_table.csv"))
cat(sprintf("[analysis table] rows=%d\n", nrow(table_out)))
print(head(table_out, 20))

# ---------- 出力：除外台帳と判断ログと手順書 ----------
# 除外した行は理由コード付きで全部出す。後から「なぜこの行が無いのか」に答えられるように。
if (length(excluded_frames) > 0) {
  write_csv(bind_rows(excluded_frames), file.path(cfg$out_dir, "excluded_rows.csv"))
}
lines <- c("# decision_log", paste0("- ", decisions), "", "## count ledger",
           sapply(ledger, function(x) sprintf("- %s: in=%s out=%s", x[1], x[2], x[3])),
           sprintf("- raw rows=%d, clean rows=%d, excluded rows total=%d (see excluded_rows.csv)",
                   nrow(raw), nrow(df), sum(sapply(excluded_frames, nrow))))
writeLines(lines, file.path(cfg$out_dir, "decision_log.md"))

# 手順書を出す。人間が Excel 等の手作業で同じ結果を再現するための手順で、
# 各ステップに「この時点で○行になるはず」という照合ポイントを付ける。
proc <- c("# 手順書（手作業で再現する場合）", "",
          sprintf("入力ファイル：%s（生データは変更しない。作業用コピーを作ってから始める）", cfg$input_csv),
          "各ステップの末尾の行数が、スクリプト実行時の件数と一致するか確認しながら進めてください。", "",
          sprintf("%d. %s", seq_along(procedure), procedure), "",
          "除外した行はすべて excluded_rows.csv に理由コード付きで残っています。")
writeLines(proc, file.path(cfg$out_dir, "procedure.md"))
cat(paste(lines, collapse = "\n"), "\n")
cat("[done] audit.md / clean.csv / analysis_table.csv / decision_log.md / procedure.md written to", cfg$out_dir, "\n")
