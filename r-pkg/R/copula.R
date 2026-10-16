# Copula mechanism layer -----------------------------------------------------
#
# copula_mechanism() produces a standard `mechanism` object that plugs into
# any System without special treatment.
#
# Two back-ends are available:
#
#   family = "gaussian"  (default / fallback)
#       Pure base-R Gaussian copula -- no extra packages.  Fits the Gaussian
#       copula via rank-based Spearman correlation and draws from the
#       conditional Gaussian distribution.
#
#   family = "auto" | "<any rvinecopulib family>"
#       Delegates to the rvinecopulib package (listed in Suggests).
#       Families supported: "t", "clayton", "gumbel", "frank", "joe",
#       "bb1", "bb6", "bb7", "bb8", "tll", and all their 90/180/270-degree
#       rotations, plus the meta-sets "parametric", "onepar", "twopar",
#       and "all".
#       Multivariate dependencies are modelled as D-vine pair-copula
#       constructions; conditional simulation uses the Rosenblatt transform
#       (rosenblatt() / inverse_rosenblatt() from rvinecopulib).
#       Bivariate dependencies use bicop() + hbicop() for exact h-function
#       inversion.
#       family = "auto" lets rvinecopulib select the best-fitting family
#       per pair via AIC -- it falls back to "gaussian" when the package is
#       not installed.
#
# Variable ordering convention (rvinecopulib path):
#   columns of the pseudo-observation matrix = c(parents..., child)
#   Child is ALWAYS the last column so that the D-vine Rosenblatt
#   conditioning is c(u_p1,...,u_pk) -> u_child.


# -- ECDF helpers -------------------------------------------------------------

.build_ecdf <- function(values) {
  n           <- length(values)
  sorted_vals <- sort(values)
  cdf_u       <- (seq_len(n) - 0.5) / n      # mid-rank pseudo-obs
  list(sorted_vals = sorted_vals, cdf_u = cdf_u)
}

.ecdf_transform <- function(sv, cu, x) {
  u <- approx(sv, cu, xout = x, rule = 2)$y
  as.numeric(pmax(cu[1L], pmin(cu[length(cu)], u)))
}

.ecdf_quantile <- function(sv, cu, u) {
  u_clamped <- pmax(cu[1L], pmin(cu[length(cu)], u))
  approx(cu, sv, xout = u_clamped, rule = 2)$y
}


# -- Shared data preparation --------------------------------------------------
#
# Used by both the Gaussian and rvinecopulib back-ends.
# Returns:
#   var_types   named chr vector: "continuous" | "ordinal" | "categorical"
#   levels_map  named list of character vectors (for factor variables)
#   raw         named list of numeric-encoded column vectors
#   ecdf_tables named list of .build_ecdf() outputs
#   n           number of rows

.prepare_copula_vars <- function(variables, fit_data, nominal_handling) {
  var_types  <- character(length(variables))
  names(var_types) <- variables
  levels_map <- list()

  for (v in variables) {
    col <- fit_data[[v]]
    if (is.ordered(col)) {
      var_types[[v]]  <- "ordinal"
      levels_map[[v]] <- levels(col)
    } else if (is.factor(col)) {
      if (identical(nominal_handling, "regression")) {
        stop(sprintf(
          paste0("Variable '%s' is a nominal factor. ",
                 "Set nominal_handling = 'arbitrary_order' to include it ",
                 "in the copula (with a warning), or exclude it from `variables`."),
          v
        ))
      }
      warning(sprintf(
        "Variable '%s' is nominal categorical; included in the copula under an arbitrary level order.", v
      ), call. = FALSE)
      var_types[[v]]  <- "categorical"
      levels_map[[v]] <- levels(col)
    } else {
      var_types[[v]] <- "continuous"
    }
  }

  raw <- lapply(variables, function(v) {
    col <- fit_data[[v]]
    if (var_types[[v]] %in% c("ordinal", "categorical")) as.double(as.integer(col) - 1L)
    else as.double(col)
  })
  names(raw) <- variables

  ecdf_tables <- lapply(variables, function(v) .build_ecdf(raw[[v]]))
  names(ecdf_tables) <- variables

  list(
    var_types   = var_types,
    levels_map  = levels_map,
    raw         = raw,
    ecdf_tables = ecdf_tables,
    n           = nrow(fit_data)
  )
}


# -- Back-end 1: Gaussian copula (base R) -------------------------------------

