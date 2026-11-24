---
name: data-analysis-pipeline
description: "Turns a messy real-world tabular dataset (CSV/Excel/TSV) into an auditable analysis table: audit first without touching raw data, clean with explicit mapping tables, normalize formats and units, build the analysis table at a declared unit, and hand off to statistical analysis and visualization. Use when the user provides dirty data and wants cleansing, normalization, table building, analysis, or figures — or mentions データクレンジング, 前処理, 正規化, 分析用テーブル, 検出履歴, 集計テーブル. Pairs with the data-analysis-check skill for verification."
---

# Skill: data-analysis-pipeline

**Domain:** Data cleaning · Normalization · Analysis-table building · EDA · Handoff to statistics/visualization

---

## Purpose

Guides the agent through one reproducible pass over a dirty tabular dataset:
**specify → audit → clean → normalize → build analysis table → analyze/plot → verify**,
with raw data never overwritten, every row-count change accounted for, and every
judgment (mapping, threshold, exclusion) written to a decision log.

Generalized from a camera-trap pipeline (audit → species-name normalization →
30-min independence filter → effort table → detection history). The domain rules
became parameters; the audit trail stayed mandatory.

---

## Non-negotiable principles

1. **Raw is immutable.** Copy inputs to `00_raw/` first; never write back. All outputs are new files.
2. **Definitions before code.** Fix the specification (Stage 0) and get it stated back before transforming anything.
3. **Mappings are explicit.** Category normalization uses a written mapping table. Unknown labels are excluded and counted — never guessed. Before lookup, apply mechanical normalization only (NFKC, strip, collapse spaces, casefold) — that absorbs halfwidth/whitespace variants without inventing meaning.
4. **Counts balance at every step.** Invariant: `n_in == n_kept + n_excluded + n_quarantined`. Print the ledger after each stage (raw → dedupe → parse → normalize → analysis table); a count that cannot be explained stops the pipeline. Excluded/quarantined rows are written to `excluded_rows.csv` with a reason code — never just dropped.
5. **Decisions are logged with their source.** Every threshold, mapping, exclusion and unit conversion goes to the decision log, tagged `source: user | default | inferred`. Decisions still on `default`/`inferred` are listed at the top of the final report as **unconfirmed decisions**. Log values must be computed by the script, never hand-typed prose (a hand-written log can lie).
6. **Fail closed.** Unmapped label → stop or quarantine. Unparseable datetime → quarantine, not silent coercion. Imputation is off unless explicitly configured with a reason.
7. **One-off analysis = single-file linear code.** No reuse-premised modularization. Start from `templates/pipeline_template.py`, fill its CONFIG, run top to bottom.
8. **CSV outputs are UTF-8 with BOM.** So they open correctly in Excel on Windows (no mojibake for Japanese labels): Python `encoding="utf-8-sig"`, R `readr::write_excel_csv()` (or base `write.csv(..., fileEncoding = "UTF-8-BOM")`). Read inputs BOM-tolerantly (`utf-8-sig` / readr default) so a BOM'd file round-trips.

---

## Code style (applies to every script this skill produces)

- **Comment what each block does** — its purpose and the judgment behind it, not syntax narration. The reader is a human (the user) checking the analysis, possibly months later.
- **Disposable by default.** No reuse-premised abstraction, frameworks, or config systems. A function is justified only when the same operation literally repeats; parameters live in one CONFIG block at the top.
- **Flat, example-style code**, like the pandas and tidyverse documentation examples: one operation per step, intermediate results in meaningfully named variables, intermediate tables printed. Avoid nested one-liners and long chains that hide intermediate state — the intermediate state is what gets verified.
- **Manually reproducible, with a procedure document.** Every transformation must be expressible as operations a human could perform by hand in Excel — sort, filter, lookup against a mapping table, pivot — even when the row count makes it impractical in practice. No cleaning/shaping step that only a black box can perform. A procedure document (`procedure.md`) is always shipped: numbered manual steps a person can follow in a spreadsheet to reproduce the same result, each step carrying its checkpoint count from the ledger ("after this step you should have N rows"), so a manual worker can verify their progress against the script's run.

## Stage 0 — Specification (procedure sheet)

Before any code, write down and confirm:

