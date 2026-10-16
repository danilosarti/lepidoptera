# Simulation engine layer ----------------------------------------------------
#
# Generating units and populations from a finalized System. See SPEC.md
# section 5.

#' One reproducible seed per unit, derived from a single base seed
#'
#' Mirrors the role of Python's `numpy.random.SeedSequence(seed).spawn(n)`:
#' each unit gets an independent draw stream (here, an independent
#' `set.seed()` call) so that regenerating a subset of units, or only a
#' subset of features for a given unit (see `propagate(mode = "partial")`
#' in intervention.R), does not change the random draws used elsewhere.
#'
#' @keywords internal
.unit_seeds <- function(n, seed) {
  if (is.null(seed)) return(rep(list(NULL), n))
  old_seed <- if (exists(".Random.seed", envir = .GlobalEnv)) .Random.seed else NULL
  on.exit({
    if (!is.null(old_seed)) assign(".Random.seed", old_seed, envir = .GlobalEnv)
  })
  set.seed(seed)
  # replace = TRUE avoids the without-replacement algorithm that fails on
  # some platforms when n is close to .Machine$integer.max; collision
  # probability for typical simulation sizes (n << 1e9) is negligible.
  as.list(sample.int(1e9L, size = n, replace = TRUE))
}

#' @keywords internal
.generate_unit <- function(system, unit_seed) {
  if (!is.null(unit_seed)) set.seed(unit_seed)
  row <- list()
  for (name in system$topo_order) {
    mechanism <- system$mechanisms[[name]]
    parent_values <- row[system$parents[[name]]]
    row[[name]] <- mechanism$fn(parent_values)
  }
  row
}

#' @keywords internal
.to_typed_frame <- function(system, rows) {
  cols <- system$topo_order
  df <- data.frame(row.names = seq_along(rows))
  for (name in cols) {
    spec <- system$features[[name]]
    if (spec$type %in% c("categorical", "ordinal")) {
      # as.character() handles both plain strings (from mechanism fns) and
      # factor elements (from as.list(baseline_row) in propagate partial mode)
      values <- vapply(rows, function(r) as.character(r[[name]]), character(1))
      df[[name]] <- factor(values, levels = spec$domain$levels,
                           ordered = spec$type == "ordinal")
    } else {
      values <- vapply(rows, function(r) as.numeric(r[[name]]), numeric(1))
      df[[name]] <- values
    }
  }
  df
}

#' Simulate a population from a system
#'
#' @param system A finalized `system` object (see [finalize_system()]).
#' @param n Integer. Number of units to generate.
#' @param seed Optional integer seed for reproducibility.
#' @return A data.frame with one row per unit and one column per feature,
#'   typed according to each feature's `FeatureType` (`factor` for
#'   categorical/ordinal columns, `numeric` for continuous ones).
#' @export
simulate <- function(system, n, seed = NULL) {
  if (!isTRUE(system$finalized)) {
    stop("System must be finalized (finalize_system()) before simulate().")
  }
  if (n < 1) stop("`n` must be a positive integer.")

  seeds <- .unit_seeds(n, seed)
  rows <- lapply(seeds, function(s) .generate_unit(system, s))
  .to_typed_frame(system, rows)
}
