# Decisions

Why the audits are shaped this way, what was reversed, and what a measurement retracted.
Decisions about the pipeline that consumes the contract — training, the promotion gate,
scoring, infrastructure — are in [`fraud-detection-mlops`](https://github.com/jjabuk/fraud-detection-mlops/blob/main/DECISIONS.md).

Where borrowed ideas came from: [ATTRIBUTION.md](ATTRIBUTION.md).

---

## 2026-08-19 — The audits move to R, and stop using a model to measure a column

**Decision.** The four audits that decide which columns reach the model are rewritten as
statistics and moved to a separate repository, an R package with its own dependency graph, tests and
reports. `evaluation/{time_consistency,distribution_shift,redundancy,segment_qualification,
selection}.py` are deleted — about 1,340 lines. `entity_purity` stays in Python, trimmed to
the entity key itself. The contract is now produced by `uv run stamp-contract` from the
fragments the audits write.

**What was wrong with what was there.** Four of the six audits used LightGBM. Two of them
used it as a *measuring instrument*: `time_consistency` fitted a gradient boosting model per
single column and read its AUC in two windows, and `distribution_shift` trained a classifier
to tell the periods apart. Both answer real questions. Neither answer can be inspected — the
direction the fit learned is not recoverable, a rejection cannot be explained to anyone who
has to approve the feature set, and the verdict depends on hyperparameters that have nothing
to do with the data.

**What replaced them.** A weight-of-evidence table is also a learned, possibly non-monotone
mapping from values to a fraud ordering, and it prints as eleven rows. The AUC of a
WoE-scored window is still the Mann–Whitney statistic, so the numbers stayed comparable.
Adversarial validation is a two-sample test with a model inside it; the energy test is the
same test without one, and returns a p-value instead of an AUC. Where the previous code read
a threshold off a point estimate, the new code runs a test: DeLong intervals, a
Benjamini–Hochberg correction across the scan, and a stated effect size.

**One verdict, not two.** The report briefly carried both the tested verdict and a
margin-based one kept for comparability with the fixture. That was a second policy living
in production code to serve a historical check. The margin rules now exist only inside
`test-golden.R`, reconstructed from the AUCs; the report carries the verdict the contract
acts on and nothing else.

**Validated before deleting, and the validation is finished.** The old implementation's
report was held as a fixture and the R code was asserted against it: identical window row
counts (100,392 / 100,393), **96.0% verdict agreement over 377 columns**, median absolute
AUC difference 0.0014 on the early window and 0.0014 on the late one, correlation 0.969.
Every column the new implementation rejected and the old one passed was required to show
the reversal in its weight-of-evidence table.

That was a one-time check of a one-time event, and it has been paid out. The fixture and
its test are gone; what they established is recorded here. All fifteen disagreements:

| Column | Old | Old AUC early → late | New | New AUC early → late |
| --- | --- | --- | --- | --- |
| V150 | pass | 0.629 → 0.529 | **inverted** | 0.565 → 0.467 |
| V151 | pass | 0.602 → 0.508 | **inverted** | 0.565 → 0.467 |
| V152 | pass | 0.614 → 0.506 | **inverted** | 0.565 → 0.467 |
| V331 | pass | 0.579 → 0.483 | **inverted** | 0.569 → 0.478 |
| V56 | pass | 0.556 → 0.489 | **inverted** | 0.527 → 0.444 |
| V77 | pass | 0.557 → 0.541 | **inverted** | 0.531 → 0.468 |
| V78 | pass | 0.568 → 0.548 | **inverted** | 0.531 → 0.468 |
| V86 | pass | 0.573 → 0.563 | **inverted** | 0.533 → 0.466 |
| V87 | pass | 0.586 → 0.572 | **inverted** | 0.532 → 0.466 |
| V130 | pass | 0.570 → 0.535 | weak | 0.517 → 0.514 |
| V135 | pass | 0.521 → 0.492 | weak | 0.515 → 0.497 |
| V137 | pass | 0.525 → 0.512 | weak | 0.518 → 0.497 |
| V319 | pass | 0.522 → 0.491 | weak | 0.513 → 0.494 |
| V26 | inverted | 0.533 → 0.464 | pass | 0.519 → 0.459 |
| V305 | weak | 0.500 → 0.500 | degenerate | not estimable |

The nine promoted to `inverted` are the substantive difference. `V150` is the clearest:
its two upper bins are **empty** in the later window — nothing takes those values any more
— and the weight of evidence of the bin that survives flips from −0.30 to +0.49. The
gradient boosting fit smoothed over that; a table of eleven bins cannot.

**Why the fixture is not kept as a regression test.** Its baseline is a deleted
implementation, so the test fails whenever the R code legitimately improves — a test whose
failure mode is "you made this better" is a test that punishes the work it is supposed to
protect. The receipt is above; re-executing it on every CI run would not make it more true.

**What the move found that the old code could not.**

- The conventional PSI threshold of 0.25 sits about **700× above the noise floor** measured
  at these sample sizes. 469 of 472 columns shift significantly; 191 shift materially. A
  threshold nobody had a null distribution for was doing all the work.
- `M7`, `M8` and `M9` have among the largest indices in the table and almost none of it is
  about their values — each became ~45pp *more populated*. Decomposing the index into
  missingness and values separates "became unreliable" from "started being collected".
- **181 columns** reach a pooled AUC of up to 0.74 and are constants inside the product
  segment carrying 57% of the traffic. Cochran–Mantel–Haenszel names that directly where an
  AUC gap against a threshold did not.
- Correlation alone would drop 188 columns; redundancy analysis says only 78 of them are
  actually reconstructable from their neighbours.

**Cost, stated.** A second toolchain, a second lockfile, a second CI job. It is worth it
because the statistics are the deliverable — if R were only redrawing the same charts, it
would not be.

**The fourth thing, and the one that mattered.** After the first three were fixed the
contract *still* changed between runs, and the cause was not in this code at all: a
filtered Arrow scan is multi-threaded and does not promise to return rows in file order.
Two runs get the same rows in a different sequence.

Nothing that reads every row notices. An AUC is a rank statistic and a PSI is a bin count;
both are invariant to row order, which is why the time-consistency and drift fragments were
byte-identical across runs and looked like proof that everything was fine. Every audit that
*subsamples* was affected, because `set.seed(0); sample.int(n, k)` picks the same positions
out of a different ordering and therefore a different sample — so the redundancy audit, and
with it the admitted set, moved between identical runs of identical code on identical data.

`load_windows` now sorts on the time axis with the identifier breaking ties, restoring the
file's own order. The test asserts the property rather than trying to reproduce the race.

The lesson is not about Arrow. It is that "seeded" and "reproducible" are different claims,
and the gap between them is invisible in any output a person reads.

**Three things this got wrong first, all caught by the same check.** The `targets` graph
and the notebooks both write fragments, so `stamp-contract --check` compares the committed
contract against what the fragments on disk stamp to. It failed three times, and each
failure was real:

1. *Two copies of the policy.* The graph and the notebooks each carried their own
   thresholds. Every threshold now lives in the audit repository's `R/policy.R` and is sourced by both —
   the same argument this decision rests on, applied to the thing meant to enforce it.
2. *Duplicated keys in a fragment.* `c(list(alpha = ...), params)` keeps both copies when
   `params` already has `alpha`, and the duplicate came back on the next read as `alpha.1`.
   `modifyList` overrides instead of appending.
3. *A representative chosen by row order.* Members of a redundancy group frequently tie on
   null rate and information value to four decimals, and the winner was whichever the input
   listed first — so the same data produced a different contract depending on whether the
   upstream report arrived from memory or from a CSV. The tiebreak is now the column name:
   still arbitrary, but stated and stable.

None of these would have surfaced from reading the code, and none would have been visible
in a report. They surfaced because a fingerprint over the admitted set is compared against
a freshly stamped one, which is the same mechanism that catches a hand-edited contract.

**What did not move.** The entity key, because it is a transformation the training job runs
and the gate's cold-entity segment depends on, not a question about the data. The
fingerprint, because `FeatureContract.from_dict` refuses a file whose stored hash disagrees
with its contents, and that detector should not depend on two JSON serialisers agreeing
forever. One writer, one hash.

---
