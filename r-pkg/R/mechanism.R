# Mechanism library layer --------------------------------------------------
#
# Marginal and conditional mechanisms, the pre-built library covering the
# type-combination matrix (SPEC.md section 4), and the custom mechanism
# registry.
#
# Calling convention for a mechanism's `fn`: `fn(parent_values)`, where
# `parent_values` is a named list (empty for a marginal mechanism). Unlike
# the Python implementation (which threads an explicit
# `numpy.random.Generator` through `fn`), the R port relies on R's global
# RNG stream and idiomatic `stats::rnorm()`/`sample()`/etc.; callers (see
# simulate.R) seed the global RNG once per unit via `set.seed()`, which
# plays the same reproducibility role as Python's per-unit
# `numpy.random.Generator`.

#' A mechanism object
#' @keywords internal
.new_mechanism <- function(name, fn, parent_types, output_type, spec = NULL) {
  structure(
    list(
      name = name, fn = fn, parent_types = parent_types,
      output_type = output_type, spec = spec
    ),
    class = "mechanism"
  )
}

#' @export
print.mechanism <- function(x, ...) {
  cat(sprintf(
    "<mechanism> %s (parents: %s -> %s)\n",
    x$name,
    if (length(x$parent_types)) paste(x$parent_types, collapse = ", ") else "(none)",
    x$output_type
  ))
  invisible(x)
}

.CUSTOM_MECHANISMS <- new.env(parent = emptyenv())

#' Register a custom mechanism
#'
#' @param name Character. Key under which the mechanism is registered.
#' @param fn Function with signature `function(parent_values)` returning a
#'   value compatible with `output_type`. Use R's RNG functions
#'   (`rnorm()`, `sample()`, ...) directly inside `fn`; the caller seeds
#'   the global RNG per unit (see simulate.R).
#' @param parent_types Character vector, one [feature_types()] entry per
#'   declared parent, in the order parents will be declared in
#'   `add_dependency()`.
#' @param output_type One of [feature_types()].
#'
#' @return The registered `mechanism` object.
#' @export
register_mechanism <- function(name, fn, parent_types, output_type) {
  mech <- .new_mechanism(name, fn, parent_types, output_type, spec = NULL)
  assign(name, mech, envir = .CUSTOM_MECHANISMS)
  mech
}

# --------------------------------------------------------------------------
# Pre-built mechanism factories
# --------------------------------------------------------------------------

.normal_factory <- function(mean = 0, sd = 1) {
  fn <- function(parent_values) rnorm(1, mean, sd)
  .new_mechanism(
    "normal", fn, character(0), "continuous",
    spec = list(factory = "normal", kwargs = list(mean = mean, sd = sd))
  )
}

.categorical_marginal_factory <- function(levels, probs, ordinal = FALSE) {
  if (length(levels) != length(probs)) {
    stop("`levels` and `probs` must have the same length.")
  }
  if (abs(sum(probs) - 1) > 1e-6) stop("`probs` must sum to 1.")
  fn <- function(parent_values) sample(levels, size = 1, prob = probs)
  key <- if (ordinal) "ordinal_marginal" else "categorical_marginal"
  .new_mechanism(
    key, fn, character(0), if (ordinal) "ordinal" else "categorical",
    spec = list(factory = key, kwargs = list(levels = levels, probs = probs))
  )
}

#' @keywords internal
categorical_marginal <- function(levels, probs) {
  .categorical_marginal_factory(levels, probs, ordinal = FALSE)
}

#' @keywords internal
ordinal_marginal <- function(levels, probs) {
  .categorical_marginal_factory(levels, probs, ordinal = TRUE)
}

#' Continuous parents -> continuous child: linear combination + Gaussian noise.
#' @keywords internal
linear_gaussian <- function(coefs, intercept = 0, sd = 1) {
  parent_names <- names(coefs)
  fn <- function(parent_values) {
    score <- intercept
    for (p in parent_names) score <- score + coefs[[p]] * as.numeric(parent_values[[p]])
    score + rnorm(1, 0, sd)
  }
  .new_mechanism(
    "linear_gaussian", fn, rep("continuous", length(parent_names)), "continuous",
    spec = list(
      factory = "linear_gaussian",
      kwargs = list(coefs = coefs, intercept = intercept, sd = sd)
    )
  )
}

.softmax <- function(scores) {
  v <- scores - max(scores)
  e <- exp(v)
  e / sum(e)
}

