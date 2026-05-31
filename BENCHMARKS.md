# Benchmarks

This document describes how `swift-parsing` measures parser performance, what "engine parity" means and
how it is compared, and the policy for gating performance regressions in continuous integration.

The benchmarks are opt-in: the `ParseBenchmarks` target and the `ordo-one/package-benchmark` dependency
are added to the package only when the `BENCHMARK` environment variable is set, so a normal build, the
cross-platform matrix, and the shipped libraries never resolve or compile them.

## Running

```sh
BENCHMARK=1 swift package benchmark
```

The harness records four metrics per benchmark, so both speed and allocation behaviour are tracked:

| Metric              | What it captures                                                      |
| ------------------- | -------------------------------------------------------------------- |
| `wallClock`         | Median time to parse one input.                                      |
| `throughput`        | Parses per second (the headline figure for comparing engines).      |
| `mallocCountTotal`  | Total allocations per parse (the green-tree and forest allocations). |
| `peakMemoryResident`| Peak resident memory during a run.                                   |

Engine construction (table generation, ATN build) happens outside `startMeasurement()`, so the figures
reflect steady-state parsing of identical input, not one-off setup.

## The parity matrix

The core of the suite parses the **same large input** for each real language with **each native engine**,
so their throughput and allocation are directly comparable on equal footing:

| Language | Input size                | Recursive descent | GLR (RNGLR) | ALL(\*) |
| -------- | ------------------------- | :---------------: | :---------: | :-----: |
| JSON     | 1024 objects (mixed kinds)| ✓                 | ✓           | ✓       |
| Lua      | 256 functions             | ✓                 | ✓           | ✓       |
| C        | 256 functions             | ✓                 | ✓           | ✓       |

Each generated input is realistic mixed source (every value kind for JSON; declarations, loops, tables,
conditionals and a spread of the operator ladder for Lua and C) rather than a single construct, so the
numbers reflect representative work rather than a micro-pattern. Two reference-engine smoke cases (a small
JSON input and the Unicode-scalar granularity) give a fast signal on small inputs and on the cost of a
wider input element.

All three engines produce byte-identical trees for these inputs (the three-engine differential contract),
so the matrix compares the *cost* of three algorithms computing the *same* result:

- **Recursive descent** is the reference: a single-pass, allocation-lean top-down parser, expected to be
  the throughput leader on the unambiguous grammars used here.
- **GLR (RNGLR)** carries the graph-structured stack and shared packed parse forest, so it trades
  throughput for the ability to handle ambiguity and (now) reuse unchanged subtrees across edits.
- **ALL(\*)** pays for adaptive prediction (a lookahead DFA cache) up front, then approaches recursive
  descent once the cache is warm; it is the engine that handles directly left-recursive grammars.

Reading the matrix as a ratio against the recursive-descent column is the parity check: it quantifies what
each engine's extra capability costs on input that needs none of it.

## CI regression policy

The `Benchmarks` CI job runs `BENCHMARK=1 swift package benchmark --no-progress` on every pull request, so
a change that fails to build or crashes a benchmark is caught immediately. Absolute timings are
machine-specific (CI runners differ from developer machines), so the gate is **relative**, against a
baseline captured on the CI runner itself:

1. Capture a baseline once on the CI runner and commit it (package-benchmark stores it under the package's
   benchmark baseline directory):

   ```sh
   BENCHMARK=1 swift package benchmark baseline update ci
   ```

2. Gate pull requests on deviation from that baseline:

   ```sh
   BENCHMARK=1 swift package benchmark baseline check ci --no-progress
   ```

The recommended tolerances, applied to the `p90` of each metric so a single noisy sample does not fail a
run, are:

| Metric              | Tolerance (p90 regression) | Rationale                                             |
| ------------------- | -------------------------- | ----------------------------------------------------- |
| `throughput`        | 10 %                       | The headline figure; a real slowdown should be small. |
| `wallClock`         | 15 %                       | Noisier than throughput on shared runners.            |
| `mallocCountTotal`  | 0 %                        | Allocation count is deterministic, so any change is a regression to review. |
| `peakMemoryResident`| 20 %                       | Coarse and allocator-dependent; a wide band avoids flakes. |

A zero-tolerance band on `mallocCountTotal` makes an accidental per-parse allocation (for example losing
the green-tree reuse on an edit, or a stray array copy in a hot path) a hard failure, which is the most
valuable signal the suite provides. The baseline is refreshed deliberately, in its own commit, whenever an
intended performance change moves the numbers, so the gate always compares against an agreed reference.