.fit_gaussian_copula <- function(child, parents, fit_data, nominal_handling) {
  variables <- c(child, parents)
  prep      <- .prepare_copula_vars(variables, fit_data, nominal_handling)
  n         <- prep$n

  # Rank-based normal scores (van der Waerden)
  normal_scores <- vapply(variables, function(v) {
    ranks <- rank(prep$raw[[v]], ties.method = "average")
    qnorm((ranks - 0.5) / n)
  }, double(n))

  Corr <- cor(normal_scores)

  d <- length(parents)
  if (d == 0L) {
    mu_coefs <- numeric(0L)
    var_cond  <- 1.0
  } else {
    Corr_pp <- Corr[2:(d + 1L), 2:(d + 1L), drop = FALSE] + 1e-8 * diag(d)
    Corr_cp <- Corr[1L, 2:(d + 1L)]
    A        <- tryCatch(solve(Corr_pp, Corr_cp),
                         error = function(e) qr.solve(Corr_pp, Corr_cp))
    mu_coefs <- A
    var_cond  <- max(1e-8, 1.0 - sum(Corr_cp * A))
  }

  list(
    child = child, parents = parents,
    var_types   = prep$var_types,
    levels_map  = prep$levels_map,
    ecdf_tables = prep$ecdf_tables,
    mu_coefs    = mu_coefs,
    var_cond    = var_cond
  )
}


# -- Back-end 2: rvinecopulib -------------------------------------------------

# Canonical family aliases -> rvinecopulib family_set strings
.RVINE_FAMILY_ALIASES <- c(
  "auto"       = "all",
  "all"        = "all",
  "parametric" = "parametric",
  "onepar"     = "onepar",
  "twopar"     = "twopar",
  "t"          = "t",
  "student"    = "t",
  "student-t"  = "t",
  "clayton"    = "clayton",
  "gumbel"     = "gumbel",
  "frank"      = "frank",
  "joe"        = "joe",
  "bb1"        = "bb1",
  "bb6"        = "bb6",
  "bb7"        = "bb7",
  "bb8"        = "bb8",
  "tll"        = "tll",
  # rotations
  "clayton90"  = "rotated_clayton_90",
  "clayton180" = "rotated_clayton_180",
  "clayton270" = "rotated_clayton_270",
  "gumbel90"   = "rotated_gumbel_90",
  "gumbel180"  = "rotated_gumbel_180",
  "gumbel270"  = "rotated_gumbel_270",
  "joe90"      = "rotated_joe_90",
  "joe180"     = "rotated_joe_180",
  "joe270"     = "rotated_joe_270",
  "bb1_90"     = "rotated_bb1_90",
  "bb1_180"    = "rotated_bb1_180",
  "bb1_270"    = "rotated_bb1_270",
  "bb6_90"     = "rotated_bb6_90",
  "bb6_180"    = "rotated_bb6_180",
  "bb6_270"    = "rotated_bb6_270",
  "bb7_90"     = "rotated_bb7_90",
  "bb7_180"    = "rotated_bb7_180",
  "bb7_270"    = "rotated_bb7_270",
  "bb8_90"     = "rotated_bb8_90",
  "bb8_180"    = "rotated_bb8_180",
  "bb8_270"    = "rotated_bb8_270"
)

.normalise_family <- function(family) {
  key <- tolower(trimws(family))
  if (key %in% names(.RVINE_FAMILY_ALIASES)) .RVINE_FAMILY_ALIASES[[key]] else key
}

# Families that go to the Gaussian base-R path (no rvinecopulib needed)
.GAUSSIAN_KEYS <- c("gaussian", "auto")   # "auto" tries rvinecopulib first


# Fit a bivariate or vine copula via rvinecopulib.
# Variable order in pobs: (parents..., child) -- child in the LAST column.
# This guarantees that the D-vine Rosenblatt conditioning gives:
#   v[k+1] = F(u_child | u_p1, ..., u_pk)
# which is exactly what inverse_rosenblatt() inverts for the draw.

