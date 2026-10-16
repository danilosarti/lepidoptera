library(lepidoptera)

# ==============================================================
# Simulation: emergency triage — patients with/without pneumonia
#
# Causal DAG:
#   age             ───────────────────────────────────────────┐
#   comorbidity     ← age                                      │
#   pneumonia       ← comorbidity                              │
#   sex             (demographic root)                         │
#   temp            ← pneumonia                                │
#   resp_rate       ← pneumonia                                │
#   spo2            ← pneumonia + comorbidity                  │
#   severity        ← spo2 + comorbidity                       │
#   hospitalization ← severity + age ────────────────────────┘
#   icu             ← severity + hospitalization
#   outcome         ← icu + severity + comorbidity + age
# ==============================================================


# ── Custom mechanisms (mixed-type combinations not covered
#    by the pre-built factories) ─────────────────────────────

# pneumonia ~ comorbidity (ordinal → categorical)
pneumonia_fn <- function(pv) {
  p <- switch(as.character(pv$comorbidity),
              none   = 0.18,
              mild   = 0.38,
              severe = 0.62,
              0.18)
  sample(c("yes", "no"), 1L, prob = c(p, 1 - p))
}
pneumonia_mech <- register_mechanism(
  "pneumonia_comorbidity", pneumonia_fn,
  parent_types = "ordinal", output_type = "categorical"
)

# spo2 ~ pneumonia (categorical) + comorbidity (ordinal) → continuous
spo2_fn <- function(pv) {
  base    <- if (as.character(pv$pneumonia) == "yes") 88 else 97
  penalty <- switch(as.character(pv$comorbidity),
                    none   = 0,
                    mild   = -1.5,
                    severe = -4,
                    0)
  rnorm(1, base + penalty, sd = 2.5)
}
spo2_mech <- register_mechanism(
  "spo2_pneumonia_comorbidity", spo2_fn,
  parent_types = c("categorical", "ordinal"), output_type = "continuous"
)

# severity ~ spo2 (continuous) + comorbidity (ordinal) → ordinal
severity_fn <- function(pv) {
  comor_score <- switch(as.character(pv$comorbidity),
                        none   = 0,
                        mild   = 0.6,
                        severe = 1.5,
                        0)
  latent <- (95 - as.numeric(pv$spo2)) * 0.18 + comor_score + rlogis(1)
  if (latent < 0.9) "mild" else if (latent < 2.3) "moderate" else "severe"
}
severity_mech <- register_mechanism(
  "severity_spo2_comorbidity", severity_fn,
  parent_types = c("continuous", "ordinal"), output_type = "ordinal"
)

# hospitalization ~ severity (ordinal) + age (continuous) → categorical
hospitalization_fn <- function(pv) {
  base <- switch(as.character(pv$severity),
                 mild     = 0.08,
                 moderate = 0.55,
                 severe   = 0.92,
                 0.08)
  p <- pmin(0.98, pmax(0.02, base + (as.numeric(pv$age) - 50) * 0.007))
  sample(c("yes", "no"), 1L, prob = c(p, 1 - p))
}
hospitalization_mech <- register_mechanism(
  "hospitalization_severity_age", hospitalization_fn,
  parent_types = c("ordinal", "continuous"), output_type = "categorical"
)

# icu ~ severity (ordinal) + hospitalization (categorical) → categorical
icu_fn <- function(pv) {
  if (as.character(pv$hospitalization) == "no") return("no")
  p <- switch(as.character(pv$severity),
              mild     = 0.02,
              moderate = 0.20,
              severe   = 0.65,
              0.02)
  sample(c("yes", "no"), 1L, prob = c(p, 1 - p))
}
icu_mech <- register_mechanism(
  "icu_severity_hospitalization", icu_fn,
  parent_types = c("ordinal", "categorical"), output_type = "categorical"
)

