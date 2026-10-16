# Intervention engine layer ---------------------------------------------
#
# Constructing interventions and propagating their effects through the
# dependency structure. See SPEC.md sections 3.6 and 5, step 4.
#
# An `intervention` is an S3 list `list(target, kind, params)`, built via
# do_fix()/do_distribution()/shift()/mechanism_override() below.

.new_intervention <- function(target, kind, params) {
  structure(list(target = target, kind = kind, params = params), class = "intervention")
}

#' Intervention: fix a feature to a constant value
#'
#' Classic do-operator: disconnects `target` from its parents and sets it
#' to `value` for every unit.
#'
#' @param target Character. Feature name (or vector of names).
#' @param value The fixed value (or vector of values, one per target).
#' @return An `intervention` object.
#' @export
do_fix <- function(target, value) {
  .new_intervention(target, "do_fix", list(value = value))
}

#' Intervention: replace a feature's generative distribution
#'
#' v1 scope: `distribution` must be a *marginal* mechanism (no parents) --
#' the feature is resampled from `distribution` independently of its
#' original parents. Use [mechanism_override()] for a conditional
#' replacement.
#'
#' @param target Character. Feature name.
#' @param distribution A marginal `mechanism`, e.g. from
#'   `mechanism_library_get("normal")(mean = ..., sd = ...)`.
#' @return An `intervention` object.
#' @export
do_distribution <- function(target, distribution) {
  .new_intervention(target, "do_distribution", list(distribution = distribution))
}

#' Intervention: shift the value a feature would otherwise take
#'
#' Preserves the dependency on parents; applies `fn` to the value that the
#' original mechanism would have produced.
#'
#' @param target Character. Feature name.
#' @param fn Function applied to the originally generated value.
#' @return An `intervention` object.
#' @export
shift <- function(target, fn) {
  .new_intervention(target, "shift", list(fn = fn))
}

#' Intervention: override a feature's mechanism entirely
#'
#' The replacement `mechanism` must declare the same number and types of
#' parents that `target` was originally given in `add_dependency()` (the
#' parent set itself is not changed by this intervention) -- mismatches
#' surface as a validation error when the derived system is finalized.
#'
#' @param target Character. Feature name.
#' @param mechanism A `mechanism` object replacing the current one.
#' @return An `intervention` object.
#' @export
mechanism_override <- function(target, mechanism) {
  .new_intervention(target, "mechanism_override", list(mechanism = mechanism))
}

.target_list <- function(iv) {
  if (length(iv$target) == 1) iv$target else as.character(iv$target)
}

.make_constant_mechanism <- function(output_type, value) {
  fn <- function(parent_values) value
  .new_mechanism("do_fix", fn, character(0), output_type)
}

.make_shifted_mechanism <- function(original, shift_fn) {
  fn <- function(parent_values) shift_fn(original$fn(parent_values))
  .new_mechanism("shift", fn, original$parent_types, original$output_type)
}

.apply_intervention <- function(derived, iv) {
  targets <- .target_list(iv)

  if (iv$kind == "do_fix") {
    values <- iv$params$value
    if (length(values) == 1 && length(targets) > 1) values <- rep(values, length(targets))
    if (length(values) != length(targets)) {
      stop("do_fix(): `value` must have one entry per target.")
    }
    for (i in seq_along(targets)) {
      target <- targets[i]
      output_type <- derived$features[[target]]$type
      derived$mechanisms[[target]] <- .make_constant_mechanism(output_type, values[[i]])
      derived$parents[[target]] <- character(0)
    }
  } else if (iv$kind == "do_distribution") {
    distribution <- iv$params$distribution
    if (length(distribution$parent_types) > 0) {
      stop(paste(
        "do_distribution() v1 only supports marginal (parentless)",
        "replacement distributions. Use mechanism_override() for a",
        "conditional replacement."
      ))
    }
    for (target in targets) {
      if (!identical(distribution$output_type, derived$features[[target]]$type)) {
        stop(sprintf(
          "do_distribution(): replacement outputs '%s', but '%s' is declared as '%s'.",
          distribution$output_type, target, derived$features[[target]]$type
        ))
      }
      derived$mechanisms[[target]] <- distribution
      derived$parents[[target]] <- character(0)
    }
  } else if (iv$kind == "shift") {
    shift_fn <- iv$params$fn
    for (target in targets) {
      derived$mechanisms[[target]] <- .make_shifted_mechanism(derived$mechanisms[[target]], shift_fn)
      # parents unchanged
    }
  } else if (iv$kind == "mechanism_override") {
    mechanism <- iv$params$mechanism
    for (target in targets) {
      derived$mechanisms[[target]] <- mechanism
      # parents unchanged; mismatches caught by finalize_system()
    }
  } else {
    stop(sprintf("Unknown intervention kind: %s", iv$kind))
  }
  derived
}