.fit_rvine_copula <- function(child, parents, fit_data, family, nominal_handling) {
  variables <- c(parents, child)      # <- child LAST
  d         <- length(variables)
  prep      <- .prepare_copula_vars(variables, fit_data, nominal_handling)
  n         <- prep$n

  # Rank-based pseudo-observations (all treated as "c" / continuous by rvinecopulib)
  pobs <- matrix(0.0, nrow = n, ncol = d, dimnames = list(NULL, variables))
  for (v in variables) {
    ranks      <- rank(prep$raw[[v]], ties.method = "average")
    pobs[, v]  <- (ranks - 0.5) / n
  }

  family_set <- .normalise_family(family)

  fitted <- if (d == 2L) {
    # -- Bivariate: bicop() -- enables exact h-function inversion ----------
    tryCatch(
      rvinecopulib::bicop(data = pobs, family_set = family_set),
      error = function(e) stop(sprintf(
        "rvinecopulib::bicop() failed [family = '%s']: %s", family, conditionMessage(e)
      ))
    )
  } else {
    # -- Multivariate: D-vine, child last --------------------------------
    # dvine_structure(1:d) orders variables 1,...,d left-to-right in the vine.
    # Column d = child -> Rosenblatt v[d] = F(u_child | u_p1,...,u_{d-1}).
    structure <- rvinecopulib::dvine_structure(seq_len(d))
    tryCatch(
      rvinecopulib::vinecop(data = pobs, structure = structure,
                            family_set = family_set),
      error = function(e) stop(sprintf(
        "rvinecopulib::vinecop() failed [family = '%s']: %s", family, conditionMessage(e)
      ))
    )
  }

  list(
    type        = if (d == 2L) "bicop" else "vinecop",
    model       = fitted,
    variables   = variables,
    child       = child,
    parents     = parents,
    var_types   = prep$var_types,
    levels_map  = prep$levels_map,
    ecdf_tables = prep$ecdf_tables
  )
}


# Draw one value for the child conditional on observed parent uniforms.
#
# Bivariate path:  h^{-1}(v | u_parent)  via hbicop(inverse = TRUE).
#
# D-vine path (Rosenblatt trick):
#   1. u_row  = [u_parents...,  0.5 (placeholder for child)]
#   2. v_row  = rosenblatt(u_row)
#      -> v[1:k] depend only on parent columns (child is last in D-vine)
#      -> v[k+1] = F(0.5 | u_parents) -- discard
#   3. v_row[k+1] <- runif(1)           -- fresh independent draw
#   4. u_new  = inverse_rosenblatt(v_row)
#      -> u_new[k+1] = F^{-1}(v_draw | u_parents)  <- the conditional sample
#   5. Return u_new[k+1] clamped to (0,1).

.rvine_conditional_sample <- function(u_parents, rv_model) {
  k <- length(rv_model$parents)

  # Helper: call hbicop and extract the scalar result regardless of API version.
  # Old rvinecopulib returns a matrix; new returns a plain numeric vector.
  .h <- function(a, b, cop, cond_var, inverse = FALSE) {
    res <- rvinecopulib::hbicop(matrix(c(a, b), nrow = 1L), cop,
                                cond_var = cond_var, inverse = inverse)
    if (is.matrix(res)) {
      as.double(res[1L, if (cond_var == 1L) 2L else 1L])
    } else {
      as.double(res[[1L]])
    }
  }

  if (rv_model$type == "bicop") {
    # Bivariate: h^{-1}(v | u_parent; C) — D-vine order is (parent, child),
    # so cond_var = 1 conditions on the parent column.
    v_child <- runif(1L)
    u_child <- .h(unname(u_parents[[1L]]), v_child,
                  rv_model$model, cond_var = 1L, inverse = TRUE)

  } else if (k == 2L) {
    # Trivariate D-vine — explicit sequential h-function algorithm.
    # Avoids rosenblatt() / inverse_rosenblatt() whose API changed in newer
    # rvinecopulib versions.
    #
    # D-vine order: (u1 = parent1, u2 = parent2, u3 = child)
    # Pair copulas:
    #   C_12    = pcs[[1]][[1]]   (tree 1, pair 1-2)
    #   C_23    = pcs[[1]][[2]]   (tree 1, pair 2-3)
    #   C_13_2  = pcs[[2]][[1]]   (tree 2, pair 1-3|2)
    #
    # Rosenblatt coordinate of the child:
    #   v3 = h(F_{3|2}(u3|u2) | F_{1|2}(u1|u2) ; C_{13|2})
    #
    # Inversion for simulation:
    #   a    = F_{1|2}(u1|u2)    = h(u1|u2 ; C_12)
    #   w    ~ U(0,1)            [fresh uniform replacing v3]
    #   temp = F_{3|2}(u3|u2) s.t. h(temp|a; C_{13|2}) = w
    #        = h^{-1}(w | a ; C_{13|2})
    #   u3   = h^{-1}(temp | u2 ; C_23)
    pcs    <- rv_model$model$pair_copulas   # direct slot access — pair_copulas() not exported
    C_12   <- pcs[[1L]][[1L]]
    C_23   <- pcs[[1L]][[2L]]
    C_13_2 <- pcs[[2L]][[1L]]

    u1 <- unname(u_parents[[1L]])
    u2 <- unname(u_parents[[2L]])

    a       <- .h(u2, u1, C_12,   cond_var = 1L)                 # h(u1|u2; C_12)
    w       <- runif(1L)
    temp    <- .h(a,  w,  C_13_2, cond_var = 1L, inverse = TRUE) # h^{-1}(w|a; C_{13|2})
    u_child <- .h(u2, temp, C_23, cond_var = 1L, inverse = TRUE) # h^{-1}(temp|u2; C_23)

  } else {
    # General multivariate D-vine (d > 3): Rosenblatt transform.
    u_row  <- matrix(unname(c(u_parents, 0.5)), nrow = 1L)
    v_row  <- as.matrix(rvinecopulib::rosenblatt(u_row, rv_model$model))
    v_row[1L, k + 1L] <- runif(1L)
    u_full <- as.matrix(rvinecopulib::inverse_rosenblatt(v_row, rv_model$model))
    u_child <- as.double(u_full[1L, k + 1L])
  }

  # Clamp to open unit interval to avoid ECDF boundary issues
  pmax(1e-6, pmin(1 - 1e-6, u_child))
}