#' Continuous parents -> categorical child via multinomial logit.
#' @keywords internal
multinomial_logit <- function(levels, coefs, intercepts = NULL) {
  if (is.null(intercepts)) intercepts <- list()
  parent_names <- sort(unique(unlist(lapply(coefs, names))))
  fn <- function(parent_values) {
    scores <- vapply(levels, function(level) {
      intercept <- if (!is.null(intercepts[[level]])) intercepts[[level]] else 0
      level_coefs <- coefs[[level]]
      score <- intercept
      if (!is.null(level_coefs)) {
        for (p in parent_names) {
          coef <- level_coefs[[p]]
          if (!is.null(coef)) score <- score + coef * as.numeric(parent_values[[p]])
        }
      }
      score
    }, numeric(1))
    probs <- .softmax(scores)
    sample(levels, size = 1, prob = probs)
  }
  .new_mechanism(
    "multinomial_logit", fn, rep("continuous", length(parent_names)), "categorical",
    spec = list(
      factory = "multinomial_logit",
      kwargs = list(levels = levels, coefs = coefs, intercepts = intercepts)
    )
  )
}

#' Continuous parents -> ordinal child via proportional-odds (ordered logit).
#' @keywords internal
ordered_logit <- function(levels, coefs, cutpoints) {
  if (length(cutpoints) != length(levels) - 1) {
    stop("`cutpoints` must have length length(levels) - 1.")
  }
  parent_names <- names(coefs)
  fn <- function(parent_values) {
    score <- 0
    for (p in parent_names) score <- score + coefs[[p]] * as.numeric(parent_values[[p]])
    latent <- score + rlogis(1, 0, 1)
    idx <- sum(latent > cutpoints) + 1L
    levels[idx]
  }
  .new_mechanism(
    "ordered_logit", fn, rep("continuous", length(parent_names)), "ordinal",
    spec = list(
      factory = "ordered_logit",
      kwargs = list(levels = levels, coefs = coefs, cutpoints = cutpoints)
    )
  )
}

#' Single categorical/ordinal parent -> categorical/ordinal child via a
#' transition table: `transition[[parent_level]] = list(child_level = prob)`.
#' @keywords internal
categorical_transition <- function(transition, output_type = "categorical") {
  if (length(transition) == 0) stop("`transition` must not be empty.")
  fn <- function(parent_values) {
    parent_value <- as.character(parent_values[[1]])
    row <- transition[[parent_value]]
    sample(names(row), size = 1, prob = unlist(row))
  }
  .new_mechanism(
    "categorical_transition", fn, "categorical", output_type,
    spec = list(
      factory = "categorical_transition",
      kwargs = list(transition = transition, output_type = output_type)
    )
  )
}

#' Single categorical/ordinal parent -> continuous child: per-level
#' Normal(mean, sd). `group_params[[level]] = list(mean = ..., sd = ...)`.
#' @keywords internal
group_effect <- function(group_params) {
  if (length(group_params) == 0) stop("`group_params` must not be empty.")
  fn <- function(parent_values) {
    parent_value <- as.character(parent_values[[1]])
    params <- group_params[[parent_value]]
    rnorm(1, params$mean, params$sd)
  }
  .new_mechanism(
    "group_effect", fn, "categorical", "continuous",
    spec = list(factory = "group_effect", kwargs = list(group_params = group_params))
  )
}

.MECHANISM_LIBRARY <- list(
  normal = .normal_factory,
  categorical_marginal = categorical_marginal,
  ordinal_marginal = ordinal_marginal,
  linear_gaussian = linear_gaussian,
  multinomial_logit = multinomial_logit,
  ordered_logit = ordered_logit,
  categorical_transition = categorical_transition,
  group_effect = group_effect
)

#' Look up a pre-built mechanism factory from the library
#'
#' Pre-built mechanisms cover the type-combination matrix in SPEC.md
#' section 4. `mechanism_library_get(key)` returns a *factory* (a
#' function), not a ready mechanism -- pre-built mechanisms always need
#' parameters. Call the factory with those parameters to obtain the
#' actual mechanism object, e.g.
#' `mechanism_library_get("linear_gaussian")(coefs = list(age = 0.1), sd = 1)`.
#'
#' @param key Character. One of `"normal"`, `"categorical_marginal"`,
#'   `"ordinal_marginal"`, `"linear_gaussian"`, `"multinomial_logit"`,
#'   `"ordered_logit"`, `"categorical_transition"`, `"group_effect"`.
#' @return A factory function.
#' @export
mechanism_library_get <- function(key) {
  if (!key %in% names(.MECHANISM_LIBRARY)) {
    stop(sprintf(
      "Unknown pre-built mechanism '%s'. Available: %s. For anything else, use register_mechanism().",
      key, paste(sort(names(.MECHANISM_LIBRARY)), collapse = ", ")
    ))
  }
  .MECHANISM_LIBRARY[[key]]
}

#' Rebuild a mechanism from its serialized `spec` (io.R helper)
#' @keywords internal
mechanism_from_spec <- function(spec) {
  factory <- mechanism_library_get(spec$factory)
  do.call(factory, spec$kwargs)
}
