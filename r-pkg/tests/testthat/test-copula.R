# Tests for copula_mechanism() and model_mechanism() -------------------------
#
# copula tests that require rvinecopulib are wrapped in
# skip_if_not_installed("rvinecopulib").  The Gaussian path tests run always.

library(lepidoptera)

# ── Helpers ──────────────────────────────────────────────────────────────────

# Bivariate dataset with known positive rank correlation (~0.7)
.make_bivar <- function(n = 400, seed = 1L) {
  set.seed(seed)
  x  <- rnorm(n)
  y  <- 0.7 * x + sqrt(1 - 0.49) * rnorm(n)
  data.frame(x = x, y = y)
}

# Trivariate dataset: z depends on both x and y
.make_trivar <- function(n = 400, seed = 2L) {
  set.seed(seed)
  x <- rnorm(n)
  y <- rnorm(n)
  z <- 0.5 * x + 0.4 * y + 0.5 * rnorm(n)
  data.frame(x = x, y = y, z = z)
}

# Build a minimal lepidoptera system for copula testing
.build_copula_system <- function(fit_data, family = "gaussian") {
  mech_x <- mechanism_library_get("normal")(mean = 0, sd = 1)
  mech_y <- copula_mechanism(
    variables = c("y", "x"),
    family    = family,
    fit_data  = fit_data
  )

  new_system() |>
    add_feature(feature_spec("x", "continuous", list(min = -Inf, max = Inf))) |>
    add_feature(feature_spec("y", "continuous", list(min = -Inf, max = Inf))) |>
    add_dependency(character(0), "x", mech_x) |>
    add_dependency("x",          "y", mech_y) |>
    finalize_system()
}


# ── 1. Gaussian copula (base R — always runs) ─────────────────────────────────

test_that("copula_mechanism(family='gaussian') preserves positive correlation", {
  df  <- .make_bivar()
  sys <- .build_copula_system(df, family = "gaussian")
  sim <- simulate(sys, n = 600, seed = 42L)

  r <- cor(sim$x, sim$y, method = "spearman")
  expect_gt(r, 0.4)   # should recover substantial correlation
})

test_that("copula_mechanism(family='gaussian') with mode='partial' respects parent values", {
  df  <- .make_bivar()
  mech_y <- copula_mechanism(variables = c("y", "x"), family = "gaussian",
                              fit_data = df)
  # For a high x value the expected y should be above the unconditional mean
  draws <- replicate(200, mech_y$fn(list(x = 2.5)))
  expect_gt(mean(draws), 0)
})

test_that("copula_mechanism() errors when fit_data is missing", {
  expect_error(copula_mechanism(c("y","x")), "`fit_data` is required")
})

test_that("copula_mechanism(nominal_handling='regression') rejects nominal factor", {
  df <- data.frame(
    x = rnorm(50),
    g = factor(rep(c("a","b"), 25))   # unordered → nominal
  )
  expect_error(
    copula_mechanism(c("x","g"), fit_data = df, nominal_handling = "regression"),
    "nominal factor"
  )
})

test_that("copula_mechanism(nominal_handling='arbitrary_order') warns but continues", {
  df <- data.frame(
    x = rnorm(50),
    g = factor(rep(c("a","b"), 25))
  )
  expect_warning(
    copula_mechanism(c("x","g"), fit_data = df, nominal_handling = "arbitrary_order"),
    "nominal"
  )
})

test_that("list_copula_families() always includes 'gaussian'", {
  expect_true("gaussian" %in% list_copula_families())
})


# ── 2. rvinecopulib back-end ──────────────────────────────────────────────────

test_that("copula_mechanism(family='t') fits a t-copula and preserves correlation", {
  skip_if_not_installed("rvinecopulib")

  df  <- .make_bivar()
  sys <- .build_copula_system(df, family = "t")
  sim <- simulate(sys, n = 600, seed = 99L)

  r <- cor(sim$x, sim$y, method = "spearman")
  expect_gt(r, 0.4)
})

