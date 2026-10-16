# Type system layer ------------------------------------------------------
#
# FeatureType enumeration, domain validation, and value encoding/decoding.
# See SPEC.md section 3.1-3.2.

#' Valid feature types
#'
#' @return A character vector of the allowed `FeatureType` values:
#'   `"continuous"`, `"categorical"`, `"ordinal"`.
#' @export
feature_types <- function() {
  c("continuous", "categorical", "ordinal")
}

#' Declare a feature
#'
#' Creates a `feature_spec`: name, type, domain, and optional metadata.
#' See SPEC.md section 3.2.
#'
#' @param name Character. Unique identifier within the system.
#' @param type Character. One of [feature_types()].
#' @param domain List. For `"continuous"`: `list(min = ..., max = ...)`
#'   (either may be `-Inf`/`Inf`). For `"categorical"`/`"ordinal"`:
#'   `list(levels = c(...))`, where the order of `levels` matters for
#'   `"ordinal"` (it defines the scale order).
#' @param metadata Optional named list, never interpreted by the core.
#'
#' @return A `feature_spec` object (S3 list with class `"feature_spec"`).
#' @export
feature_spec <- function(name, type, domain, metadata = NULL) {
  if (!is.character(name) || length(name) != 1 || !nzchar(name)) {
    stop("`name` must be a single non-empty string.")
  }
  if (!(type %in% feature_types())) {
    stop(sprintf(
      "Unknown feature type '%s'. Must be one of: %s.",
      type, paste(feature_types(), collapse = ", ")
    ))
  }

  if (type == "continuous") {
    if (!is.list(domain) || is.null(domain$min) || is.null(domain$max)) {
      stop("`domain` for a continuous feature must be list(min = ..., max = ...).")
    }
    if (domain$min > domain$max) {
      stop("`domain$min` cannot be greater than `domain$max`.")
    }
  } else {
    if (!is.list(domain) || is.null(domain$levels)) {
      stop(sprintf(
        "`domain` for a %s feature must be list(levels = c(...)).", type
      ))
    }
    levels <- domain$levels
    if (length(levels) < 2) {
      stop("`domain$levels` must have at least 2 entries.")
    }
    if (length(unique(levels)) != length(levels)) {
      stop("`domain$levels` must not contain duplicates.")
    }
  }

  structure(
    list(name = name, type = type, domain = domain, metadata = metadata),
    class = "feature_spec"
  )
}

#' Levels of a categorical/ordinal feature
#'
#' @param spec A `feature_spec`.
#' @return Character vector of levels, or `NULL` for a continuous feature.
#' @keywords internal
feature_levels <- function(spec) {
  if (spec$type %in% c("categorical", "ordinal")) {
    spec$domain$levels
  } else {
    NULL
  }
}

#' @export
print.feature_spec <- function(x, ...) {
  cat(sprintf("<feature_spec> %s (%s)\n", x$name, x$type))
  invisible(x)
}
