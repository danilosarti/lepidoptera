# System builder layer ------------------------------------------------------
#
# Declaring features, edges, and mechanisms, and finalizing/validating a
# System against the invariants in SPEC.md section 3.5.
#
# A `system` is an S3 list with elements `features` (named list of
# `feature_spec`), `parents` (named list of character vectors, keyed by
# child name), `mechanisms` (named list of `mechanism`, keyed by child
# name), `finalized` (logical), and `topo_order` (character vector, set by
# `finalize_system()`). Systems are treated as immutable from the caller's
# point of view: every builder function returns a (possibly new) `system`
# rather than mutating in place, consistent with normal R copy-on-modify
# semantics.

#' Create an empty system
#'
#' @return A `system` object with no features, edges, or mechanisms yet.
#' @export
new_system <- function() {
  structure(
    list(
      features = list(),
      parents = list(),
      mechanisms = list(),
      finalized = FALSE,
      topo_order = character(0)
    ),
    class = "system"
  )
}

#' Add a feature to a system
#'
#' @param system A `system` object, as created by [new_system()].
#' @param spec A `feature_spec`, as created by [feature_spec()].
#' @return The updated `system`.
#' @export
add_feature <- function(system, spec) {
  if (system$finalized) {
    stop("Cannot add features to an already-finalized system.")
  }
  if (spec$name %in% names(system$features)) {
    stop(sprintf("Feature '%s' was already added.", spec$name))
  }
  system$features[[spec$name]] <- spec
  system
}

#' Add a dependency (edge set + mechanism) to a system
#'
#' @param system A `system` object.
#' @param parents Character vector of parent feature names (use
#'   `character(0)` for a marginal/root mechanism), in the same order
#'   used when `mechanism` was built.
#' @param child Character. Name of the dependent feature. Must already
#'   exist (see [add_feature()]).
#' @param mechanism A `mechanism` object, e.g. from
#'   [mechanism_library_get()] or [register_mechanism()].
#' @return The updated `system`.
#' @export
add_dependency <- function(system, parents, child, mechanism) {
  if (system$finalized) {
    stop("Cannot add dependencies to an already-finalized system.")
  }
  if (child %in% names(system$mechanisms)) {
    stop(sprintf(
      "Feature '%s' already has a mechanism; remove it first if you need to redefine it.",
      child
    ))
  }
  system$parents[[child]] <- parents
  system$mechanisms[[child]] <- mechanism
  system
}

#' All `(parent, child)` edges declared via `add_dependency()`
#'
#' @param system A `system` object.
#' @return A data.frame with character columns `parent`, `child`.
#' @keywords internal
system_edges <- function(system) {
  parents_list <- character(0)
  children_list <- character(0)
  for (child in names(system$parents)) {
    ps <- system$parents[[child]]
    if (length(ps) > 0) {
      parents_list <- c(parents_list, ps)
      children_list <- c(children_list, rep(child, length(ps)))
    }
  }
  data.frame(parent = parents_list, child = children_list, stringsAsFactors = FALSE)
}

#' Finalize and validate a system
#'
#' Runs the invariants in SPEC.md section 3.5:
#' 1. every feature has exactly one mechanism;
#' 2. the dependency graph is acyclic;
#' 3. every edge references existing features;
#' 4. each mechanism's declared parent types match the actual types of
#'    the parents it was attached to;
#' 5. the mechanism's output type matches the feature's declared type.
#'
#' @param system A `system` object.
#' @return The same `system`, marked finalized, ready for [simulate()].
#' @export
finalize_system <- function(system) {
  if (system$finalized) return(system)

  feature_names <- names(system$features)

  # Invariant 3: edges reference existing features.
  for (child in names(system$parents)) {
    if (!(child %in% feature_names)) {
      stop(sprintf(
        "add_dependency() declared child '%s', which was never added via add_feature().",
        child
      ))
    }
    for (parent in system$parents[[child]]) {
      if (!(parent %in% feature_names)) {
        stop(sprintf(
          "add_dependency() declared parent '%s' for child '%s', but '%s' was never added via add_feature().",
          parent, child, parent
        ))
      }
    }
  }

  # Invariant 1: every feature has exactly one mechanism.
  missing <- sort(setdiff(feature_names, names(system$mechanisms)))
  if (length(missing) > 0) {
    stop(sprintf(
      "These features have no mechanism (call add_dependency(), with parents = character(0) for a root feature): %s.",
      paste(missing, collapse = ", ")
    ))
  }

  # Invariant 4/5: type checks.
  for (child in names(system$mechanisms)) {
    mechanism <- system$mechanisms[[child]]
    declared_parents <- system$parents[[child]]
    if (length(mechanism$parent_types) != length(declared_parents)) {
      stop(sprintf(
        "Mechanism for '%s' declares %d parent type(s), but %d parent(s) were declared in add_dependency().",
        child, length(mechanism$parent_types), length(declared_parents)
      ))
    }
    for (i in seq_along(declared_parents)) {
      parent <- declared_parents[i]
      expected_type <- mechanism$parent_types[i]
      actual_type <- system$features[[parent]]$type
      if (!identical(expected_type, actual_type)) {
        stop(sprintf(
          "Mechanism for '%s' expects parent '%s' to be '%s', but it is '%s'.",
          child, parent, expected_type, actual_type
        ))
      }
    }
    child_type <- system$features[[child]]$type
    if (!identical(mechanism$output_type, child_type)) {
      stop(sprintf(
        "Mechanism for '%s' produces '%s', but '%s' is declared as '%s'.",
        child, mechanism$output_type, child, child_type
      ))
    }
  }

  # Invariant 2 + topological order (errors on a cycle).
  system$topo_order <- topological_sort(feature_names, system_edges(system))
  system$finalized <- TRUE
  system
}

#' An independent copy of a system (used internally by intervention.R)
#' @keywords internal
system_copy <- function(system) {
  structure(
    list(
      features = system$features,
      parents = system$parents,
      mechanisms = system$mechanisms,
      finalized = FALSE,
      topo_order = character(0)
    ),
    class = "system"
  )
}

#' @export
print.system <- function(x, ...) {
  cat(sprintf(
    "<system> %d feature(s), %s\n",
    length(x$features),
    if (x$finalized) "finalized" else "not finalized"
  ))
  invisible(x)
}
