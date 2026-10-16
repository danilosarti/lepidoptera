# Tests mapping to SPEC.md section 3.5 invariants and section 9 (parity
# test strategy). NOTE: these have been authored against the real R
# implementation but could not be executed in the authoring environment
# (no R interpreter available there) -- run `devtools::test()` locally to
# confirm before relying on them.

.toy_system <- function() {
  s <- new_system()
  s <- add_feature(s, feature_spec("age", "continuous", list(min = 0, max = 120)))
  s <- add_feature(s, feature_spec("group", "categorical", list(levels = c("A", "B"))))
  s <- add_feature(s, feature_spec("score", "continuous", list(min = -Inf, max = Inf)))
  s <- add_feature(s, feature_spec("risk", "ordinal", list(levels = c("low", "medium", "high"))))

  s <- add_dependency(s, character(0), "age", mechanism_library_get("normal")(mean = 40, sd = 10))
  s <- add_dependency(s, character(0), "group",
    mechanism_library_get("categorical_marginal")(levels = c("A", "B"), probs = c(0.5, 0.5)))
  s <- add_dependency(s, "age", "score",
    mechanism_library_get("linear_gaussian")(coefs = list(age = 0.5), intercept = 10, sd = 2))
  s <- add_dependency(s, "score", "risk",
    mechanism_library_get("ordered_logit")(
      levels = c("low", "medium", "high"), coefs = list(score = 0.1), cutpoints = c(2, 4)
    ))
  s
}

test_that("a finalized system simulates a typed population", {
  s <- finalize_system(.toy_system())
  expect_equal(s$topo_order, c("age", "group", "score", "risk"))

  df <- simulate(s, n = 50, seed = 1)
  expect_equal(nrow(df), 50)
  expect_true(is.numeric(df$age))
  expect_true(is.numeric(df$score))
  expect_true(is.factor(df$group) && !is.ordered(df$group))
  expect_true(is.ordered(df$risk))
})

test_that("simulate() is reproducible given the same seed", {
  s <- finalize_system(.toy_system())
  df1 <- simulate(s, n = 20, seed = 7)
  df2 <- simulate(s, n = 20, seed = 7)
  expect_equal(df1, df2)
})

test_that("a system with a cycle is rejected", {
  s <- new_system()
  s <- add_feature(s, feature_spec("x", "continuous", list(min = 0, max = 1)))
  s <- add_feature(s, feature_spec("y", "continuous", list(min = 0, max = 1)))
  s <- add_dependency(s, "y", "x", mechanism_library_get("linear_gaussian")(coefs = list(y = 1)))
  s <- add_dependency(s, "x", "y", mechanism_library_get("linear_gaussian")(coefs = list(x = 1)))
  expect_error(finalize_system(s), "cycle")
})

test_that("every feature must end up with exactly one mechanism", {
  s <- new_system()
  s <- add_feature(s, feature_spec("x", "continuous", list(min = 0, max = 1)))
  expect_error(finalize_system(s), "no mechanism")
})

test_that("edges referencing unknown features are rejected", {
  s <- new_system()
  s <- add_feature(s, feature_spec("x", "continuous", list(min = 0, max = 1)))
  s <- add_dependency(s, "ghost", "x", mechanism_library_get("linear_gaussian")(coefs = list(ghost = 1)))
  expect_error(finalize_system(s), "never added")
})

test_that("do_fix() propagates downstream and leaves unaffected features alone (mode = 'partial')", {
  s <- finalize_system(.toy_system())
  result <- propagate(s, list(do_fix("age", 80)), n = 200, seed = 42, mode = "partial")
  expect_true(all(result$baseline$group == result$intervened$group))
  expect_equal(unique(result$intervened$age), 80)
  expect_true(mean(result$intervened$score) > mean(result$baseline$score))
})
