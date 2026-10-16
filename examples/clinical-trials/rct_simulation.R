# ==============================================================
# Clinical Trial Simulation with lepidoptera
# setwd("~/lepidoptera/lepidoptera/examples/clinical-trials")
#
# Scenario: Phase III RCT of a novel antihypertensive drug
#
# Causal DAG
# ──────────
#   age          (root) → comorbidity, baseline_bp, week12_bp
#   sex          (root) → baseline_bp, week12_bp
#   comorbidity  ← age         → baseline_bp, week12_bp
#   baseline_bp  ← age, sex, comorbidity → week12_bp
#   treatment    (randomized root) → side_effects, adherence, week12_bp
#   side_effects ← treatment   → adherence
#   adherence    ← treatment, side_effects → week12_bp
#   week12_bp    ← baseline_bp, treatment, adherence, age, comorbidity
#   response     ← baseline_bp, week12_bp  (≥ 10 mmHg reduction = responder)
#
# Demonstrated scenarios
# ──────────────────────
#   0. Baseline trial simulation (n = 500, 1:1 randomization)
#   1. ITT analysis          — do_fix("treatment", "active")
#   2. Per-protocol analysis — mechanism_override("adherence", full_adherence)
#   3. Enrichment strategy   — shift("baseline_bp", +15 mmHg) to simulate
#                              a severe-hypertension-only inclusion criterion
#   4. Elderly subgroup      — shift("age", +15 years)
# ==============================================================

library(lepidoptera)

# ── Custom mechanism: baseline systolic blood pressure ────────
# Parents: age (continuous), sex (categorical), comorbidity (ordinal)
# Hypertensive screening population, mu ≈ 150 mmHg at age 55

baseline_bp_fn <- function(pv) {
  mu <- 150 +
        (as.numeric(pv$age) - 55) * 0.45 +
        switch(as.character(pv$sex), M = 3, F = -3, 0) +
        switch(as.character(pv$comorbidity), none = 0, mild = 5, severe = 12, 0)
  rnorm(1, mu, sd = 12)
}
baseline_bp_mech <- register_mechanism(
  "baseline_bp_from_age_sex_comorbidity", baseline_bp_fn,
  parent_types = c("continuous", "categorical", "ordinal"),
  output_type  = "continuous"
)

# ── Custom mechanism: side effects (yes/no) ───────────────────
# Parent: treatment (categorical)
# Active arm has higher incidence due to vasodilatory effects

side_effects_fn <- function(pv) {
  p <- switch(as.character(pv$treatment), active = 0.28, placebo = 0.08, 0.08)
  sample(c("yes", "no"), 1L, prob = c(p, 1 - p))
}
side_effects_mech <- register_mechanism(
  "side_effects_from_treatment", side_effects_fn,
  parent_types = "categorical", output_type = "categorical"
)

# ── Custom mechanism: adherence (full / partial / none) ───────
# Parents: treatment (categorical), side_effects (categorical)
# Side effects reduce adherence regardless of arm

adherence_fn <- function(pv) {
  base_full <- switch(as.character(pv$treatment),
                      active = 0.72, placebo = 0.85, 0.72)
  if (as.character(pv$side_effects) == "yes") base_full <- base_full * 0.60
  p_partial <- (1 - base_full) * 0.55
  p_none    <- (1 - base_full) * 0.45
  sample(c("full", "partial", "none"), 1L,
         prob = c(base_full, p_partial, p_none))
}
adherence_mech <- register_mechanism(
  "adherence_from_treatment_side_effects", adherence_fn,
  parent_types = c("categorical", "categorical"), output_type = "ordinal"
)

# ── Custom mechanism: week-12 systolic BP (primary endpoint) ──
# Parents: baseline_bp, treatment, adherence, age, comorbidity
# Separates pharmacological effect from adherence-mediated attenuation