.derive_system <- function(system, interventions) {
  derived <- system_copy(system)
  for (iv in interventions) derived <- .apply_intervention(derived, iv)
  finalize_system(derived)
}

#' @keywords internal
.new_simulation_result <- function(baseline, intervened, interventions,
                                    affected_features, propagation_order) {
  structure(
    list(
      baseline = baseline, intervened = intervened, interventions = interventions,
      affected_features = affected_features, propagation_order = propagation_order
    ),
    class = "simulation_result"
  )
}

#' Apply interventions and propagate their effects
#'
#' @param system A finalized `system` object.
#' @param interventions A list of `intervention` objects (see [do_fix()],
#'   [do_distribution()], [shift()], [mechanism_override()]).
#' @param n Integer. Number of units to simulate for the baseline
#'   (required).
#' @param seed Optional integer seed, shared between baseline and
#'   intervened population for paired comparison.
#' @param mode Character. `"full"` resamples the whole population from
#'   the derived system. `"partial"` keeps unaffected features exactly
#'   equal to the baseline and recomputes only the downstream closure of
#'   the targeted features. The two modes are each internally
#'   reproducible given the same seed, but are not bit-identical to each
#'   other (they consume the per-unit random stream differently).
#' @return A `simulation_result`: a list with `baseline`, `intervened`,
#'   `interventions`, `affected_features`, `propagation_order`.
#' @export
propagate <- function(system, interventions, n = NULL, seed = NULL,
                       mode = c("full", "partial")) {
  mode <- match.arg(mode)
  if (!isTRUE(system$finalized)) stop("System must be finalized before propagate().")
  if (is.null(n)) stop("`n` is required.")
  if (length(interventions) == 0) stop("`interventions` must be non-empty.")

  baseline <- simulate(system, n, seed)
  derived <- .derive_system(system, interventions)

  targets <- character(0)
  for (iv in interventions) targets <- union(targets, .target_list(iv))

  affected_features <- downstream_closure(system_edges(system), targets)
  propagation_order <- system$topo_order[system$topo_order %in% affected_features]

  if (mode == "full") {
    intervened <- simulate(derived, n, seed)
  } else {
    intervened <- .propagate_partial(derived, baseline, n, seed, propagation_order)
  }

  .new_simulation_result(baseline, intervened, interventions, affected_features, propagation_order)
}

#' @keywords internal
.propagate_partial <- function(derived, baseline, n, seed, propagation_order) {
  seeds <- .unit_seeds(n, seed)
  rows <- lapply(seq_len(nrow(baseline)), function(i) as.list(baseline[i, , drop = FALSE]))
  new_rows <- vector("list", length(rows))
  for (i in seq_along(rows)) {
    row <- rows[[i]]
    unit_seed <- seeds[[i]]
    if (!is.null(unit_seed)) set.seed(unit_seed)
    for (name in propagation_order) {
      mechanism <- derived$mechanisms[[name]]
      parent_values <- row[derived$parents[[name]]]
      row[[name]] <- mechanism$fn(parent_values)
    }
    new_rows[[i]] <- row
  }
  .to_typed_frame(derived, new_rows)
}

#' Compare baseline and intervened populations
#'
#' For each feature in `affected_features`: mean/sd shift for continuous
#' features, level-frequency shift for categorical/ordinal features.
#'
#' @param result A `simulation_result`, as returned by [propagate()].
#' @return A named list, one entry per affected feature.
#' @export
compare <- function(result) {
  summary <- list()
  for (name in result$affected_features) {
    base_col <- result$baseline[[name]]
    interv_col <- result$intervened[[name]]
    if (is.factor(base_col)) {
      summary[[name]] <- list(
        type = "categorical",
        baseline_freq = as.list(prop.table(table(base_col))),
        intervened_freq = as.list(prop.table(table(interv_col)))
      )
    } else {
      summary[[name]] <- list(
        type = "continuous",
        baseline_mean = mean(base_col),
        intervened_mean = mean(interv_col),
        baseline_sd = sd(base_col),
        intervened_sd = sd(interv_col),
        mean_diff = mean(interv_col) - mean(base_col)
      )
    }
  }
  summary
}
