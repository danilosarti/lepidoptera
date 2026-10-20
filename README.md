# lepidoptera

[![CRAN](https://www.r-pkg.org/badges/version/lepidoptera)](https://CRAN.R-project.org/package=lepidoptera)
[![PyPI](https://img.shields.io/pypi/v/lepidoptera)](https://pypi.org/project/lepidoptera/)
[![arXiv](https://img.shields.io/badge/arXiv-2501.08242-b31b1b)](https://arxiv.org/abs/2501.08242)

**Documentation:** https://danilosarti.github.io/lepidoptera/

A generic, domain-agnostic simulation engine based on **Structural Causal Models (SCMs)**.

Define any system as a Directed Acyclic Graph (DAG) of typed features, attach
generative mechanisms to each node, simulate populations, and apply causal
interventions that propagate downstream automatically.

---

## What lepidoptera does

| Capability | Detail |
|---|---|
| **Feature types** | Continuous, categorical, ordinal — each with typed domains |
| **DAG structure** | Declare features and dependencies; topological order is derived automatically (Kahn's algorithm) |
| **Mechanism library** | 8 pre-built factories: `normal`, `categorical_marginal`, `ordinal_marginal`, `linear_gaussian`, `group_effect`, `multinomial_logit`, `ordered_logit`, `copula_mechanism` |
| **Custom mechanisms** | `register_mechanism(name, fn, parent_types, output_type)` — any R/Python function |
| **Reproducibility** | Per-unit independent seeds derived from a single base seed |
| **Interventions** | `do_fix`, `shift`, `mechanism_override`, `do_distribution` |
| **Propagation** | `propagate()` re-samples the downstream BFS closure; returns baseline + intervened populations |
| **Comparison** | `compare()` summarises differences between baseline and intervened populations |
| **Portability** | `export_system` / `import_system` (JSON); Python mirror with identical API |
| **AI mechanisms** | `llm_mechanism()` (OpenAI), `learned_mechanism()` (data-fitted) |

lepidoptera knows nothing about any specific domain. Any domain knowledge
lives in the mechanisms and DAG structure you define on top of the engine.

---

## Repository structure

```
lepidoptera/
├── r-pkg/                        # R package (reference implementation)
│   ├── R/
│   │   ├── type-system.R         # Feature types and domain validation
│   │   ├── graph.R               # DAG, topological sort, BFS closure
│   │   ├── mechanism.R           # Mechanism library and register_mechanism()
│   │   ├── copula.R              # Gaussian copula mechanism
│   │   ├── system.R              # System builder and finalization
│   │   ├── simulate.R            # Population sampling
│   │   ├── intervention.R        # Interventions and propagate()
│   │   ├── io.R                  # JSON export / import
│   │   ├── plot.R                # DAG visualisation
│   │   └── ai.R                  # LLM and learned mechanisms
│   ├── tests/testthat/           # 13 passing tests (FAIL 0, WARN 0, SKIP 1*)
│   ├── DESCRIPTION
│   ├── NAMESPACE
│   └── lepidoptera.Rproj
│
├── python/                       # Python mirror (identical API)
│   ├── src/lepidoptera/
│   └── tests/
│
├── examples/
│   ├── pneumology-ward/          # Example: hospital ward built on lepidoptera
│   │   ├── hospital_emergency_sim.R   # Triage simulation (causal scenarios)
│   │   ├── digital_twin_ward.R        # Hourly Markov ward engine
│   │   └── ward_app.R                 # Shiny interface (dark theme, gamification-ready)
│   └── clinical-trials/          # Example: Phase III RCT simulation
│       └── rct_simulation.R           # ITT, per-protocol, enrichment, subgroup scenarios
│
├── lepidoptera_training.pptx     # 18-slide deck: engine + pneumology example
├── SPEC.md                       # Full design specification
└── README.md
```

*The skipped test requires the optional `rvinecopulib` package for vine copulas.

---

## Quick start (R)

```r
# Install
devtools::install("r-pkg")

library(lepidoptera)

# 1. Define a system
sys <- new_system() |>
  add_feature(feature_spec("x", "continuous", list(min = 0, max = 100))) |>
  add_feature(feature_spec("group", "categorical", list(levels = c("A", "B")))) |>
  add_feature(feature_spec("y", "continuous", list(min = 0, max = 200))) |>
  add_dependency(character(0), "x",
    mechanism_library_get("normal")(mean = 50, sd = 15)) |>
  add_dependency(character(0), "group",
    mechanism_library_get("categorical_marginal")(
      levels = c("A", "B"), probs = c(0.6, 0.4))) |>
  add_dependency(c("x", "group"), "y",
    mechanism_library_get("group_effect")(list(
      A = list(mean = 80, sd = 10),
      B = list(mean = 120, sd = 15)))) |>
  finalize_system()

# 2. Simulate a population
df <- simulate(sys, n = 1000, seed = 42)

# 3. Apply an intervention and compare
result <- propagate(sys,
  interventions = list(do_fix("group", "B")),
  n = 1000, seed = 42, mode = "partial")

compare(result)
```

---

## Examples

### Pneumology ward (`examples/pneumology-ward/`)

An 11-variable hospital DAG (age → comorbidity → pneumonia → vitals → severity →
ICU → outcome) with causal intervention scenarios, an hourly Markov digital twin,
and a Shiny app for clinical training and gamification.

```r
setwd("~/lepidoptera/lepidoptera/examples/pneumology-ward")
source("hospital_emergency_sim.R")   # triage simulation
shiny::runApp("ward_app.R")          # interactive digital twin
```

### Clinical trials (`examples/clinical-trials/`)

A Phase III RCT of a novel antihypertensive drug. The 9-variable DAG covers
patient characteristics, randomized treatment assignment, adherence, side effects,
and a week-12 BP endpoint. Four scenarios demonstrate the full lepidoptera
intervention API:

| Scenario | Intervention | Causal question |
|---|---|---|
| ITT | `do_fix("treatment", "active")` | Average Treatment Effect as randomized |
| Per-protocol | `do_fix` + `mechanism_override("adherence", ...)` | Efficacy under full adherence |
| Enrichment | `do_fix` + `shift("baseline_bp", +15)` | Effect in severe-hypertension cohort |
| Elderly subgroup | `shift("age", +20)` + `do_fix` | Does ATE differ in elderly patients? |

```r
setwd("~/lepidoptera/lepidoptera/examples/clinical-trials")
source("rct_simulation.R")
```

---

## Design specification

See [`SPEC.md`](SPEC.md) for the full specification: data model, type combinations,
copula mechanism, propagation algorithm, and R/Python API contract.