week12_bp_fn <- function(pv) {
  # Natural regression to mean
  drift <- rnorm(1, -2, 2)

  # Pharmacological effect is adherence-dependent
  tx_effect <- switch(as.character(pv$treatment),
    active = switch(as.character(pv$adherence),
      full    = rnorm(1, -14, 3),   # full effect: −14 mmHg
      partial = rnorm(1,  -8, 4),   # partial:      −8 mmHg
      none    = rnorm(1,   0, 3),   # non-adherent:  0 mmHg
      0),
    placebo = rnorm(1, 0, 2.5),     # placebo noise
    0)

  # Baseline covariates modulate the endpoint (not the treatment effect)
  age_mod   <- (as.numeric(pv$age) - 55) * 0.10
  comor_mod <- switch(as.character(pv$comorbidity),
                      none = 0, mild = 1.5, severe = 3.5, 0)

  rnorm(1, as.numeric(pv$baseline_bp) + drift + tx_effect + age_mod + comor_mod,
        sd = 4)
}
week12_bp_mech <- register_mechanism(
  "week12_bp_primary_endpoint", week12_bp_fn,
  parent_types = c("continuous", "categorical", "ordinal", "continuous", "ordinal"),
  output_type  = "continuous"
)

# ── Custom mechanism: responder status ───────────────────────
# Parents: baseline_bp, week12_bp (both continuous)
# Responder = ≥ 10 mmHg systolic reduction

response_fn <- function(pv) {
  reduction <- as.numeric(pv$baseline_bp) - as.numeric(pv$week12_bp)
  if (reduction >= 10) "responder" else "non_responder"
}
response_mech <- register_mechanism(
  "response_from_bp_reduction", response_fn,
  parent_types = c("continuous", "continuous"), output_type = "categorical"
)

# ── Build the trial system ────────────────────────────────────

trial <- new_system() |>

  # Feature declarations
  add_feature(feature_spec("age",          "continuous",
                           list(min = 18,  max = 85))) |>
  add_feature(feature_spec("sex",          "categorical",
                           list(levels = c("M", "F")))) |>
  add_feature(feature_spec("comorbidity",  "ordinal",
                           list(levels = c("none", "mild", "severe")))) |>
  add_feature(feature_spec("baseline_bp",  "continuous",
                           list(min = 120, max = 220))) |>
  add_feature(feature_spec("treatment",    "categorical",
                           list(levels = c("active", "placebo")))) |>
  add_feature(feature_spec("side_effects", "categorical",
                           list(levels = c("yes", "no")))) |>
  add_feature(feature_spec("adherence",    "ordinal",
                           list(levels = c("full", "partial", "none")))) |>
  add_feature(feature_spec("week12_bp",    "continuous",
                           list(min = 80,  max = 230))) |>
  add_feature(feature_spec("response",     "categorical",
                           list(levels = c("responder", "non_responder")))) |>

  # Root nodes — no parents
  add_dependency(character(0), "age",
    mechanism_library_get("normal")(mean = 55, sd = 12)) |>
  add_dependency(character(0), "sex",
    mechanism_library_get("categorical_marginal")(
      levels = c("M", "F"), probs = c(0.52, 0.48))) |>
  add_dependency(character(0), "treatment",
    mechanism_library_get("categorical_marginal")(
      levels = c("active", "placebo"), probs = c(0.5, 0.5))) |>   # 1:1 randomization

  # Comorbidity burden increases with age (ordered logistic regression)
  add_dependency("age", "comorbidity",
    mechanism_library_get("ordered_logit")(
      levels    = c("none", "mild", "severe"),
      coefs     = list(age = 0.06),
      cutpoints = c(2.5, 4.2))) |>

  # Baseline BP is determined by patient characteristics at screening
  add_dependency(c("age", "sex", "comorbidity"), "baseline_bp",
    baseline_bp_mech) |>

  # Treatment arm determines side-effect risk
  add_dependency("treatment", "side_effects", side_effects_mech) |>

  # Adherence depends on arm and side effects
  add_dependency(c("treatment", "side_effects"), "adherence", adherence_mech) |>

  # Primary endpoint: week-12 BP
  add_dependency(
    c("baseline_bp", "treatment", "adherence", "age", "comorbidity"),
    "week12_bp", week12_bp_mech) |>

  # Derived endpoint: responder status
  add_dependency(c("baseline_bp", "week12_bp"), "response", response_mech) |>

  finalize_system()


# ═══════════════════════════════════════════════════════════════
# Scenario 0 — Baseline trial (observed data, 1:1 randomization)
# ═══════════════════════════════════════════════════════════════
set.seed(42)
df_trial <- simulate(trial, n = 500, seed = 42)

cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Scenario 0: Baseline trial (n = 500, 1:1)          ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat("\nTreatment allocation:\n")
print(table(df_trial$treatment))
cat("\nAdherence by arm:\n")
print(table(df_trial$treatment, df_trial$adherence))
cat("\nSide effects by arm:\n")
print(table(df_trial$treatment, df_trial$side_effects))
cat("\nMean week-12 BP by arm (mmHg):\n")
print(round(tapply(df_trial$week12_bp, df_trial$treatment, mean), 1))
cat("\nMean baseline BP by arm (mmHg):\n")
print(round(tapply(df_trial$baseline_bp, df_trial$treatment, mean), 1))
cat("\nResponder rate by arm:\n")
print(round(prop.table(table(df_trial$treatment, df_trial$response),
                        margin = 1) * 100, 1))


# ═══════════════════════════════════════════════════════════════
# Scenario 1 — ITT: do(treatment = "active")
# ─────────────────────────────────────────────────────────────
# Causal query: what is the average treatment effect (ATE)?
# Counterfactual: same patients receive active drug instead of
# their observed (randomized) assignment.
# mode = "partial": reuses the same individual random draws —
# only the downstream values of treatment-affected nodes change.
# ═══════════════════════════════════════════════════════════════
r_itt <- propagate(trial,
  interventions = list(do_fix("treatment", "active")),
  n = 500, seed = 42, mode = "partial"
)

ate_bp       <- mean(r_itt$intervened$week12_bp) - mean(r_itt$baseline$week12_bp)
rr_active    <- mean(r_itt$intervened$response == "responder") * 100
rr_placebo   <- mean(r_itt$baseline$response   == "responder") * 100

cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Scenario 1: ITT — do(treatment = 'active')         ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat(sprintf("  Average treatment effect (ATE):  %+.1f mmHg\n", ate_bp))
cat(sprintf("  Responder rate — active arm:     %.1f%%\n",      rr_active))
cat(sprintf("  Responder rate — placebo arm:    %.1f%%\n",      rr_placebo))
cat(sprintf("  Absolute risk difference:        %+.1f pp\n",    rr_active - rr_placebo))

compare_itt <- compare(r_itt)
cat("\n  Variable-level summary (compare output):\n")
for (feat in c("side_effects", "adherence", "week12_bp", "response")) {
  if (feat %in% names(compare_itt)) {
    cat(sprintf("\n  [%s]\n", feat))
    print(compare_itt[[feat]])
  }
}


# ═══════════════════════════════════════════════════════════════
# Scenario 2 — Per-protocol: full adherence override
# ─────────────────────────────────────────────────────────────
# Causal query: what is the EFFICACY under perfect adherence?
# Combines do(treatment = "active") with a mechanism_override
# that forces adherence = "full" for every patient.
# The difference vs. ITT quantifies the adherence-dilution factor.
# ═══════════════════════════════════════════════════════════════
adherence_full_mech <- register_mechanism(
  "adherence_perfect_compliance",
  function(pv) "full",
  parent_types = c("categorical", "categorical"), output_type = "ordinal"
)

r_pp <- propagate(trial,
  interventions = list(
    do_fix("treatment", "active"),
    mechanism_override("adherence", adherence_full_mech)
  ),
  n = 500, seed = 42, mode = "partial"
)

ate_pp <- mean(r_pp$intervened$week12_bp) - mean(r_pp$baseline$week12_bp)

cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Scenario 2: Per-protocol (perfect adherence)       ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat(sprintf("  Per-protocol ATE:                %+.1f mmHg\n", ate_pp))
cat(sprintf("  ITT ATE:                         %+.1f mmHg\n", ate_bp))
cat(sprintf("  Adherence dilution:              %+.1f mmHg\n", ate_pp - ate_bp))
cat(sprintf("  PP responder rate:               %.1f%%\n",
    mean(r_pp$intervened$response == "responder") * 100))


# ═══════════════════════════════════════════════════════════════
# Scenario 3 — Enrichment: severe hypertension inclusion
# ─────────────────────────────────────────────────────────────
# Causal query: does restricting to high-baseline patients
# amplify the observed treatment effect?
# Simulates a stricter inclusion criterion (baseline BP ≥ 165)
# by shifting baseline_bp upward (+15 mmHg).
# ═══════════════════════════════════════════════════════════════
r_enrich <- propagate(trial,
  interventions = list(
    do_fix("treatment", "active"),
    shift("baseline_bp", function(x) x + 15)
  ),
  n = 500, seed = 42, mode = "partial"
)