# -- Public API ----------------------------------------------------------------

#' Copula-based dependency mechanism
#'
#' Fits a copula on `fit_data` and returns a `mechanism` that draws the child
#' feature conditional on realised parent values.  Supports both the built-in
#' Gaussian copula (base R, no extra packages) and the full family catalogue of
#' **rvinecopulib** (package must be installed for non-Gaussian families).
#'
#' @param variables Character vector.  **`variables[1]` is the child** (the
#'   feature to generate); `variables[-1]` are the parents.  Match with
#'   `add_dependency(parents = variables[-1], child = variables[1], ...)`.
#' @param family Copula family.  `"gaussian"` (default) uses the built-in
#'   base-R path.  `"auto"` uses **rvinecopulib** with AIC-based family
#'   selection if the package is installed, otherwise falls back to Gaussian.
#'   All other values require **rvinecopulib**:
#'   \itemize{
#'     \item Elliptical: `"t"`
#'     \item Archimedean: `"clayton"`, `"gumbel"`, `"frank"`, `"joe"`
#'     \item BB families: `"bb1"`, `"bb6"`, `"bb7"`, `"bb8"`
#'     \item Rotations: append `"90"`, `"180"`, or `"270"` (e.g. `"clayton90"`)
#'     \item Non-parametric: `"tll"`
#'     \item Meta-sets: `"onepar"`, `"twopar"`, `"parametric"`, `"all"`
#'   }
#' @param marginals `"auto"` (empirical CDF, rank-based).  Only `"auto"` is
#'   implemented in v1.
#' @param nominal_handling `"regression"` (default): error if a nominal factor
#'   appears in `variables`.  `"arbitrary_order"`: include with a warning.
#' @param fit_data A `data.frame` with all `variables` columns.  Required.
#'
#' @return A `mechanism` object (not JSON-serializable; `spec = NULL`).
#' @export
copula_mechanism <- function(variables,
                              family           = "gaussian",
                              marginals        = "auto",
                              nominal_handling = c("regression", "arbitrary_order"),
                              fit_data         = NULL) {
  nominal_handling <- match.arg(nominal_handling)
  if (is.null(fit_data))      stop("`fit_data` is required.")
  if (length(variables) < 1L) stop("`variables` must have at least 1 element.")

  child   <- variables[1L]
  parents <- variables[-1L]

  fam_key <- tolower(trimws(family))

  # -- Route: Gaussian (base R) vs. rvinecopulib ---------------------------
  use_gaussian <- fam_key == "gaussian"

  # "auto" uses rvinecopulib when available; falls back to Gaussian
  if (fam_key == "auto") {
    if (requireNamespace("rvinecopulib", quietly = TRUE)) {
      fam_key      <- "auto"   # passes "all" to rvinecopulib
      use_gaussian <- FALSE
    } else {
      message("rvinecopulib not installed -- using Gaussian copula for family = 'auto'.")
      use_gaussian <- TRUE
    }
  }

  if (!use_gaussian && !requireNamespace("rvinecopulib", quietly = TRUE)) {
    stop(sprintf(
      paste0("family = '%s' requires the rvinecopulib package.\n",
             "  Install it with:  install.packages('rvinecopulib')\n",
             "  Or use family = 'gaussian' for the built-in base-R fallback."),
      family
    ))
  }

  # ====================================================================
  # PATH A -- Gaussian copula (base R)
  # ====================================================================
  if (use_gaussian) {
    model     <- .fit_gaussian_copula(child, parents, fit_data, nominal_handling)
    sd_cond   <- sqrt(model$var_cond)
    et        <- model$ecdf_tables
    vt        <- model$var_types
    lm_       <- model$levels_map

    fn <- function(parent_values) {
      # 1. Transform parents -> normal scores
      z_parents <- vapply(model$parents, function(p) {
        raw <- if (vt[[p]] == "continuous") as.double(parent_values[[p]])
               else as.double(match(parent_values[[p]], lm_[[p]]) - 1L)
        u   <- .ecdf_transform(et[[p]]$sorted_vals, et[[p]]$cdf_u, raw)
        qnorm(u)
      }, double(1L))

      # 2. Conditional Gaussian draw
      mu_c    <- if (length(z_parents) > 0L) sum(model$mu_coefs * z_parents) else 0.0
      z_child <- rnorm(1L, mu_c, sd_cond)

      # 3. Normal score -> uniform -> child domain
      u_child <- pnorm(z_child)
      cu_ch   <- et[[child]]$cdf_u
      u_child <- pmax(cu_ch[1L], pmin(cu_ch[length(cu_ch)], u_child))
      raw_val <- .ecdf_quantile(et[[child]]$sorted_vals, cu_ch, u_child)

      if (vt[[child]] == "continuous") {
        as.double(raw_val)
      } else {
        k_lvl <- length(lm_[[child]])
        lm_[[child]][pmax(1L, pmin(k_lvl, round(raw_val) + 1L))]
      }
    }

    parent_types <- unname(model$var_types[parents])
    output_type  <- model$var_types[[child]]
    mech_name    <- "copula_gaussian"

  # ====================================================================
  # PATH B -- rvinecopulib (all non-Gaussian families + auto)
  # ====================================================================
  } else {
    rv_model <- .fit_rvine_copula(child, parents, fit_data, fam_key, nominal_handling)
    et       <- rv_model$ecdf_tables
    vt       <- rv_model$var_types
    lm_      <- rv_model$levels_map

    fn <- function(parent_values) {
      # 1. Transform each parent to the uniform scale via ECDF
      u_parents <- vapply(rv_model$parents, function(p) {
        raw <- if (vt[[p]] == "continuous") as.double(parent_values[[p]])
               else as.double(match(parent_values[[p]], lm_[[p]]) - 1L)
        .ecdf_transform(et[[p]]$sorted_vals, et[[p]]$cdf_u, raw)
      }, double(1L))

      # 2. Conditional draw via Rosenblatt / hbicop
      u_child <- .rvine_conditional_sample(u_parents, rv_model)

      # 3. Back-transform uniform -> child domain via inverse ECDF
      raw_val <- .ecdf_quantile(et[[child]]$sorted_vals, et[[child]]$cdf_u, u_child)

      if (vt[[child]] == "continuous") {
        as.double(raw_val)
      } else {
        k_lvl <- length(lm_[[child]])
        lm_[[child]][pmax(1L, pmin(k_lvl, round(raw_val) + 1L))]
      }
    }

    parent_types <- unname(rv_model$var_types[parents])
    output_type  <- rv_model$var_types[[child]]
    mech_name    <- paste0("copula_", .normalise_family(fam_key))
  }

  .new_mechanism(mech_name, fn, parent_types, output_type, spec = NULL)
}