test_that("copula_mechanism(family='clayton') captures lower-tail dependence", {
  skip_if_not_installed("rvinecopulib")

  # Clayton copula has strong lower-tail dependence.
  # Simulate from a genuine Clayton DGP and check that the mechanism
  # recovers lower-tail concordance.
  set.seed(7L)
  n  <- 500
  # Clayton(theta=3) samples via conditional method
  u1 <- runif(n)
  v  <- runif(n)
  theta <- 3
  u2 <- (v^(-theta / (1 + theta)) * (u1^(-theta) - 1) + 1)^(-1 / theta)
  df <- data.frame(
    x = qnorm(u1),
    y = qnorm(pmax(1e-6, pmin(1 - 1e-6, u2)))
  )

  mech_y <- copula_mechanism(variables = c("y", "x"), family = "clayton",
                              fit_data = df)

  # Conditional on a low x (below 10th pctile), mean y should be low
  low_x_draws  <- replicate(300, mech_y$fn(list(x = -1.5)))
  high_x_draws <- replicate(300, mech_y$fn(list(x =  1.5)))
  expect_lt(mean(low_x_draws), mean(high_x_draws))
})

test_that("copula_mechanism(family='gumbel') handles upper-tail families", {
  skip_if_not_installed("rvinecopulib")
  df  <- .make_bivar()
  mech_y <- copula_mechanism(variables = c("y","x"), family = "gumbel",
                              fit_data = df)
  expect_s3_class(mech_y, "mechanism")
  draws <- replicate(100, mech_y$fn(list(x = 1.0)))
  expect_true(is.numeric(draws))
})

test_that("copula_mechanism(family='frank') works for symmetric tail", {
  skip_if_not_installed("rvinecopulib")
  df    <- .make_bivar()
  mech  <- copula_mechanism(variables = c("y","x"), family = "frank",
                             fit_data = df)
  draws <- replicate(100, mech$fn(list(x = 0)))
  expect_true(is.numeric(draws))
})

test_that("copula_mechanism(family='joe') works", {
  skip_if_not_installed("rvinecopulib")
  df    <- .make_bivar()
  mech  <- copula_mechanism(variables = c("y","x"), family = "joe",
                             fit_data = df)
  draws <- replicate(100, mech$fn(list(x = 0)))
  expect_true(is.numeric(draws))
})

test_that("copula_mechanism(family='bb1') works", {
  skip_if_not_installed("rvinecopulib")
  df    <- .make_bivar()
  mech  <- copula_mechanism(variables = c("y","x"), family = "bb1",
                             fit_data = df)
  draws <- replicate(100, mech$fn(list(x = 0)))
  expect_true(is.numeric(draws))
})

test_that("copula_mechanism(family='tll') works (non-parametric TLL)", {
  skip_if_not_installed("rvinecopulib")
  df    <- .make_bivar(n = 200)
  mech  <- copula_mechanism(variables = c("y","x"), family = "tll",
                             fit_data = df)
  draws <- replicate(100, mech$fn(list(x = 0)))
  expect_true(is.numeric(draws))
})

test_that("copula_mechanism(family='auto') selects a family and works end-to-end", {
  skip_if_not_installed("rvinecopulib")

  df  <- .make_bivar()
  sys <- .build_copula_system(df, family = "auto")
  sim <- simulate(sys, n = 400, seed = 5L)

  r <- cor(sim$x, sim$y, method = "spearman")
  expect_gt(r, 0.3)
})

test_that("copula_mechanism works with 2 parents (D-vine, 3 variables)", {
  skip_if_not_installed("rvinecopulib")

  df <- .make_trivar()

  # z depends on x and y via a vine copula
  mech_x <- mechanism_library_get("normal")(mean = 0, sd = 1)
  mech_y <- mechanism_library_get("normal")(mean = 0, sd = 1)
  mech_z <- copula_mechanism(
    variables = c("z", "x", "y"),   # z = child, x and y = parents
    family    = "auto",
    fit_data  = df
  )

  sys <- new_system() |>
    add_feature(feature_spec("x", "continuous", list(min = -Inf, max = Inf))) |>
    add_feature(feature_spec("y", "continuous", list(min = -Inf, max = Inf))) |>
    add_feature(feature_spec("z", "continuous", list(min = -Inf, max = Inf))) |>
    add_dependency(character(0),   "x", mech_x) |>
    add_dependency(character(0),   "y", mech_y) |>
    add_dependency(c("x", "y"),    "z", mech_z) |>
    finalize_system()

  sim <- simulate(sys, n = 400, seed = 10L)
  expect_equal(nrow(sim), 400L)

  # z should correlate positively with both x and y
  expect_gt(cor(sim$z, sim$x, method = "spearman"), 0.2)
  expect_gt(cor(sim$z, sim$y, method = "spearman"), 0.1)
})

test_that("list_copula_families() returns all rvinecopulib families when installed", {
  skip_if_not_installed("rvinecopulib")

  fams <- list_copula_families()
  expect_true("gaussian"   %in% fams)
  expect_true("t"          %in% fams)
  expect_true("clayton"    %in% fams)
  expect_true("gumbel"     %in% fams)
  expect_true("frank"      %in% fams)
  expect_true("joe"        %in% fams)
  expect_true("auto"       %in% fams)
})