ate_enrich <- mean(r_enrich$intervened$week12_bp) -
              mean(r_enrich$baseline$week12_bp)

cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Scenario 3: Enrichment — severe hypertension only  ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat(sprintf("  Mean baseline BP — standard:     %.1f mmHg\n",
    mean(r_enrich$baseline$baseline_bp)))
cat(sprintf("  Mean baseline BP — enriched:     %.1f mmHg\n",
    mean(r_enrich$intervened$baseline_bp)))
cat(sprintf("  ATE in enriched cohort:          %+.1f mmHg\n", ate_enrich))
cat(sprintf("  ATE in standard population:      %+.1f mmHg\n", ate_bp))
cat(sprintf("  Enrichment benefit:              %+.1f mmHg\n", ate_enrich - ate_bp))
cat(sprintf("  Responder rate (enriched):       %.1f%%\n",
    mean(r_enrich$intervened$response == "responder") * 100))


# ═══════════════════════════════════════════════════════════════
# Scenario 4 — Elderly subgroup (age > 65)
# ─────────────────────────────────────────────────────────────
# Causal query: how does treatment efficacy change in elderly?
# shift("age") propagates to comorbidity, baseline_bp, and the
# endpoint — capturing the full causal chain.
# Compare: run BOTH shifts together (active + elderly)
# vs. baseline to isolate the subgroup effect.
# ═══════════════════════════════════════════════════════════════
r_eld_active <- propagate(trial,
  interventions = list(
    shift("age", function(x) pmin(85, x + 20)),
    do_fix("treatment", "active")
  ),
  n = 500, seed = 42, mode = "full"
)
r_eld_placebo <- propagate(trial,
  interventions = list(
    shift("age", function(x) pmin(85, x + 20)),
    do_fix("treatment", "placebo")
  ),
  n = 500, seed = 42, mode = "full"
)

ate_elderly <- mean(r_eld_active$intervened$week12_bp) -
               mean(r_eld_placebo$intervened$week12_bp)

cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Scenario 4: Elderly subgroup (age + 20 years)      ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat(sprintf("  Mean age — standard cohort:      %.1f years\n",
    mean(r_eld_active$baseline$age)))
cat(sprintf("  Mean age — elderly cohort:       %.1f years\n",
    mean(r_eld_active$intervened$age)))
cat(sprintf("  Severe comorbidity — standard:   %.0f%%\n",
    mean(r_eld_active$baseline$comorbidity == "severe") * 100))
cat(sprintf("  Severe comorbidity — elderly:    %.0f%%\n",
    mean(r_eld_active$intervened$comorbidity == "severe") * 100))
cat(sprintf("  ATE in elderly subgroup:         %+.1f mmHg\n",   ate_elderly))
cat(sprintf("  ATE in full population (ITT):    %+.1f mmHg\n",   ate_bp))
cat(sprintf("  Responder rate — elderly active: %.1f%%\n",
    mean(r_eld_active$intervened$response == "responder") * 100))
cat(sprintf("  Responder rate — elderly placebo:%.1f%%\n",
    mean(r_eld_placebo$intervened$response == "responder") * 100))


# ═══════════════════════════════════════════════════════════════
# Summary table
# ═══════════════════════════════════════════════════════════════
cat("\n╔══════════════════════════════════════════════════════╗")
cat("\n║  Summary: ATE by analysis strategy                  ║")
cat("\n╚══════════════════════════════════════════════════════╝\n")
cat(sprintf(
  "  %-40s %+6.1f mmHg\n", "ITT (as-randomized):",          ate_bp))
cat(sprintf(
  "  %-40s %+6.1f mmHg\n", "Per-protocol (full adherence):", ate_pp))
cat(sprintf(
  "  %-40s %+6.1f mmHg\n", "Enriched (severe hypertension):", ate_enrich))
cat(sprintf(
  "  %-40s %+6.1f mmHg\n", "Elderly subgroup (age + 20 y):", ate_elderly))
cat("\n")