#' List available copula families
#'
#' Returns `"gaussian"` always (built-in base-R path).  When **rvinecopulib**
#' is installed the full parametric family list is prepended, together with
#' the meta-set names `"auto"`, `"all"`, `"parametric"`, `"onepar"`,
#' `"twopar"`.
#'
#' @return Character vector of family identifiers accepted by
#'   [copula_mechanism()].
#' @export
list_copula_families <- function() {
  built_in <- "gaussian"

  if (!requireNamespace("rvinecopulib", quietly = TRUE)) {
    return(built_in)
  }

  # Known families as of rvinecopulib >= 0.6.0
  parametric <- c(
    "indep", "t",
    "clayton", "rotated_clayton_90", "rotated_clayton_180", "rotated_clayton_270",
    "gumbel",  "rotated_gumbel_90",  "rotated_gumbel_180",  "rotated_gumbel_270",
    "frank",
    "joe",     "rotated_joe_90",     "rotated_joe_180",     "rotated_joe_270",
    "bb1",     "rotated_bb1_90",     "rotated_bb1_180",     "rotated_bb1_270",
    "bb6",     "rotated_bb6_90",     "rotated_bb6_180",     "rotated_bb6_270",
    "bb7",     "rotated_bb7_90",     "rotated_bb7_180",     "rotated_bb7_270",
    "bb8",     "rotated_bb8_90",     "rotated_bb8_180",     "rotated_bb8_270",
    "tll"
  )

  meta_sets <- c("auto", "all", "parametric", "onepar", "twopar")

  unique(c(meta_sets, parametric, built_in))
}
