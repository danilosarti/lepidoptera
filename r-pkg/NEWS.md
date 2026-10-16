# lepidoptera 0.1.2

## Bug fixes

* Fixed D-vine conditional sampling for mechanisms with exactly 2 parents
  (trivariate vine): replaced the `rosenblatt()` / `inverse_rosenblatt()`
  pipeline—whose behaviour changed for single-row matrices in newer
  **rvinecopulib** versions—with an explicit sequential h-function algorithm
  using `pair_copulas()`.  Spearman correlations in the simulated output now
  correctly reflect the fitted dependence structure.

# lepidoptera 0.1.1

## Bug fixes

* Fixed `copula_mechanism()` with non-Gaussian families: `hbicop()` now returns
  a numeric vector in newer **rvinecopulib** versions; the bivariate path
  handles both vector and matrix return types.
* Fixed D-vine conditional sampling for mechanisms with 2+ parents: unnamed
  matrices are now passed to `rosenblatt()` / `inverse_rosenblatt()` to prevent
  column reordering by name in newer **rvinecopulib** versions.
* Removed reference to non-exported `rvinecopulib::bicop_family_list` in
  `list_copula_families()`.

# lepidoptera 0.1.0

## Initial release

* Core system API: `new_system()`, `add_feature()`, `add_dependency()`,
  `finalize_system()`.
* Pre-built mechanism library covering all nine parent-type × child-type
  combinations: `linear_gaussian`, `multinomial_logit`, `ordered_logit`,
  `group_effect`, `categorical_transition`, accessible via
  `mechanism_library_get()`.
* `simulate()` for population-level data generation under topological ordering
  with per-unit reproducible seeds.
* Intervention types: `do_fix()`, `do_distribution()`, `shift()`,
  `mechanism_override()`.
* `propagate()` with `mode = "full"` (ATE / independent interventional draws)
  and `mode = "partial"` (ITE / frozen exogenous noise counterfactuals).
* Vine copula mechanism via `copula_mechanism()`, backed by
  `rvinecopulib` (optional dependency).
* Predictive model integration via `model_mechanism()` and `learned_mechanism()`.
* Language model mechanism via `llm_mechanism()`.
* JSON / YAML serialisation via `export_system()` / `import_system()`.
* DAG visualisation via `plot_graph()` (requires `igraph`).