| Item | What to fix |
|---|---|
| Input | File(s), version/date, source, row unit (1 row = what?) |
| Column roles | Classify every column (taxonomy from Anthropic's explore-data): Identifier / Dimension / Metric / Temporal / Text / Boolean / Structural — plus the unit for each Metric |
| Analysis unit | The grain of the final table (e.g. site × week, individual × day) |
| Denominators | What every rate is divided by (effort, exposure, population) and where it comes from |
| Exclusions | Known invalid records and the rule that identifies them |
| Missing policy | Per column: exclude / impute (how) / flag — decided now, not mid-code |

If the user cannot state the definitions back, the specification is not done.

## Stage 1 — Audit (inspect only, modify nothing)

Produce an audit table:

- Row/column counts; exact-duplicate row count
- Per column: fill rate, distinct-value count, top values
- **Read everything as string first** (`keep_default_na=False` / explicit `na_tokens`): spreadsheet libraries silently convert `""` and `"NA"` to null, which corrupts audit counts (e.g. a literal "NA" label disappears)
- Datetime columns: how many distinct formats are present
- Numeric columns: parse-failure count, min/max, impossible values
- Category columns: full distinct-label list (this feeds the mapping table)
- Key columns: uniqueness check

Output: `audit.md`. Do **not** clean in this stage.

## Stage 2 — Cleaning (execute the plan, count everything)

In order, printing counts after each operation:

1. Drop exact duplicates (report n). If a dedupe key is declared, dedupe on it and report n.
2. Parse datetimes with mixed-format parsing. Unparseable values → `quarantine.csv` with a reason code (do not assert-crash, do not coerce silently). Record which format parsed each row when formats are ambiguous (e.g. 03/04 — declare `dayfirst` and the timezone in the specification).
3. Normalize categories: mechanical preprocessing (NFKC/strip/casefold) → mapping table built from the Stage-1 label list. Distinguish **known-unknown** labels (the source deliberately wrote 不明/unknown — exclude with code `UNKNOWN_LABEL`) from **unmapped** labels (not in the table — fail closed: stop or quarantine; never drop silently).
4. Coerce numerics; report parse failures per column.
5. Apply the Stage-0 missing policy per column; report rows affected per column.
6. **Dedupe again after normalization** on the declared key: the same record written in two datetime formats or two label variants survives raw dedupe and must be caught here.
7. **Validate rules** from the specification (ranges, referential integrity, records inside their exposure period). Violations are flagged or quarantined with reason codes.

Output: `clean.csv` (new file; raw untouched).

## Stage 3 — Normalize & shape

- Canonical column names; one name per concept across all files.
- Unit conversions applied once, recorded in the decision log (original unit → analysis unit).
- Reshape to tidy form for the declared analysis unit (long for event data, wide only at presentation).
- Joins: assert and print row counts **before and after** every join; an unexplained row gain/loss stops the pipeline.

## Stage 4 — Analysis table

- Aggregate to the declared analysis unit.
- **Eventization (optional, parameterized):** when near-duplicate events in time must be collapsed (the camera-trap 30-min rule generalized): group keys + time column + gap threshold. Declare the **anchor** (`last_kept`: gap measured from the last kept event — or `last_record`: from the previous record) and the boundary (`>=` vs `>`); the counts differ by anchor, so an undeclared anchor is a hidden decision. Keep `source_row_ids` on each event so it stays traceable to the raw rows. Report records → events and n collapsed, plus counts at 1–2 alternative thresholds (sensitivity) so the reader can see whether conclusions depend on the choice.
- **Denominator/effort table (when rates are computed):** build the exposure table separately (e.g. trap-nights, observation days, person-time). State the counting convention explicitly (`nights = (end − start).days` vs `days = +1` — they differ by one and both appear in the wild). Apply declared minimum-effort rules (flag below warning level, exclude below hard minimum) and state them in the log. Never report a rate whose denominator table does not exist.
- **Matrix outputs:** a unit × period cell that was **not observed** (unit inactive that period) is `NA`, never `0`. `0` means observed and absent. Filling unobserved cells with 0 manufactures false absences and biases occupancy/detection estimates.
- Sanity: check the final table's dimensions against the specification (n units × n periods).

Output: `analysis_table.csv` (+ `effort_table.csv` when applicable).

## Stage 5 — Analysis & figures

- Descriptive statistics first (n, distribution, missingness of the analysis table itself).
- Inferential work: hand off to the dedicated skills — `statistical-analysis`, `pymc` (Bayesian), `occupancy-and-detection` / domain skills where relevant.
- Figures: hand off to `scientific-visualization`. Every figure states what was filtered out.
- **Spreadsheet deliverables** (rule from Anthropic's xlsx skill): write formulas, never hardcoded computed results, so the sheet recalculates when inputs change; document every assumption and hardcoded number where the reader can see it; ship zero formula errors — and remember a clean recalculation proves formulas *evaluate*, not that they are *right*, so spot-check that a few formulas pull the expected values.
- **Notebook deliverables** (convention from OpenAI's jupyter-notebook skill): small runnable cells, each with a short note of purpose and expected result; validate by running top to bottom; if execution is impossible, say so explicitly.

## Stage 6 — Verification

Run the companion `data-analysis-check` skill's 11-item verification on the result, including:

- Count reconciliation: raw → clean → analysis table, every difference explained by a logged rule
- Independent recalculation of one headline number by a different route
- Known-truth check: one value verified by hand from the raw file
- Subtotals sum to totals; percentages to ~100% where they should
- Named pitfall sweep (catalog from Anthropic's validate-data): **join explosion** (row gains at joins), **denominator shifting** (the base changes between compared numbers), **average of averages**, **incomplete-period comparison**, **timezone mismatch**, **survivorship / selection bias** (exclusions correlate with the outcome)

The pipeline is not done until Stage 6 passes.

---

## File layout

```
<project>/
  00_raw/            # untouched inputs (copies)
  audit.md           # Stage 1 output
  clean.csv          # Stage 2 output
  excluded_rows.csv  # every excluded/quarantined row + reason code
  effort_table.csv   # Stage 4, when rates are computed
  analysis_table.csv # Stage 4 output
  decision_log.md    # every mapping, threshold, exclusion, conversion + reason + source
  procedure.md       # manual reproduction guide (spreadsheet steps + checkpoint counts)
  pipeline.py        # the single-file script that produced everything above
```

Known-answer testing: keep a small fixture with planted defects (exact duplicates,
a burst of near-in-time records, blank/NA/unknown labels, an unmapped variant with
trailing space, a record outside its exposure period, one low-effort unit) and the
expected counts per reason code. Re-run it whenever the pipeline script changes;
the R and Python templates must agree on it exactly.

## Decision log — minimum contents

- Mapping table(s) used for category normalization, and unmapped labels found
- Every threshold (eventization gap, effort minimums) and why
- Every exclusion rule and how many rows it removed
- Every unit conversion
- Data version of the inputs

## Anti-patterns (stop and fix if you catch yourself)

- `dropna()` or filtering without printing how many rows went and why
- Guessing what an unknown category label means
- Overwriting or "fixing" the raw file
- Reporting a rate without its denominator table
- Splitting a one-off analysis into modules/packages for hypothetical reuse
- Presenting results before the Stage-6 count reconciliation

## Template

`templates/pipeline_template.py` — a single-file, top-to-bottom implementation of
Stages 1–4 with a CONFIG block at the top (input path, column roles, mapping
tables, eventization and effort parameters). Copy it into the project as
`pipeline.py`, fill CONFIG, and run. It prints the count ledger and writes
`audit.md`, `clean.csv`, `analysis_table.csv`, a filled `decision_log.md`, and
`procedure.md` (the manual reproduction guide). `templates/pipeline_template.R`
is the R twin (tidyverse style); both templates agree exactly on the
planted-defect fixture — verified 2026-11-24: identical clean-table rows,
analysis tables, and exclusion reason codes. The R template requires a UTF-8
locale and stops otherwise.

## References (official skills consulted for this design)

- Anthropic, [knowledge-work-plugins — data plugin](https://github.com/anthropics/knowledge-work-plugins/tree/main/data) (`explore-data`: column classification and profiling questions; `validate-data`: pre-delivery QA and the named pitfall catalog)
- Anthropic, [skills — xlsx](https://github.com/anthropics/skills/tree/main/skills/xlsx) (formulas over hardcoded results; zero formula errors; documented assumptions)
- OpenAI, [skills — jupyter-notebook](https://github.com/openai/skills/tree/main/skills/.curated/jupyter-notebook) (small runnable cells, top-to-bottom validation)
- K-Dense-AI, [scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) (`exploratory-data-analysis`: audit-only stance, never auto-modify raw data)
- baratadiego, [ecological-agent-skills](https://github.com/baratadiego/ecological-agent-skills) (camera-trap-processing: independence threshold, effort rules, detection history — the domain preset this skill was generalized from)
