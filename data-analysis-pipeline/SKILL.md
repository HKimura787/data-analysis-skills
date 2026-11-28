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

The stages generalize a concrete production pipeline (audit → label
normalization → independence filter → effort table → event history).
Domain-specific rules became parameters; the audit trail stayed mandatory.

---

## Non-negotiable principles

1. **Raw is immutable.** Copy inputs to `00_raw/` first; never write back. All outputs are new files. Immediately after copying, lock `00_raw/` read-only (POSIX: `chmod -R a-w 00_raw/`; Windows: set the folder read-only) and record it in the decision log — editor deny-rules do not stop the pipeline script itself from writing, but file permissions do (templates implement this). Tool checkpoints are not a safety net: Claude Code checkpoints do not cover files changed only via Bash (i.e. everything `pipeline.py` writes). The safety net is the `00_raw/` copy + sha256 + Git for code/spec — never `/rewind`. (Source: Anthropic, [checkpointing](https://code.claude.com/docs/en/checkpointing), checked 2026-11-28.)
2. **Definitions before code.** Fix the specification (Stage 0) and get it stated back before transforming anything.
3. **Mappings are explicit.** Category normalization uses a written mapping table. Unknown labels are excluded and counted — never guessed. Before lookup, apply mechanical normalization only (NFKC, strip, collapse spaces, casefold) — that absorbs halfwidth/whitespace variants without inventing meaning. When mechanical normalization merges two distinct raw labels into one, write the full raw→normalized mapping to the decision log; in `procedure.md`, express normalization as a lookup against that complete mapping table (Excel has no NFKC operation).
4. **Counts balance at every step.** Invariant: `n_in == n_kept + n_excluded + n_quarantined`. Print the ledger after each stage (raw → dedupe → parse → normalize → analysis table); a count that cannot be explained stops the pipeline. Excluded/quarantined rows are written to `excluded_rows.csv` with a reason code — never just dropped.
5. **Decisions are logged with their source.** Every threshold, mapping, exclusion and unit conversion goes to the decision log, tagged `source: user | default | inferred`. Decisions still on `default`/`inferred` are listed at the top of the final report as **unconfirmed decisions**. For each such decision that the user cannot settle at Stage 0, also report the headline result under the main alternative (at most 2 alternatives) and state whether the headline conclusion flips — with the flip criterion (direction, ranking, crossing a management target) fixed at Stage 0, before seeing the results. Never pick the convenient alternative after seeing the numbers: the user chooses for substantive reasons, logged `source: user`. "Does not flip" means robust only within the alternatives compared. (The Stage 4 sensitivity counts are one instance of this; the canonical statement is in `data-analysis-check` 手順1.) Do not hand-write `decision_log.md` as prose: the script generates it from its CONFIG block and runtime count variables, so logged numbers cannot diverge from the actual run (the reasons — the "why" — are strings written in CONFIG that the script emits verbatim).
6. **Fail closed.** Unmapped label → **stop by default**: show the unmapped labels with counts and let the user decide (extend the mapping table, or quarantine). Quarantine only on the user's decision, logged with `source: user`. Unparseable datetime → quarantine, not silent coercion. Imputation is off unless explicitly configured with a reason.
7. **One-off analysis = single-file linear code, one file per unit of human review.** No reuse-premised modularization. With a single input source, the whole pipeline is one `pipeline.py`. With several sources, each source gets its own normalization script (`normalize/<source_id>.py`, Stages 1–3 for that source only), and everything after the data reach the shared schema is one `integrate.py`. Each of these files individually follows the single-file, linear rules. Scripts never import from each other; shared knowledge (code tables, crosswalks, label mappings) lives in versioned CSV inputs, never in shared code. Start each file from `templates/pipeline_template.py`.
8. **CSV outputs are UTF-8 with BOM.** So they open correctly in Excel on Windows (no mojibake for Japanese labels): Python `encoding="utf-8-sig"`, R `readr::write_excel_csv()` (or base `write.csv(..., fileEncoding = "UTF-8-BOM")`). Read inputs BOM-tolerantly (`utf-8-sig` / readr default) so a BOM'd file round-trips.

---

## Code style (applies to every script this skill produces)

- **Comment what each block does** — its purpose and the judgment behind it, not syntax narration. The reader is a human (the user) checking the analysis, possibly months later.
- **Disposable, flat, single file** (user's rules, 2026-11-24 / 2026-11-27). No reuse-premised abstraction, frameworks, or external config files; parameters live in one CONFIG block at the top. Write like the pandas and tidyverse documentation examples: one operation per line, every intermediate product (data frame etc.) kept in a meaningfully named variable and inspectable at each step (print `shape` / `head()` / key-column sums). Never bury intermediate state inside nested one-liners, long method chains, composed expressions, or helper internals — the intermediate state is what gets verified.
- **One normalization script per source, confirmed before the next** (user's rule, 2026-11-28). With multiple input files, write one dedicated script per source file, even when two sources look alike: copy the previous script and edit it, so the diff between the two scripts records how the sources differ. Do not process a folder in one pass, loop over sources inside one script, or add a `--source` switch. Each script reads only its source and writes `normalized/<source_id>.csv` in the shared schema plus `normalized/<source_id>_ledger.md` (n_in / kept / excluded / quarantined, numeric column totals before and after, sha256 of the raw file and of the script). Shared lookup tables are versioned inputs; a script never edits them.
- **Reconcile against the original, then advance.** Work on at most two sources at a time, in input-register order. After running a source's script, stop and show the user its reconciliation against the original file: row count, every numeric column total against the original's own total row (or the Stage 1 anchor), and at least 3 cells traced by hand, one near an exclusion boundary. Start the next source only after the user marks this one `confirmed` in the input register, with the date. A fix to a confirmed source's script resets it to `unconfirmed`.
- **Plain `for` loops; functions only when the same operation literally repeats.** Write repetition over processing units (files, species, sites, years) as an explicit `for` loop the reader can step through line by line. Whole-column vector operations stay as one-line vector operations; whether a row-wise loop is needed is decided by the meaning of the operation.
- **Manually reproducible, with a procedure document.** Every transformation must be expressible as operations a human could perform by hand in Excel — sort, filter, lookup against a mapping table, pivot, a computed column (same-row arithmetic, previous-row reference), moving rows aside — even when the row count makes it impractical in practice. No cleaning/shaping step that only a black box can perform. A procedure document (`procedure.md`) is always shipped: draft the steps at Stage 0 for approval (definitions only — counts are not known yet), then emit the final version after the run with each step carrying its checkpoint count from the ledger ("after this step you should have N rows"), so a manual worker can verify their progress against the script's run.

## Stage 0 — Specification

The specification (definitions — saved as `spec.md`) is what gets approved before code. It is **not** `procedure.md`: the manual procedure document carries checkpoint counts that only exist after the run, so its final version is emitted after execution (see Code style).

Before any code, write down and confirm (this table is the pipeline-side view of the canonical spec list in `data-analysis-check` 手順1 — the items are the same):

| Item | What to fix |
|---|---|
| Input | File(s), version/date, source, row unit (1 row = what?). For each candidate source: listed / received (identifiable version) / selected, with the reason for any hold or exclusion; original producer, acquisition source and date, and observation period when they differ; whether the terms of use cover this analysis |
| Column roles | Classify every column (taxonomy from Anthropic's explore-data): Identifier / Dimension / Metric / Temporal / Text / Boolean / Structural — plus the unit for each Metric |
| Analysis unit | The grain of the final table (e.g. site × week, individual × day) |
| Denominators | What every rate is divided by (effort, exposure, population) and where it comes from |
| Exclusions | Known invalid records and the rule that identifies them |
| Missing policy | Per column: exclude / impute (how) / flag — decided now, not mid-code |
| Datetime | Expected format(s), `dayfirst`, timezone |
| Dedupe key | The key that makes two rows "the same record" (or: exact-duplicate handling only) |
| Eventization | Gap threshold, anchor, boundary (`>=` vs `>`) — **no defaults**: if not declared, ask |
| Effort | How exposure is counted, and the minimum-effort rule |
| Unobserved cells | Unit × period cells not observed are `NA`, never `0` |
| Stakes tier | 通常 / 重要 / 間違いが許されない (tiers defined in `data-analysis-check` 手順1) — decides how much of Stage 6 is mandatory |
| Language | Python or R |

The per-source states in the Input row are tracked in an **input register**: one row per candidate source (source id; state — listed / received / selected, and `confirmed` once that source's normalized output has been reconciled against the original; reason for any hold or exclusion; sha256 of the received file). Keep it as a section of `spec.md`, or as `input_register.csv` beside it when the source count is large. This register is the only place source states are defined; per-source scripts run in input-register order (see Code style), and only `confirmed` sources enter integration.

Done when the user can answer, in their own words, the three gate questions of `data-analysis-check` 手順1: what was excluded (WHERE), the numerator/denominator of every metric, and the join keys and grain (does a join multiply rows?).

## Stage 1 — Audit (inspect only, modify nothing)

Produce an audit table:

- Row/column counts; exact-duplicate row count
- Per column: fill rate, distinct-value count, top values
- **Read everything as string first** (`keep_default_na=False` / explicit `na_tokens`, `dtype=str`): spreadsheet libraries silently convert `""` and `"NA"` to null, which corrupts audit counts (e.g. a literal "NA" label disappears), and numeric coercion drops leading zeros from codes (municipality / mesh / individual IDs)
- **Encoding**: Japanese administrative data is often CP932 (Shift_JIS), not UTF-8. Detect it, and record the encoding actually used in `audit.md` — never hard-assume. Record each input file's sha256 in the decision log's data-version entry
- **Excel inputs**: sheet list, merged cells, multi-row headers, hidden rows/columns, date serial values, fullwidth digits
- Datetime columns: how many distinct formats are present
- Numeric columns: parse-failure count, min/max, impossible values, **and the column total** (the pre-cleaning anchor that later stages reconcile against)
- Category columns: full distinct-label list (this feeds the mapping table)
- Key columns: uniqueness check
- Grain: whether each source exposes records at the declared analysis unit; if only a summary exists, state which analyses it cannot support

Output: `audit.md`. Do **not** clean in this stage.

## Stage 2 — Cleaning (execute the plan, count everything)

In order, printing counts after each operation:

1. Exact duplicates: report the count and examples in `audit.md` first. Whether they are dropped is a Stage-0 specification decision (in count data, two identical rows can be two legitimate individuals) — log it in the decision log. Dropped duplicates go to `excluded_rows.csv` with reason `EXACT_DUPLICATE`, so the count invariant still balances. If a dedupe key is declared, dedupe on it and report n.
2. Parse datetimes with mixed-format parsing. Unparseable values → `excluded_rows.csv` with `status=quarantined` and reason code `UNPARSEABLE_DATETIME` (do not assert-crash, do not coerce silently). Record which format parsed each row when formats are ambiguous (e.g. 03/04 — declare `dayfirst` and the timezone in the specification).
3. Normalize categories: mechanical preprocessing (NFKC/strip/casefold) → mapping table built from the Stage-1 label list. Distinguish **known-unknown** labels (the source deliberately wrote 不明/unknown — exclude with code `UNKNOWN_LABEL`) from **unmapped** labels (not in the table — fail closed: stop by default and let the user decide, per principle 6; never drop silently).
4. Coerce numerics; report parse failures per column.
5. Apply the Stage-0 missing policy per column; report rows affected per column.
6. **Dedupe again after normalization** on the declared key: the same record written in two datetime formats or two label variants survives raw dedupe and must be caught here.
7. **Validate rules** from the specification (ranges, referential integrity, records inside their exposure period). Violations are flagged or quarantined with reason codes.

Output: `clean.csv` (new file; raw untouched).

## Stage 3 — Normalize & shape

- Canonical column names; one name per concept across all files.
- Unit conversions applied once, recorded in the decision log (original unit → analysis unit).
- Reshape to tidy form for the declared analysis unit (long for event data, wide only at presentation).
- **Multi-valued identifiers** (one cell lists several identifiers): keep the observation table at one row per observation, with its raw value and source locator (file + version; sheet + cell for a spreadsheet, row number in the raw file for CSV). Build a separate link table, one row per observation × identifier. Assert and print: observation key unique; (observation key, identifier) unique; every link-table key exists in the observation table; link-table rows = sum of identifiers per observation; count of values matching more than one candidate (stop and show them). Measures stay in the observation table only. Aggregating by a linked identifier requires an allocation rule (count fully in each / split equally / by weight / do not aggregate) fixed at Stage 0 and logged; with none declared, stop. In `procedure.md`, express the split as: computed columns extracting the 1st, 2nd, … value → for each column, filter non-empty rows and copy (observation key, value) to the link sheet.
- **Identifiers that change over time:** keep raw label, canonical label and verified code (as string) in separate columns. When a successor covers a different extent than its predecessor, keep historical and current identifiers in separate columns. Resolve ambiguous codes by namespace + validity period. When a historical identifier cannot be established, do not guess: stop by default and show those records with counts (principle 6); leaving it `NA` and continuing is a user decision logged `source: user`. Record the crosswalk's version, coverage period and unresolved keys in the decision log.
- Joins: assert and print row counts **before and after** every join; an unexplained row gain/loss stops the pipeline. Also stop on a degenerate join: 0 matched rows, or a key match rate far below what the specification or the Stage 1 audit leads you to expect (e.g. under 5% when most keys should match). A join that silently matches almost nothing is a failure, not an empty result — record the observed match rate in the decision log.
- `integrate.py` reads only sources marked `confirmed` and stops if a normalized file's or its script's sha256 differs from the value recorded at confirmation. It then runs the cross-source checks no single-source review can see: records duplicated across sources, mixed revisions of the same period, and a per-source total series flagging year-on-year jumps beyond the threshold fixed in spec.md.

## Stage 4 — Analysis table

- Aggregate to the declared analysis unit.
- **Eventization (optional, parameterized):** when near-duplicate events in time must be collapsed (e.g. a 30-minute independence rule): group keys + time column + gap threshold. Declare the **anchor** (`last_kept`: gap measured from the last kept event — or `last_record`: from the previous record) and the boundary (`>=` vs `>`); the counts differ by anchor, so an undeclared anchor is a hidden decision. Keep `source_row_ids` on each event so it stays traceable to the raw rows. Report records → events and n collapsed, plus counts at 1–2 alternative thresholds (sensitivity) so the reader can see whether conclusions depend on the choice.
- **Denominator/effort table (when rates are computed):** build the exposure table separately (e.g. trap-nights, observation days, person-time). State the counting convention explicitly (`nights = (end − start).days` vs `days = +1` — they differ by one and both appear in the wild). Apply declared minimum-effort rules (flag below warning level, exclude below hard minimum) and state them in the log. Never report a rate whose denominator table does not exist.
- **Matrix outputs:** a unit × period cell that was **not observed** (unit inactive that period) is `NA`, never `0`. `0` means observed and absent. Filling unobserved cells with 0 manufactures false absences and biases occupancy/detection estimates.
- Sanity: check the final table's dimensions against the specification (n units × n periods).

Output: `analysis_table.csv` (+ `effort_table.csv` when applicable).

## Stage 5 — Analysis & figures

- Descriptive statistics first (n, distribution, missingness of the analysis table itself).
- Inferential work: hand off to the dedicated skills — `statistical-analysis`, `pymc` (Bayesian), `occupancy-and-detection` / domain skills where relevant.
- Figures: hand off to `scientific-visualization`. Every figure states what was filtered out.
- **Spreadsheet deliverables** (rule from Anthropic's xlsx skill): write formulas, never hardcoded computed results, so the sheet recalculates when inputs change; document every assumption and hardcoded number where the reader can see it; ship zero formula errors — and remember a clean recalculation proves formulas *evaluate*, not that they are *right*, so spot-check that a few formulas pull the expected values.
- **Notebook deliverables** (convention from OpenAI's jupyter-notebook skill): small runnable cells, each with a short note of purpose and expected result; validate by running top to bottom; if execution is impossible, say so explicitly. Notebooks are for this stage only (descriptive statistics and figures): Stages 1–4 live in `pipeline.py`, or in the per-source scripts plus `integrate.py`, and a notebook's only input is `analysis_table.csv` — never clean or reshape inside a notebook. The code style above applies to notebook code too.

## Stage 6 — Verification

Run the companion `data-analysis-check` skill's 11-item verification on the result, including:

- Count reconciliation: raw → clean → analysis table, every difference explained by a logged rule
- Independent recalculation of one headline number by a different route
- Known-truth check: a few values (at least 3, one of them near an exclusion boundary) verified by hand from the raw file
- Subtotals sum to totals; percentages to ~100% where they should
- Named pitfall sweep (catalog from Anthropic's validate-data, plus the domain pitfalls of `data-analysis-check`): **join explosion** (row gains at joins), **denominator shifting** (the base changes between compared numbers), **average of averages**, **incomplete-period comparison**, **timezone mismatch**, **survivorship / selection bias** (exclusions correlate with the outcome), **version mixing** (concatenating different revisions of retroactively updated statistics), **fiscal vs. calendar year mismatch**, **unit scale error** (ha vs. km², 0–1 vs. %)

**Zero-base re-implementation (stakes tier 間違いが許されない only** — published estimates, government submissions): follow `data-analysis-check` 手順4 exactly; it is the canonical text. Pipeline-specific additions: compare the count ledger at **every stage** (raw → dedupe → parse → normalize → analysis table) and diff `analysis_table.csv` cell by cell. Never give the re-implementer the original code, **its ledger counts, or `procedure.md`** — counts shown in advance turn re-implementation into tracing. Agreement proves the implementation matches the specification, not that the specification is right (when both models err, they produce the same wrong answer ~60% of the time — the conditional figure defined in `data-analysis-check` 項目11), so one anchor outside the system is still required.

**"Passes" means:** every verification-table row is OK, or NG with an explanation the user has accepted; no `default`/`inferred` decision remains unconfirmed without the user's sign-off; and `procedure.md`'s checkpoint counts match the ledger. The pipeline is not done until Stage 6 passes.

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
  spec.md            # Stage 0 specification (definitions approved before code)
  verification.md    # Stage 6 verification table + results (data-analysis-check 手順5 order)
  report.md          # final report, when one is produced
  fixtures/          # known-answer test data with planted defects
  pipeline.py        # single-source jobs: the single-file script that produced everything above
  normalize/         # multi-source jobs: one normalization script per source (normalize/<source_id>.py)
  normalized/        # multi-source jobs: per-source normalized tables + their ledgers
  integrate.py       # multi-source jobs: combines confirmed sources, then Stages 4–6
  input_register.csv # multi-source jobs: per-source states (or a section of spec.md)
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
- Data version of the inputs (including each file's sha256 and the encoding used)
- Missing policy per column; datetime format(s), timezone, `dayfirst`
- Dedupe key and the exact-duplicate decision; eventization anchor and boundary; effort counting convention
- Labels merged by mechanical normalization (the full raw→normalized list)
- Allocation rule for multi-valued identifiers; crosswalk version, coverage and unresolved keys

## Anti-patterns (stop and fix if you catch yourself)

- `dropna()` or filtering without printing how many rows went and why
- Guessing what an unknown category label means
- Overwriting or "fixing" the raw file
- Reporting a rate without its denominator table
- Splitting a one-off analysis into modules/packages for hypothetical reuse
- Normalizing many sources in one script or loop and checking only the combined result
- Presenting results before the Stage-6 count reconciliation

## Template

`templates/pipeline_template.py` — a single-file, top-to-bottom implementation of
Stages 1–4 with a CONFIG block at the top (input path, column roles, mapping
tables, eventization and effort parameters). The template is a **draft to edit
directly**, not a generic engine: copy it into the project as `pipeline.py`,
delete the stages the job does not use, write data-specific steps inline in
ベタ書き style, and do not grow CONFIG flags or branches to cover new cases.
Fill CONFIG, and run. It prints the count ledger and writes
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
- baratadiego, [ecological-agent-skills](https://github.com/baratadiego/ecological-agent-skills) (camera-trap-processing: independence threshold, effort rules, detection history)