# outcome ~ icu (cat) + severity (ord) + comorbidity (ord) + age (cont)
outcome_fn <- function(pv) {
  lvls  <- c("discharge", "improvement", "worsening", "death")
  probs <- if (as.character(pv$icu) == "yes") {
    c(0.08, 0.32, 0.38, 0.22)
  } else {
    switch(as.character(pv$severity),
      mild     = c(0.880, 0.100, 0.015, 0.005),
      moderate = c(0.550, 0.350, 0.080, 0.020),
      severe   = c(0.180, 0.420, 0.280, 0.120),
      c(0.550, 0.350, 0.080, 0.020)   # fallback
    )
  }
  # Adjust for comorbidity and age
  delta    <- (switch(as.character(pv$comorbidity),
                      none   = 0,
                      mild   = 0.03,
                      severe = 0.08,
                      0) +
               (as.numeric(pv$age) - 50) * 0.001)
  probs[1] <- probs[1] - delta   # discharge less likely
  probs[4] <- probs[4] + delta   # death more likely
  probs    <- pmax(0.001, probs)
  sample(lvls, 1L, prob = probs / sum(probs))
}
outcome_mech <- register_mechanism(
  "outcome_icu_sev_comor_age", outcome_fn,
  parent_types = c("categorical", "ordinal", "ordinal", "continuous"),
  output_type  = "ordinal"
)


# ── Build the system ──────────────────────────────────────────

hospital <- new_system() |>

  # Features
  add_feature(feature_spec("age",             "continuous",
                           list(min = 18, max = 100))) |>
  add_feature(feature_spec("sex",             "categorical",
                           list(levels = c("M", "F")))) |>
  add_feature(feature_spec("comorbidity",     "ordinal",
                           list(levels = c("none", "mild", "severe")))) |>
  add_feature(feature_spec("pneumonia",       "categorical",
                           list(levels = c("yes", "no")))) |>
  add_feature(feature_spec("temp",            "continuous",
                           list(min = 35, max = 42))) |>
  add_feature(feature_spec("resp_rate",       "continuous",
                           list(min = 8,  max = 50))) |>
  add_feature(feature_spec("spo2",            "continuous",
                           list(min = 60, max = 100))) |>
  add_feature(feature_spec("severity",        "ordinal",
                           list(levels = c("mild", "moderate", "severe")))) |>
  add_feature(feature_spec("hospitalization", "categorical",
                           list(levels = c("yes", "no")))) |>
  add_feature(feature_spec("icu",             "categorical",
                           list(levels = c("yes", "no")))) |>
  add_feature(feature_spec("outcome",         "ordinal",
                           list(levels = c("discharge", "improvement",
                                           "worsening", "death")))) |>

  # Root nodes
  add_dependency(character(0), "age",
    mechanism_library_get("normal")(mean = 58, sd = 18)) |>
  add_dependency(character(0), "sex",
    mechanism_library_get("categorical_marginal")(
      levels = c("M", "F"), probs = c(0.53, 0.47))) |>

  # Comorbidity increases with age
  add_dependency("age", "comorbidity",
    mechanism_library_get("ordered_logit")(
      levels    = c("none", "mild", "severe"),
      coefs     = list(age = 0.055),
      cutpoints = c(2.8, 4.6))) |>

  # Pneumonia more likely with higher comorbidity
  add_dependency("comorbidity",                     "pneumonia",       pneumonia_mech)       |>

  # Vital signs
  add_dependency("pneumonia", "temp",
    mechanism_library_get("group_effect")(list(
      yes = list(mean = 38.9, sd = 0.7),
      no  = list(mean = 36.7, sd = 0.4)))) |>

  add_dependency("pneumonia", "resp_rate",
    mechanism_library_get("group_effect")(list(
      yes = list(mean = 27, sd = 5),
      no  = list(mean = 16, sd = 2)))) |>

  add_dependency(c("pneumonia", "comorbidity"),     "spo2",            spo2_mech)            |>
  add_dependency(c("spo2",      "comorbidity"),     "severity",        severity_mech)        |>
  add_dependency(c("severity",  "age"),             "hospitalization", hospitalization_mech) |>
  add_dependency(c("severity",  "hospitalization"), "icu",             icu_mech)             |>
  add_dependency(c("icu", "severity", "comorbidity", "age"), "outcome", outcome_mech)        |>

  finalize_system()


