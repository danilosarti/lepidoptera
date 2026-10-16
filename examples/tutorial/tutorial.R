# ==============================================================
# lepidoptera — step-by-step tutorial
# setwd("~/lepidoptera/lepidoptera/examples/tutorial")
# devtools::load_all("../../r-pkg")
#
# System: student exam performance
#
# DAG:
#   study_hours    (continuous, root)
#   prior_knowledge (ordinal: low/medium/high, root)
#   fatigue         (ordinal: low/moderate/high ← study_hours)
#   exam_score      (continuous ← study_hours, prior_knowledge, fatigue)
#   outcome         (categorical: fail/pass/distinction ← exam_score)
# ==============================================================

library(lepidoptera)

# ── Step 4: Mechanisms for root nodes ─────────────────────────

mech_study_hours <- mechanism_library_get("normal")(mean = 7, sd = 3)

mech_prior <- mechanism_library_get("ordinal_marginal")(
  levels = c("low", "medium", "high"),
  probs  = c(0.3, 0.5, 0.2)
)

# ── Step 5: Built-in mechanism for fatigue (ordinal child) ────

mech_fatigue <- mechanism_library_get("ordered_logit")(
  levels    = c("low", "moderate", "high"),
  coefs     = list(study_hours = 0.30),  # more hours → more fatigue
  cutpoints = c(1.5, 3.2)
)

# ── Step 6: Custom mechanisms ─────────────────────────────────

# exam_score ← study_hours (continuous)
#              prior_knowledge (ordinal)
#              fatigue (ordinal)
score_fn <- function(pv) {
  mu <- 40 + as.numeric(pv$study_hours) * 4.5

  mu <- mu + switch(as.character(pv$prior_knowledge),
    low    = -10,
    medium =   0,
    high   = +10,
    0)

  mu <- mu + switch(as.character(pv$fatigue),
    low      =   0,
    moderate =  -5,
    high     = -15,
    0)

  pmin(100, pmax(0, rnorm(1, mu, sd = 8)))
}

mech_score <- register_mechanism(
  "score_from_study_knowledge_fatigue",
  score_fn,
  parent_types = c("continuous", "ordinal", "ordinal"),
  output_type  = "continuous"
)

# outcome ← exam_score (threshold rule)
outcome_fn <- function(pv) {
  s <- as.numeric(pv$exam_score)
  if      (s >= 75) "distinction"
  else if (s >= 50) "pass"
  else              "fail"
}

mech_outcome <- register_mechanism(
  "outcome_from_score",
  outcome_fn,
  parent_types = "continuous",
  output_type  = "categorical"
)

# ── Step 7: Assemble and finalize ─────────────────────────────

exam_sys <- new_system() |>

  # Features
  add_feature(feature_spec("study_hours",     "continuous",
                           list(min = 0, max = 20))) |>
  add_feature(feature_spec("prior_knowledge", "ordinal",
                           list(levels = c("low", "medium", "high")))) |>
  add_feature(feature_spec("fatigue",         "ordinal",
                           list(levels = c("low", "moderate", "high")))) |>
  add_feature(feature_spec("exam_score",      "continuous",
                           list(min = 0, max = 100))) |>
  add_feature(feature_spec("outcome",         "categorical",
                           list(levels = c("fail", "pass", "distinction")))) |>

  # Dependencies
  add_dependency(character(0),                                  "study_hours",     mech_study_hours) |>
  add_dependency(character(0),                                  "prior_knowledge", mech_prior)       |>
  add_dependency("study_hours",                                 "fatigue",         mech_fatigue)     |>
  add_dependency(c("study_hours", "prior_knowledge", "fatigue"),"exam_score",      mech_score)       |>
  add_dependency("exam_score",                                  "outcome",         mech_outcome)     |>

  finalize_system()

cat("System finalized.\n")

# ── Step 8: Simulate a population ─────────────────────────────

df <- simulate(exam_sys, n = 1000, seed = 42)

