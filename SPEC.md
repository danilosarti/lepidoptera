# lepidoptera — Package Specification

Document version: 0.1 (foundational draft)  
Status: proposal for validation — no code implemented yet  
Planned implementations: R and Python, in parallel, with API parity

---

## 1. Overview

`lepidoptera` is a generic, domain-agnostic simulation engine. It models no specific domain — it knows nothing about epidemiology, economics, biology, etc. What it does:

1. Represent a **system** as a set of **features** (variables) with heterogeneous types (continuous, categorical, ordinal).
2. Represent **a priori dependencies** between those features as a graph.
3. Define, for each dependency, a **mechanism** (function/rule) describing how a feature's value is generated from its parent features' values.
4. Generate (simulate) populations of units from that system.
5. Apply **interventions** on one or more features and **propagate** their effects through the dependency structure, recomputing everything affected downstream.

The long-term vision is that `lepidoptera` serves as the infrastructure layer ("backstage") on which domain-specific simulation solutions are built — without reinventing dependency representation, mixed types, and intervention propagation for every new project.

### 1.1 Design principles

- **Domain-agnostic.** Nothing in the core knows what a feature "means". Domain semantics are the responsibility of whoever uses the package on top.
- **Mixed types as first-class citizens.** Continuous, categorical, and ordinal must be supported in any parent→child combination, with no special handling in user code.
- **Explicit structure, explicit mechanism.** The dependency graph and value-generation rules are first-class objects — inspectable and serialisable — not anonymous functions hidden away.
- **Intervention as a central operation.** The system is not just for "running a simulation", but for asking "what changes if I intervene here?" — this must be cheap and well-defined.
- **R/Python parity.** Both implementations share the same conceptual model, the same function names (adapted to each language's idiomatic conventions), and must produce equivalent results given the same seed.
- **v1 simple, v2 extensible.** The first version assumes an acyclic graph (DAG) with one-shot propagation. The architecture is designed to later support temporal dynamics and feedback loops without breaking the v1 API.

### 1.2 Out of scope (for now)

- Causal inference from observational data (structure discovery). `lepidoptera` assumes the dependency structure is provided by the user, not discovered.
- Automatic optimisation/calibration of mechanism parameters.
- Graphical user interface. The focus is the library/engine; visualisation is treated as a secondary utility (e.g. graph plot), not as a product.
- Distributed/parallel large-scale simulation (may come later, not a v1 requirement).

---

## 2. Core concepts

| Concept | Definition |
|---|---|
| **Feature** | A variable in the system. Has a name, type (continuous, categorical, or ordinal), and a domain. |
| **Domain** | For continuous: interval (with possible infinite bounds). For categorical: finite set of unordered levels. For ordinal: finite set of ordered levels. |
| **Dependency graph** | A directed graph whose nodes are features. An edge `A → B` means "B depends on A" (A is a parent of B). v1: the graph must be acyclic (DAG). |
| **Mechanism** | The generative rule associated with a feature that, given the current values of its parents (and possibly a noise term), determines the value (or value distribution) of that feature. Root features (no parents) have a marginal mechanism (a base distribution, no inputs). |
| **System** | The complete specification: features + dependency graph + mechanisms for each feature. The simulatable "specification". |
| **Unit** | A single simulated realisation of the system — a vector with one value per feature, generated following the graph's topological order. |
| **Population** | A set of N units simulated independently from the same system. Represented as a table (data frame): rows = units, columns = features. |
| **Intervention** | A modification applied to one or more features of the system (e.g. fixing a value, shifting a distribution, replacing a mechanism) before generating/regenerating a population. |
| **Propagation** | The process of recomputing, in topological order, all features directly or indirectly affected by an intervention, leaving unaffected features intact (or recomputing them consistently when full resampling is used). |
| **Simulation result** | The comparable artefact: baseline population vs. post-intervention population, plus metadata (which features were changed, in what order propagation occurred). |

---

## 3. Data model

This section describes entities in a language-agnostic way. Section 7 maps each entity to concrete classes/functions in R and Python.

### 3.1 `FeatureType`

Closed enumeration: `continuous`, `categorical`, `ordinal`.

### 3.2 `FeatureSpec`

Fields:

- `name: string` — unique identifier within the system.
- `type: FeatureType`
- `domain`: depends on type —
  - continuous: `{min, max}` (may be infinite)
  - categorical: `{levels: [string, ...]}` (unordered)
  - ordinal: `{levels: [string, ...]}` (list order defines scale order)
- `metadata: dict` optional — free space for user annotations (human-readable labels, units, description), never interpreted by the core.

### 3.3 `Mechanism`

A mechanism is the generative function associated with a feature. Two types:

- **Marginal mechanism** (for root features, no parents): a distribution/rule that takes no inputs, only an RNG and parameters. E.g.: Normal(μ, σ) for continuous; categorical distribution with probability vector; ordered multinomial distribution for ordinal.
- **Conditional mechanism** (for features with ≥1 parent): a function `f(parent_values, rng, params) -> value` (or `-> distribution`, from which a value is sampled). The signature receives the current values of **all** declared parent features, as native types (number for continuous, string/factor for categorical and ordinal).

Each mechanism explicitly declares:
- `output_type`: must be compatible with the type of the feature it belongs to.
- `parent_types`: expected types for each parent (used for validation at system assembly time, not at simulation time).

The core provides a **pre-built mechanism library** covering the most common type combinations (see section 4), and allows users to register custom mechanisms (any function respecting the signature).

### 3.4 `DependencyEdge`

- `from: FeatureSpec.name` (parent)
- `to: FeatureSpec.name` (child)

A feature may have multiple parents; in that case, the child feature's `Mechanism` receives all parent values at once (there is no implicit edge-by-edge composition — the mechanism is per-node, not per-edge).

### 3.5 `System`

- `features: {name -> FeatureSpec}`
- `edges: [DependencyEdge, ...]`
- `mechanisms: {name -> Mechanism}` — one entry per feature.
- Invariants validated at construction/finalisation:
  1. Every feature has exactly one mechanism.
  2. The graph induced by `edges` is acyclic (v1).
  3. Every feature referenced in an edge exists in `features`.
  4. The `parent_types` of each conditional mechanism is consistent with the actual types of the parents declared in the edges.
  5. Every feature has at least one valid generation path (roots have a marginal mechanism; non-roots have a conditional mechanism covering exactly their parents).

### 3.6 `Intervention`

- `target: feature name (or list of features)`
- `kind`: one of
  - `do_fix`: fixes the feature at a constant value for all units (classic do-operator), disconnecting it from its parents.
  - `do_distribution`: replaces the marginal/conditional mechanism with a new distribution/function, optionally preserving or dropping parent dependency.
  - `shift`: applies a displacement/transformation to the value that would have been generated by the original mechanism (e.g. +Δ for continuous, level remapping for categorical/ordinal), preserving parent dependency.
  - `mechanism_override`: completely replaces a feature's `Mechanism` with an arbitrary new one.
- `params`: intervention-type-specific data (fixed value, new distribution, shift function, new mechanism).

Interventions are immutable objects applied to a copy of the system (never mutating the original system in-place) — this allows comparing baseline and intervention from the same base specification.

### 3.7 `Population`

A table with one row per simulated unit and one column per feature, plus an implicit unit-id column. Column typing reflects the `FeatureType` (numeric for continuous; factor/category for categorical and ordinal, preserving the declared order for ordinal).

### 3.8 `SimulationResult`

- `baseline: Population`
- `intervened: Population` (same number of units and same base seed as `baseline`, enabling unit-by-unit paired comparison where applicable)
- `interventions: [Intervention, ...]` applied
- `affected_features: [name, ...]` — transitive downstream closure of intervention-target features, in the order they were recomputed
- `propagation_order: [name, ...]` — topological order used

---

## 4. Variable types and dependency combinations

The central requirement: any parent-type → child-type combination must be supportable. This gives 9 binary combinations (3 types × 3 types), plus the case of multiple parents of different types for a single child.

| Parent → Child | Default strategy provided by the core |
|---|---|
| Continuous → Continuous | Parametric function (linear, polynomial, etc.) + configurable additive noise. |
| Continuous → Categorical | Multinomial regression-style: continuous is mapped to per-level probabilities (e.g. via softmax over a linear combination of parents). |
| Continuous → Ordinal | Ordinal regression-style (cumulative logit / proportional odds): continuous shifts the cut-points (thresholds) between ordered levels. |
| Categorical → Continuous | Each parent level associated with a different effect (mean/parameter) on the child's continuous distribution (equivalent to a "group effect"). |
| Categorical → Categorical | Transition table / conditional probability matrix, level-by-level. |
| Categorical → Ordinal | Each categorical parent level associated with a different distribution over the child's ordered levels. |
| Ordinal → Continuous | Ordinal is treated with its numeric code (position in scale) as pseudo-continuous in the generative function, OR per-level effect as in categorical → continuous (user's choice). |
| Ordinal → Categorical | Analogous to categorical → categorical, with the option for the user to exploit the ordering (e.g. monotonic probabilities) if desired. |
| Ordinal → Ordinal | Transition table optionally respecting monotonicity in propagation. |
| Multiple mixed parents → Child (any type) | The mechanism receives the full vector of parent values (each in its native type) and is the mechanism's responsibility to combine effects. The core provides a "mixed-parent encoding" helper (dummy/one-hot for categorical, integer code for ordinal, raw value for continuous) for users who want to build a generic linear/additive combination rather than writing the combination logic by hand. |

Important: the core does **not** require use of these pre-built mechanisms. They exist as convenience (covering the common case without the user having to write a statistical function from scratch). Any custom mechanism respecting the `Mechanism` signature is valid.

### 4.1 Copula mechanism (vine copulas)

In addition to the ad-hoc strategies in the table above, `lepidoptera` provides a **copula mechanism** as a general-purpose dependence engine, covering the full copula family catalogue provided by `rvinecopulib` without reimplementing anything from scratch.

**When to use.** The copula mechanism models the joint dependence between a set of features (a node and its parents) at once, rather than a deterministic parent→child function. Given the parent values of a unit, the child value is obtained by **conditional sampling** within the vine.

---

#### 4.1.1 Back-ends and family routing

`copula_mechanism()` has two execution paths:

| `family =` | Back-end | Extra packages |
|---|---|---|
| `"gaussian"` | Pure Gaussian copula in base R (Spearman correlation via normal scores) | none |
| `"auto"` | **rvinecopulib** with automatic per-pair AIC family selection; silently falls back to Gaussian if package is not installed | `rvinecopulib` (Suggests) |
| any other value | **rvinecopulib** with the specified family/set | `rvinecopulib` required |

---

#### 4.1.2 Supported families (rvinecopulib)

`rvinecopulib` covers 20+ parametric bivariate families, assembled into **vine copulas** (D-vine for the multivariate case) for joint dependence in any dimension.

| Category | Family | `family =` |
|---|---|---|
| Gaussian (base R) | Gaussian | `"gaussian"` |
| Elliptical | Student-t | `"t"` |
| Symmetric Archimedean | Frank | `"frank"` |
| Archimedean (lower tail) | Clayton | `"clayton"` |
| Archimedean (upper tail) | Gumbel, Joe | `"gumbel"`, `"joe"` |
| Two-parameter | BB1, BB6, BB7, BB8 | `"bb1"`, `"bb6"`, `"bb7"`, `"bb8"` |
| Rotations (90°/180°/270°) | Any rotated Archimedean | `"clayton90"`, `"gumbel180"`, … |
| Non-parametric | Kernel (TLL) | `"tll"` |
| Meta-sets | Selects best within a group | `"onepar"`, `"twopar"`, `"parametric"`, `"all"` |
| Automatic selection | Best family per pair via AIC | `"auto"` |

`list_copula_families()` returns the full vector of names accepted by the current installation.

---

#### 4.1.3 Conditional simulation — Rosenblatt transform

To generate `u_child | u_parents` via a vine copula, `lepidoptera` uses the **Rosenblatt transform** available in `rvinecopulib`:

**Variable ordering convention.** Variables are arranged in the pseudo-observation matrix as `c(parents..., child)` — the child **always in the last column**. A D-vine with order `1, 2, …, d` ensures:
```
v[i]   = F(u_i | u_1, ..., u_{i-1})    # depends only on columns to the left
v[d]   = F(u_child | u_parents)        # the conditional we want to sample
```

**Algorithm (multivariate, d ≥ 3):**
1. Build `u_row = [u_p1, …, u_pk, 0.5]` (placeholder `0.5` for the child — does not affect earlier columns in the D-vine).
2. `v_row = rosenblatt(u_row, vine_obj)`.
3. Replace `v_row[k+1] ← runif(1)` — fresh, independent draw.
4. `u_new = inverse_rosenblatt(v_row, vine_obj)`.
5. `u_child = u_new[k+1]` — correctly sampled conditional marginal.

**Algorithm (bivariate, d = 2):**
Uses `hbicop(matrix(c(u_parent, v_child), 1), bicop_obj, cond_var=1, inverse=TRUE)` — exact h-function inversion.

**Decoding.** `u_child ∈ (0,1)` is converted back to the original domain via the inverse empirical CDF (rank-ECDF table estimated from `fit_data`).

---

#### 4.1.4 R signature

```r
copula_mechanism(
  variables,                              # c(child, parent1, parent2, ...)
  family           = "gaussian",          # see table 4.1.2
  marginals        = "auto",             # "auto" = empirical ECDF (rank-based)
  nominal_handling = "regression",       # "regression" | "arbitrary_order"
  fit_data         = NULL                # data.frame with all variables columns (required in v1)
)

list_copula_families()                   # returns families available in current installation
```

---

#### 4.1.5 Variable types and `nominal_handling`

- **Continuous / Ordinal** — encoded as `double` before building pseudo-observations.
- **Nominal categorical** — copulas assume ordering in the margins; `nominal_handling` controls behaviour:
  - `"regression"` (default): explicit error if a nominal appears in `variables`.
  - `"arbitrary_order"`: includes the nominal with the level order as declared, emitting a `warning`.

---

#### 4.1.6 Optional dependency

`rvinecopulib` is in `Suggests` (not required). Systems that do not use `copula_mechanism()` need not install it. The `family = "gaussian"` path runs entirely in base R.

---

## 5. Simulation engine (v1: static DAG)

1. **Topological ordering.** When finalising a `System`, a topological order of features is computed (Kahn or DFS). An explicit error is raised if a cycle is detected.
2. **Generating a single unit.** The topological order is traversed; for each feature, if it is a root, a value is sampled from the marginal mechanism; if it has parents, the already-generated parent values (in the same unit) are collected and the conditional mechanism is applied.
3. **Generating a population.** The unit-generation process is repeated N times, with RNG controlled by a seed (each unit may use an RNG stream derived from the global seed + unit index, for reproducibility and to enable unit-by-unit baseline/intervention comparison).
4. **Applying an intervention.** Given a list of interventions, a derived `System` is built (a copy with the affected mechanisms/edges replaced according to each intervention's `kind`). The transitive downstream closure of target features is computed (`affected_features`). Two regeneration strategies, both supported:
   - **Full resampling**: a new population is generated from scratch from the derived `System`, using the same base seed as the baseline (units paired one-to-one).
   - **Partial resampling (more efficient)**: starting from the already-generated baseline population; values of unaffected features are kept; only `affected_features` are recomputed, in topological order, using the fixed values of unaffected parents and the new values of affected parents.
5. **Result.** A `SimulationResult` is assembled with baseline, intervened, list of interventions, `affected_features`, and `propagation_order`.

### 5.1 Reproducibility

Every simulation call accepts an explicit seed. Given the same `System`, same seed, and same N, the generated population is identical across runs and (to the extent possible, respecting RNG differences between languages) equivalent across R and Python implementations — this should be validated through parity tests (section 9).

---

## 6. Future extension: temporal dynamics and cycles (v2, out of immediate scope)

v1 solves static systems. For systems with feedback loops (e.g. A affects B which affects A) or time-evolving processes, v2 introduces:

- **`TimeStep`**: a system may be declared dynamic, where each feature has a "current" version and may depend on "past" (lagged) versions of itself or other features — this allows expressing cycles as cross-time dependencies (A(t) depends on B(t-1), B(t) depends on A(t-1)), preserving the acyclicity guarantee within any single timestep.
- **Iterative simulation engine**: instead of a single topological pass, T sequential steps are simulated, each being a topological pass over the "unrolled" graph for that timestep.
- **Time-dependent interventions**: an intervention may be applied from a specific timestep onward (e.g. "from t=5, fix feature X") and its propagation extends to subsequent timesteps.
- **Compatibility**: a v1 (static) `System` must be treatable as a degenerate case of a v2 `System` with T=1 and no lagged dependencies — the v1 API should not need to change when v2 is implemented.

This section is an architectural guideline, not a detailed specification — it will be detailed in a separate document once v1 is stable.

---

## 7. Software architecture

Layers, from lowest to highest:

1. **Type system** — `FeatureType`, domain validation, value encoding/decoding (e.g. categorical as string vs. internal code).
2. **Graph engine** — dependency graph representation, acyclicity checking, topological ordering, transitive closure computation (ancestors/descendants of a node) — used both for validation and for identifying `affected_features` in interventions.
3. **Mechanism library** — pre-built mechanisms per type combination (section 4), the copula mechanism via `rvinecopulib` (section 4.1), and custom mechanism registration.
4. **System builder** — API for declaring features, edges, and mechanisms, and for validating/"finalising" a `System` (running the invariants from section 3.5).
5. **Simulation engine** — unit/population generation given a finalised `System` and a seed (section 5).
6. **Intervention engine** — building a derived `System` from interventions, computing `affected_features`, executing full or partial resampling.
7. **I/O / serialisation** — exporting/importing a `System` (without simulated data) in a textual format (JSON or YAML) common to both languages, so that a system defined in Python can in principle be loaded in R (and vice versa). This serialised format is the parity contract between the two implementations.
8. **(Future) Domain extension layer** — not part of the core; the space where domain-specific solutions (epidemiology, markets, etc.) use `lepidoptera` as a dependency.

---

## 8. Public API (mirrored R / Python)

Convention: function names in `snake_case` in both languages. In Python, entities like `System`, `FeatureSpec`, `Mechanism`, `Intervention` are classes. In R, they are S3 objects (or R6, to be decided at implementation) with `new_*()` constructors and methods via generic functions — the table below lists the equivalent function/method on each side, not the internal class.

| Operation | Python | R |
|---|---|---|
| Create feature specification | `feature_spec(name, type, domain, metadata=None)` | `feature_spec(name, type, domain, metadata = NULL)` |
| Create empty system | `System()` | `new_system()` |
| Add feature | `system.add_feature(spec)` | `add_feature(system, spec)` |
| Add dependency + mechanism | `system.add_dependency(parents, child, mechanism)` | `add_dependency(system, parents, child, mechanism)` |
| Register custom mechanism | `register_mechanism(name, fn, parent_types, output_type)` | `register_mechanism(name, fn, parent_types, output_type)` |
| Look up pre-built mechanism | `mechanism_library.get(key)` | `mechanism_library_get(key)` |
| Copula mechanism (vine) | `copula_mechanism(variables, family="auto", marginals="auto", nominal_handling="regression", fit_data=None)` | `copula_mechanism(variables, family = "auto", marginals = "auto", nominal_handling = "regression", fit_data = NULL)` |
| Finalise/validate system | `system.finalize()` | `finalize_system(system)` |
| Simulate population | `simulate(system, n, seed=None)` | `simulate(system, n, seed = NULL)` |
| Create intervention (fix) | `do_fix(target, value)` | `do_fix(target, value)` |
| Create intervention (distribution) | `do_distribution(target, distribution)` | `do_distribution(target, distribution)` |
| Create intervention (shift) | `shift(target, fn)` | `shift(target, fn)` |
| Create intervention (mechanism override) | `mechanism_override(target, mechanism)` | `mechanism_override(target, mechanism)` |
| Apply intervention(s) and propagate | `propagate(system, interventions, n=None, seed=None, mode="full"/"partial")` | `propagate(system, interventions, n = NULL, seed = NULL, mode = "full")` |
| Compare results | `compare(result)` (method of `SimulationResult`) | `compare(result)` |
| Export system | `system.to_json(path)` / `system.to_yaml(path)` | `export_system(system, path, format = "json")` |
| Import system | `System.from_json(path)` | `import_system(path, format = "json")` |
| Visualise graph | `system.plot_graph()` | `plot_graph(system)` |

Parity notes:
- Every function accepting `seed` must, given the same serialised `System` and same `seed`, produce statistically equivalent populations (not necessarily bit-identical, given that R and Python RNGs differ internally — but the distribution specifications and parameters must be identical). Exact bit-identity across languages is not a goal; distributional equivalence is.
- Validation error messages (system with cycle, mechanism with incompatible type, etc.) must express the same structured information in both languages (same error "code"), even if the text differs.

---

## 9. Testing strategy and parity validation

- **Unit tests per layer**, replicated in R and Python: type system, graph engine (acyclicity, topological ordering, transitive closure), pre-built mechanisms (each type combination from section 4), `System` invariants.
- **Cross-language parity tests**: a set of reference systems, serialised in JSON, is loaded in both R and Python; simulation with the same seed (or a large number of units, comparing aggregated moments/distributions) must produce statistically equivalent results within a defined tolerance.
- **Intervention tests**: for each reference system, apply known interventions and verify that `affected_features` corresponds exactly to the expected transitive closure, and that features outside that closure are identical between baseline and intervened (in "partial" mode).

---

## 10. Roadmap

- **v0.1 (this document)** — specification frozen for initial implementation.
- **v1.0** — static DAG, full mixed types (section 4), one-shot propagation engine, mirrored R/Python API, JSON serialisation, parity tests.
- **v1.x** — expanded mechanism library, graph visualisation, performance improvements (population generation vectorisation).
- **v2.0** — temporal dynamics and cycles via lagged dependencies (section 6), maintaining backward compatibility with v1 systems.
- **v2.x+** — starting point for domain-specific solutions built on `lepidoptera` (extension layer, section 7.8).
- **v1.x+ (cross-cutting)** — AI integration layer (section 12), incremental and optional, does not block v1.0/v2.0.

---

## 11. AI integration (LLMs/transformers) — optional cross-cutting extension

`lepidoptera` is designed to be "AI-native" without requiring changes to the core architecture: the rule that **any function respecting the `Mechanism` signature is valid** (sections 3.3/4) is already the entry point — a mechanism whose `fn` calls an LLM, or a trained model (including transformer architectures), is just another `Mechanism`. The fronts below are optional extensions, orthogonal to the propagation engine (sections 5–6) and independent of each other — they can be adopted one at a time, in any order, without touching the core.

### 11.1 `llm_mechanism` — LLM-based generative mechanism

A mechanism whose generative function is an LLM call, useful especially for semantic/textual features that do not fit neatly into regression (section 4) or copula (section 4.1) — e.g. given a customer's age, income, and history (parents), generate a sentiment category or a descriptive text snippet (child).

Conceptual signature (mirrored R/Python, same pattern as section 8):

```
llm_mechanism(
  prompt_template,   # template with placeholders for parent values
  model,             # model/provider identifier
  parents,           # parent names, in the order they fill the template
  output_type,       # FeatureType of the returned value
  parser = "auto"    # how LLM text output is converted to output_type
                     # (e.g. mapping to categorical/ordinal level, numeric parsing for continuous)
)
```

`output_type`/`parent_types` are inferred as in any other `Mechanism` (section 3.3) — to the `System`, a node with `llm_mechanism` is indistinguishable from a node with a regression or copula mechanism.

**Cost and determinism.** LLM calls have cost and latency per simulated unit, and are non-deterministic even with a fixed seed (unless the backend offers temperature/seed control) — `finalize_system()` emits a warning when an `llm_mechanism` is on a path that will be executed N times per unit, suggesting caching per parent-value combination (memoisation) when the parent domain is finite (categorical/ordinal) or discretisable.

### 11.2 `learned_mechanism` — data-fitted mechanism (any model, including tabular transformers)

Generalisation of the pattern already used in `copula_mechanism` (`fit_data`, section 4.1): instead of a copula model, any predictive model fittable to observed data — including transformer models for tabular data — becomes a node's mechanism.

```
learned_mechanism(
  parents, child,
  model = "auto",      # "auto" | "gbm" | "transformer" | already-fitted model object
  fit_data,            # observed data of parents + child
  uncertainty = "auto" # how model uncertainty is propagated in sampling (e.g. residuals, predictive distribution)
)
```

Typical use case: "I have an observed sample of these variables, and I want the mechanism to learn the relationship automatically rather than me specifying the functional form" — same spirit as `fit_data` in section 4.1, but without requiring copula structure.

### 11.3 `model_mechanism` — use a pre-trained external model as a mechanism

Differs from `learned_mechanism` in one fundamental way: `learned_mechanism` **trains** a model internally from `fit_data`; `model_mechanism` **uses** a model the user has already trained outside `lepidoptera` (a `ranger` random forest, a `glm`, an `xgboost`, a `keras` model, etc.).

```r
model_mechanism(
  predict_fn,          # function(parent_values) -> single value
  parents,             # character vector: parent feature names
  parent_types,        # character vector: feature_types() entry per parent
  output_type,         # one of feature_types()
  levels   = NULL,     # required if output_type is "categorical" or "ordinal"
  name     = "model_mechanism"
)
```

The user is responsible for the complete `predict_fn`: receiving `parent_values` (named list), calling the model, extracting the correct output slot, and optionally adding stochastic noise (e.g. Gaussian residuals for an `lm`). To the `System`, a node with `model_mechanism` is indistinguishable from any other `Mechanism`.

**Typical use cases.** (a) using a random forest trained on observational data as a generative mechanism for a feature; (b) using a logistic regression model to generate categorical outcomes; (c) integrating deep learning models (via any R wrapper) into the simulation system without needing a specific API — the `predict_fn` is the integration boundary.

### 11.4 System generation from natural language

An LLM translates a free-text domain description ("a system with smoking, income, and heart disease, where income affects smoking and both affect heart disease") directly into the serialisation format from section 7, layer 7 (JSON/YAML) — the same contract already used for R/Python parity (`export_system`/`import_system`). This means **this front requires no new API**: the LLM only needs to learn to generate an artefact that the core already knows how to import and validate via `finalize_system()`/`System.finalize()`. Validation errors (section 3.5) serve as feedback signals for the LLM to correct the generated specification.

### 11.5 Intervention query in natural language

An LLM translates a free-text question ("what happens to heart disease if I increase income by 10%?") into a `propagate()` call with the corresponding `Intervention` objects (`do_fix`/`do_distribution`/`shift`/`mechanism_override`, section 3.6), executes the simulation, and narrates the `SimulationResult`/`compare()` back in text. Combines naturally with 11.4: describe the system and query interventions in the same conversation.

### 11.6 Tool layer for agents (MCP/tool-calling)

Expose the public API from section 8 (`add_feature`, `add_dependency`, `simulate`, `propagate`, etc.) as tools callable by an LLM agent (e.g. via the MCP protocol) — the agent manipulates a `System` step by step, decides when to simulate and when to intervene, and reports results. This front depends only on the already-specified public API; it requires no core changes beyond a thin wrapper over each function/method.

### 11.7 Semantic metadata

The `metadata` field of `FeatureSpec` (section 3.2), already present and never interpreted by the core, is the natural space to store semantic descriptions, embeddings, or LLM-generated annotations — enabling search/similarity between features and mechanisms of different systems (e.g. "find a system similar to this one already specified"), without requiring any new fields in the data structure.

### 11.8 Recommended implementation order

There is no strong technical dependency between 11.1–11.7, but the highest-return order is: (1) `llm_mechanism`/`learned_mechanism` — fits the current architecture without changing the spec; (2) system generation from natural language — opens the entry door for non-technical users; (3) intervention query in natural language — closes the loop of "conversing with the simulation"; (4) agent/MCP layer — depends on the core (sections 3–5) being at least minimally implemented, since it exposes the real API, not a placeholder.

---

## 12. Glossary

- **DAG**: directed acyclic graph.
- **Marginal mechanism**: generates a value without depending on other features (root feature).
- **Conditional mechanism**: generates a value from parent values.
- **Transitive downstream closure**: all features reachable from a node following edges in the dependency direction (descendants).
- **Partial resampling**: recomputing only the features affected by an intervention, keeping the rest of the population intact.
- **R/Python parity**: the guarantee that both implementations represent the same conceptual model and produce equivalent results from the same system specification.
- **LLM/learned/external mechanism**: a mechanism whose generative function is an LLM call, an internally data-fitted model, or a pre-trained external model (sections 11.1–11.3), treated by the core as any other `Mechanism`.