# ── Baseline scenario: 500 patients ──────────────────────────

set.seed(42)
df_base <- simulate(hospital, n = 500, seed = 42)

cat("\n=== Baseline (n=500) ===\n")
cat("\nPneumonia distribution:\n");  print(table(df_base$pneumonia))
cat("\nSeverity distribution:\n");   print(table(df_base$severity))
cat("\nOutcome distribution:\n");    print(table(df_base$outcome))
cat("\nICU rate:", mean(df_base$icu == "yes"), "\n")
cat("Mean SpO2 (pneumonia):",
    round(mean(df_base$spo2[df_base$pneumonia == "yes"]), 1), "\n")
cat("Mean SpO2 (no pneumonia):",
    round(mean(df_base$spo2[df_base$pneumonia == "no"]),  1), "\n")


# ── Scenario 1: all patients with pneumonia (do_fix) ─────────

r1 <- propagate(hospital,
  interventions = list(do_fix("pneumonia", "yes")),
  n = 500, seed = 42, mode = "partial"
)

cat("\n=== Scenario 1: do(pneumonia = 'yes') ===\n")
cat("\nOutcomes — baseline vs. intervention:\n")
print(rbind(
  baseline     = prop.table(table(r1$baseline$outcome)),
  intervention = prop.table(table(r1$intervened$outcome))
))
cat("\nICU rate — baseline:", round(mean(r1$baseline$icu == "yes"), 3),
    "| intervention:", round(mean(r1$intervened$icu == "yes"), 3), "\n")


# ── Scenario 2: elderly population (+20 years — shift) ───────

r2 <- propagate(hospital,
  interventions = list(shift("age", function(x) x + 20)),
  n = 500, seed = 42, mode = "full"
)

cat("\n=== Scenario 2: population +20 years (shift) ===\n")
print(compare(r2)[c("hospitalization", "icu", "outcome")])


# ── Scenario 3: outbreak with higher comorbidity burden ──────

new_comor <- mechanism_library_get("ordered_logit")(
  levels    = c("none", "mild", "severe"),
  coefs     = list(age = 0.07),
  cutpoints = c(1.8, 3.2)   # lower thresholds = more severe patients
)

r3 <- propagate(hospital,
  interventions = list(mechanism_override("comorbidity", new_comor)),
  n = 500, seed = 42, mode = "full"
)

cat("\n=== Scenario 3: outbreak with higher comorbidity ===\n")
cat("Severe comorbidity — baseline:",
    round(mean(r3$baseline$comorbidity  == "severe"), 3),
    "| intervention:",
    round(mean(r3$intervened$comorbidity == "severe"), 3), "\n")
cat("Death — baseline:",
    round(mean(r3$baseline$outcome  == "death"), 4),
    "| intervention:",
    round(mean(r3$intervened$outcome == "death"), 4), "\n")


# ── Summary: mortality rate by scenario ──────────────────────

cat("\n=== Summary: death rate by scenario ===\n")
cat(sprintf(
  "Baseline:            %.1f%%\nAll pneumonia:       %.1f%%\n+20 years:           %.1f%%\nHigh comorbidity:    %.1f%%\n",
  mean(df_base$outcome         == "death") * 100,
  mean(r1$intervened$outcome   == "death") * 100,
  mean(r2$intervened$outcome   == "death") * 100,
  mean(r3$intervened$outcome   == "death") * 100
))


# ── Export the system (Python interoperability) ───────────────
# Systems with custom mechanisms (register_mechanism) are not serialisable.
# To export, use only mechanism_library_get() factories.
tryCatch(
  {
    export_system(hospital, "hospital_emergency.json")
    cat("\nSystem exported to hospital_emergency.json\n")
  },
  error = function(e) {
    cat("\nNote: export_system is not supported for systems that use",
        "register_mechanism.\n", conditionMessage(e), "\n")
  }
)