test_that("copula_mechanism() without rvinecopulib gives clear error for non-Gaussian", {
  # Simulate the case where rvinecopulib is absent by patching requireNamespace
  # via mocking. testthat::with_mocked_bindings not available pre-3.1.1 so we
  # test the error message on the real installation conditionally.
  skip_if(requireNamespace("rvinecopulib", quietly = TRUE),
          "rvinecopulib is installed — skip missing-package error test")

  df <- .make_bivar(n = 50)
  expect_error(
    copula_mechanism(c("y","x"), family = "clayton", fit_data = df),
    "rvinecopulib"
  )
})

test_that("copula_mechanism outputs are in the child's empirical range", {
  skip_if_not_installed("rvinecopulib")

  df    <- .make_bivar()
  mech  <- copula_mechanism(variables = c("y","x"), family = "auto",
                             fit_data = df)
  draws <- replicate(200, mech$fn(list(x = 0)))

  # Should stay roughly within 4 sds of observed y
  expect_true(all(draws > min(df$y) - 5))
  expect_true(all(draws < max(df$y) + 5))
})


# ── 3. model_mechanism() ──────────────────────────────────────────────────────

test_that("model_mechanism() wraps a pre-fitted lm", {
  set.seed(1L)
  df     <- data.frame(age = rnorm(100, 50, 10), sbp = rnorm(100, 120, 15))
  fit    <- lm(sbp ~ age, data = df)
  sigma  <- summary(fit)$sigma

  mech <- model_mechanism(
    predict_fn   = function(pv) {
      nd   <- data.frame(age = as.numeric(pv$age))
      pred <- predict(fit, nd)[[1L]]
      pred + rnorm(1L, 0, sigma)
    },
    parents      = "age",
    parent_types = "continuous",
    output_type  = "continuous"
  )

  expect_s3_class(mech, "mechanism")
  draws <- replicate(200, mech$fn(list(age = 60)))
  expect_true(is.numeric(draws))
  expect_gt(mean(draws), 100)   # intercept > 0 for typical data
})

test_that("model_mechanism() integrates into a full system", {
  set.seed(2L)
  n      <- 200
  df_fit <- data.frame(age = rnorm(n, 50, 10), sbp = rnorm(n, 120, 15))
  fit    <- lm(sbp ~ age, data = df_fit)
  sigma  <- summary(fit)$sigma

  mech_age <- mechanism_library_get("normal")(mean = 50, sd = 10)
  mech_sbp <- model_mechanism(
    predict_fn   = function(pv) {
      nd <- data.frame(age = as.numeric(pv$age))
      predict(fit, nd)[[1L]] + rnorm(1L, 0, sigma)
    },
    parents      = "age",
    parent_types = "continuous",
    output_type  = "continuous"
  )

  sys <- new_system() |>
    add_feature(feature_spec("age", "continuous", list(min = 0, max = 120))) |>
    add_feature(feature_spec("sbp", "continuous", list(min = 60, max = 260))) |>
    add_dependency(character(0), "age", mech_age) |>
    add_dependency("age",        "sbp", mech_sbp) |>
    finalize_system()

  sim <- simulate(sys, n = 300, seed = 42L)
  expect_equal(nrow(sim), 300L)
  expect_true(cor(sim$age, sim$sbp, method = "spearman") > 0)
})

test_that("model_mechanism() works for categorical output", {
  set.seed(3L)
  mech <- model_mechanism(
    predict_fn   = function(pv) {
      p <- plogis(as.numeric(pv$x))   # logistic probability
      sample(c("yes", "no"), 1L, prob = c(p, 1 - p))
    },
    parents      = "x",
    parent_types = "continuous",
    output_type  = "categorical",
    levels       = c("yes", "no")
  )

  draws <- replicate(300, mech$fn(list(x = 3)))   # high x → mostly "yes"
  expect_gt(mean(draws == "yes"), 0.8)
})

test_that("model_mechanism() errors on non-function predict_fn", {
  expect_error(
    model_mechanism(predict_fn = "not_a_function", parents = "x",
                    parent_types = "continuous", output_type = "continuous"),
    "function"
  )
})

test_that("model_mechanism() errors when parents/parent_types length mismatch", {
  expect_error(
    model_mechanism(predict_fn = function(pv) 0, parents = c("x","y"),
                    parent_types = "continuous", output_type = "continuous"),
    "same length"
  )
})