cat("\n── Baseline population (n = 1000) ─────────────────────\n")
cat("\nFirst 6 rows:\n")
print(head(df))
cat("\nOutcome distribution:\n")
print(prop.table(table(df$outcome)))
cat("\nMean score by prior knowledge:\n")
print(round(tapply(df$exam_score, df$prior_knowledge, mean), 1))

# ── Step 10 & 11: Intervention — do_fix study_hours = 12 ─────

r <- propagate(exam_sys,
  interventions = list(do_fix("study_hours", 12)),
  n    = 1000,
  seed = 42,
  mode = "partial"   # same students, hypothetically studied more
)

cat("\n── Intervention: do_fix('study_hours', 12) ─────────────\n")
cat(sprintf("\nMean exam score — baseline:    %.1f\n", mean(r$baseline$exam_score)))
cat(sprintf("Mean exam score — intervened:  %.1f\n",  mean(r$intervened$exam_score)))
cat(sprintf("Mean shift:                   %+.1f\n",
    mean(r$intervened$exam_score) - mean(r$baseline$exam_score)))

cat("\nOutcome distribution:\n")
cat("           fail    pass  distinction\n")
cat(sprintf("baseline   %.1f%%  %.1f%%  %.1f%%\n",
    mean(r$baseline$outcome   == "fail")        * 100,
    mean(r$baseline$outcome   == "pass")        * 100,
    mean(r$baseline$outcome   == "distinction") * 100))
cat(sprintf("intervened %.1f%%  %.1f%%  %.1f%%\n",
    mean(r$intervened$outcome == "fail")        * 100,
    mean(r$intervened$outcome == "pass")        * 100,
    mean(r$intervened$outcome == "distinction") * 100))

delta <- compare(r)
cat("\ncompare() — exam_score summary:\n")
print(delta[["exam_score"]])

# ── Step 12: More interventions ───────────────────────────────

# shift: +3 study hours above what each student would naturally do
r_shift <- propagate(exam_sys,
  interventions = list(shift("study_hours", function(x) x + 3)),
  n = 1000, seed = 42, mode = "partial"
)

cat("\n── Intervention: shift('study_hours', +3 h) ────────────\n")
cat(sprintf("Mean score shift: %+.1f\n",
    mean(r_shift$intervened$exam_score) - mean(r_shift$baseline$exam_score)))

# Multiple interventions: best-case student
r_best <- propagate(exam_sys,
  interventions = list(
    do_fix("study_hours",    12),
    do_fix("prior_knowledge","high")
  ),
  n = 1000, seed = 42, mode = "partial"
)

cat("\n── Intervention: best-case (study=12 + knowledge=high) ─\n")
cat(sprintf("Distinction rate: %.1f%%\n",
    mean(r_best$intervened$outcome == "distinction") * 100))

cat("\nDone. Open tutorial.html for the annotated walkthrough.\n")

# ── Step 13: Counterfactual — individual "what if?" ───────────

# Same system, same seed → same 1000 individuals
# mode = "partial" keeps each person's prior_knowledge + noise fixed;
# only study_hours and its downstream consequences change.

r_cf <- propagate(exam_sys,
  interventions = list(do_fix("study_hours", 10)),
  n    = 1000,
  seed = 42,
  mode = "partial"   # ← counterfactual: same individuals, different choice
)

# Among those who actually failed: what would have happened?
actually_failed <- r_cf$baseline$outcome == "fail"
cf_outcomes     <- r_cf$intervened$outcome[actually_failed]

cat(sprintf("\n── Counterfactual: what if every failing student had studied 10 h? ─\n"))
cat(sprintf("Among %d students who actually failed:\n", sum(actually_failed)))
cat(sprintf("  would still fail:        %d  (%.0f%%)\n",
    sum(cf_outcomes == "fail"),        mean(cf_outcomes == "fail")        * 100))
cat(sprintf("  would pass:              %d  (%.0f%%)\n",
    sum(cf_outcomes == "pass"),        mean(cf_outcomes == "pass")        * 100))
cat(sprintf("  would get distinction:   %d  (%.0f%%)\n",
    sum(cf_outcomes == "distinction"), mean(cf_outcomes == "distinction") * 100))

# Zoom in on one specific student
i <- which(actually_failed)[1]
cat(sprintf("\nStudent #%d — what actually happened:\n", i))
print(r_cf$baseline[i, ])
cat(sprintf("Student #%d — counterfactual (study = 10 h):\n", i))
print(r_cf$intervened[i, ])

# ── Step 14: Copula mechanism — dependence structure from data ──────────

# Generate observed data with a known negative correlation
set.seed(1)
n_obs   <- 400
obs_data <- data.frame(
  study_hours = rnorm(n_obs, 6, 2),
  sleep_hours = rnorm(n_obs, 7, 1.2)
)
# students who study more sleep slightly less
obs_data$sleep_hours <- obs_data$sleep_hours -
  0.4 * obs_data$study_hours + rnorm(n_obs, 0, .8)

# Fit a copula mechanism: learns the joint dependence automatically
mech_sleep <- copula_mechanism(
  variables = c("sleep_hours", "study_hours"),  # child first, parents after
  family    = "auto",                            # best-fit per pair via AIC
  fit_data  = obs_data
)

mech_study <- mechanism_library_get("normal")(mean = 6, sd = 2)

sys_cop <- new_system() |>
  add_feature(feature_spec("study_hours", "continuous", list(min = 0, max = 24))) |>
  add_feature(feature_spec("sleep_hours",  "continuous", list(min = 0, max = 24))) |>
  add_dependency(character(0),  "study_hours", mech_study) |>
  add_dependency("study_hours", "sleep_hours", mech_sleep) |>
  finalize_system()

sim_cop <- simulate(sys_cop, n = 600, seed = 42)
cat("\n── Step 14: copula_mechanism ────────────────────────\n")
cat(sprintf("Observed Spearman r(study, sleep)  = %.2f\n",
    cor(obs_data$study_hours, obs_data$sleep_hours, method = "spearman")))
cat(sprintf("Simulated Spearman r(study, sleep) = %.2f\n",
    cor(sim_cop$study_hours, sim_cop$sleep_hours, method = "spearman")))

cat("\nFamilies available on this installation:\n")
print(list_copula_families())

# ── Step 15: model_mechanism — wrap any pre-fitted model ───────────────

# Fit a linear model on observed data
set.seed(7)
df_fit <- data.frame(age = rnorm(200, 50, 10), sbp = rnorm(200, 120, 15))
fit_lm <- lm(sbp ~ age, data = df_fit)
sigma  <- summary(fit_lm)$sigma

# Wrap it as a mechanism: predict_fn receives parent_values, returns one value
mech_sbp <- model_mechanism(
  predict_fn   = function(pv) {
    nd   <- data.frame(age = as.numeric(pv$age))
    pred <- predict(fit_lm, nd)[[1L]]
    pred + rnorm(1, 0, sigma)   # add residual noise manually
  },
  parents      = "age",
  parent_types = "continuous",
  output_type  = "continuous"
)

mech_age <- mechanism_library_get("normal")(mean = 50, sd = 10)

sys_mm <- new_system() |>
  add_feature(feature_spec("age", "continuous", list(min = 0,  max = 120))) |>
  add_feature(feature_spec("sbp", "continuous", list(min = 60, max = 260))) |>
  add_dependency(character(0), "age", mech_age) |>
  add_dependency("age",        "sbp", mech_sbp) |>
  finalize_system()

sim_mm <- simulate(sys_mm, n = 400, seed = 1)
cat("\n── Step 15: model_mechanism ─────────────────────────\n")
cat(sprintf("Spearman r(age, sbp) in simulation = %.2f\n",
    cor(sim_mm$age, sim_mm$sbp, method = "spearman")))
