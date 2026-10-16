## lepidoptera-paper.R
## Replication script for:
##   Sarti, D.A. (2026). lepidoptera: A Domain-Agnostic Engine for Causal
##   Simulation with Mixed Variable Types, Vine Copula Dependence, and
##   Counterfactual Propagation. Journal of Statistical Software (submitted).
##
## Run with: source("lepidoptera-paper.R")
## Requires: lepidoptera (>= 0.1.0), rvinecopulib (>= 0.6.3), ranger
##
## Note: some examples use pre-fitted objects (fit_lm, rf, ward_sys, trial_data)
##       that depend on earlier code in the same session. Run top-to-bottom.

library(lepidoptera)

library(lepidoptera)

## -- Feature specifications -----------------------------------------
income_spec  <- feature_spec("income",   "continuous",  list(min=0, max=Inf))
smoke_spec   <- feature_spec("smoking",  "categorical",
                             list(levels = c("never","former","current")))
diet_spec    <- feature_spec("diet_score", "continuous", list(min=0, max=100))
cvd_spec     <- feature_spec("cvd_risk", "categorical",
                             list(levels = c("low","high")))

## -- Mechanisms -----------------------------------------------------
## Root: income ~ Normal(50, 15)
mech_income <- mechanism_library_get("normal")(mean = 50, sd = 15)

## Continuous→Categorical: smoking | income
mech_smoke  <- multinomial_logit(
  levels     = c("never","former","current"),
  coefs      = list(former  = list(income = -0.03),
                    current = list(income = -0.05)),
  intercepts = list(former  = 0.2, current = -0.8)
)

## Continuous→Continuous: diet_score | income
mech_diet   <- linear_gaussian(
  coefs     = list(income = 0.6),
  intercept = 20, sd = 8
)

## Mixed→Categorical: cvd_risk | diet_score + smoking
mech_cvd    <- multinomial_logit(
  levels     = c("low","high"),
  coefs      = list(high = list(diet_score = -0.04,
                                smoking_former  = 0.5,
                                smoking_current = 1.2)),
  intercepts = list(high = -2.0)
)

## -- Assemble and finalise -----------------------------------------
mediation_sys <- new_system()                                         |>
  add_feature(income_spec)  |> add_feature(smoke_spec)               |>
  add_feature(diet_spec)    |> add_feature(cvd_spec)                  |>
  add_dependency(character(0),           "income",     mech_income)  |>
  add_dependency("income",               "smoking",    mech_smoke)   |>
  add_dependency("income",               "diet_score", mech_diet)    |>
  add_dependency(c("diet_score","smoking"), "cvd_risk", mech_cvd)    |>
  finalize_system()

## ----------------------------------------------------------------------

pop <- simulate(mediation_sys, n = 2000, seed = 42)
head(pop, 3)
summary(pop$diet_score)
table(pop$smoking, pop$cvd_risk)

## ----------------------------------------------------------------------

## Simulate baseline
baseline <- simulate(mediation_sys, n = 1000, seed = 42)

## Counterfactual: what if income were fixed at 80 for everyone?
cf_result <- propagate(
  mediation_sys,
  interventions = list(do_fix("income", 80)),
  n    = 1000, seed = 42,
  mode = "partial"           # same individuals, different income
)

## Among those currently at high CVD risk: what would happen?
high_risk  <- cf_result$baseline$cvd_risk == "high"
cf_risk    <- cf_result$intervened$cvd_risk[high_risk]

cat(sprintf(
  "Among %d high-risk individuals:\n  still high: %d (%.0f%%)\n  would be low: %d (%.0f%%)\n",
  sum(high_risk),
  sum(cf_risk == "high"),  mean(cf_risk == "high")  * 100,
  sum(cf_risk == "low"),   mean(cf_risk == "low")   * 100
))

## ----------------------------------------------------------------------

## Observed patient data: age and comorbidity burden are negatively correlated
set.seed(1)
obs <- data.frame(
  age         = rnorm(400, 62, 10),
  comorbidity = rnorm(400, 4,  1.5)
)
obs$comorbidity <- obs$comorbidity - 0.35 * (obs$age - 62) / 10 +
                  rnorm(400, 0, 0.8)

## Fit copula mechanism: learns dependence structure automatically
mech_comorbidity <- copula_mechanism(
  variables = c("comorbidity", "age"),  # child first, parents after
  family    = "auto",                    # AIC-selected family per pair
  fit_data  = obs
)

## Inspect what family was selected
mech_comorbidity$model$family
# [1] "gaussian"   (or "frank", "t", … depending on data)

## Simulate and verify the recovered correlation
mech_age <- mechanism_library_get("normal")(mean = 62, sd = 10)
sys_cop  <- new_system()                                            |>
  add_feature(feature_spec("age",         "continuous", list(min=18,max=120))) |>
  add_feature(feature_spec("comorbidity", "continuous", list(min=0, max=Inf))) |>
  add_dependency(character(0), "age",         mech_age)            |>
  add_dependency("age",        "comorbidity", mech_comorbidity)    |>
  finalize_system()

sim_cop <- simulate(sys_cop, n = 800, seed = 99)
cat(sprintf("Observed rho_S = %.2f   Simulated rho_S = %.2f\n",
  cor(obs$age, obs$comorbidity,     method = "spearman"),
  cor(sim_cop$age, sim_cop$comorbidity, method = "spearman")))

## ----------------------------------------------------------------------

## Fit mechanism from data: OLS + residual noise for continuous child
mech_diet_learned <- learned_mechanism(
  parents  = "income",
  child    = "diet_score",
  fit_data = obs_data         # data.frame with both columns
)

## ----------------------------------------------------------------------

## Pre-fit a random forest on clinical trial data
rf <- ranger::ranger(
  response ~ age + dose + biomarker,
  data        = trial_data,
  probability = TRUE,
  num.trees   = 500
)

## Wrap it as a generative mechanism
mech_response <- model_mechanism(
  predict_fn   = function(pv) {
    nd   <- data.frame(age      = as.numeric(pv$age),
                       dose     = as.numeric(pv$dose),
                       biomarker = as.numeric(pv$biomarker))
    pred <- predict(rf, nd)$predictions     # 1 x K probability matrix
    sample(c("no_response","response"), 1, prob = pred[1,])
  },
  parents      = c("age","dose","biomarker"),
  parent_types = c("continuous","continuous","continuous"),
  output_type  = "categorical",
  levels       = c("no_response","response")
)

## ----------------------------------------------------------------------

## Use an LLM to generate free-text clinical notes
mech_note <- llm_mechanism(
  prompt_template = "Patient: {age} yo, {smoking} smoker, CVD risk {cvd_risk}.
                     Write a one-sentence discharge note.",
  model           = function(prompt) httr2_call_llm(prompt),  # user's client
  parents         = c("age","smoking","cvd_risk"),
  parent_types    = c("continuous","categorical","categorical"),
  output_type     = "categorical",
  levels          = NULL,   # free text; user parses downstream
  parser          = identity
)

## ----------------------------------------------------------------------

trial_sys <- new_system()  |>
  add_feature(feature_spec("age",        "continuous",
                            list(min=18, max=90)))  |>
  add_feature(feature_spec("ecog",       "ordinal",
                            list(levels=c("0","1","2","3","4"))))  |>
  add_feature(feature_spec("treatment",  "categorical",
                            list(levels=c("control","active"))))   |>
  add_feature(feature_spec("response",   "categorical",
                            list(levels=c("no","yes"))))           |>
  add_dependency(character(0),       "age",       mech_age_root)  |>
  add_dependency("age",              "ecog",      mech_ecog)      |>
  add_dependency(c("age","ecog"),    "treatment", mech_treat)     |>
  add_dependency(c("treatment","ecog","age"), "response", mech_resp) |>
  finalize_system()

## Observational run (confounded)
obs_pop  <- simulate(trial_sys, n = 5000, seed = 1)

## Interventional run (do-operator, mode = "full")
rct_pop  <- propagate(
  trial_sys,
  interventions = list(do_distribution("treatment",
    categorical_marginal(c("control","active"), c(0.5,0.5)))),
  n = 5000, seed = 1, mode = "full"
)

## Naive observational OR vs. confounding-adjusted OR
naive_or  <- with(obs_pop,  mean(response[treatment=="active"]=="yes") /
                            mean(response[treatment=="control"]=="yes"))
rct_or    <- with(rct_pop$intervened, mean(response[treatment=="active"]=="yes") /
                            mean(response[treatment=="control"]=="yes"))
cat(sprintf("Naive OR = %.2f   Adjusted OR = %.2f\n", naive_or, rct_or))

## ----------------------------------------------------------------------

## Upgrade triage priority by one level for all patients
upgrade_fn <- function(x) {
  map <- c(P3="P2", P2="P1", P1="P1")  # P1 is ceiling
  map[x]
}

ward_cf <- propagate(
  ward_sys,
  interventions = list(shift("triage", upgrade_fn)),
  n    = 2000, seed = 7,
  mode = "partial"    # same patient, different triage
)

## Among home-discharged: where would they have gone?
home_pts  <- ward_cf$baseline$discharge == "home"
cf_dest   <- ward_cf$intervened$discharge[home_pts]
cat(sprintf("Of %d home-discharged patients, if triaged one level higher:\n", sum(home_pts)))
print(prop.table(table(cf_dest)) * 100)

## ----------------------------------------------------------------------

n <- 5000; seed <- 42

## Baseline: income = 30
r_low   <- propagate(mediation_sys,
             list(do_fix("income", 30)), n=n, seed=seed, mode="full")

## Total effect: income = 80
r_high  <- propagate(mediation_sys,
             list(do_fix("income", 80)), n=n, seed=seed, mode="full")

## NDE: income = 80, but mediators set to values under income = 30
## Step 1: simulate mediators under income = 30
med_low <- r_low$intervened[, c("smoking","diet_score")]

## Step 2: fix income = 80 AND fix mediators at their low-income values
r_nde   <- propagate(mediation_sys, list(
              do_fix("income",     80),
              do_fix("smoking",    med_low$smoking),    # vector-valued do-fix
              do_fix("diet_score", med_low$diet_score)),
              n=n, seed=seed, mode="full")

## Proportions at high CVD risk
p_low  <- mean(r_low$intervened$cvd_risk  == "high")
p_high <- mean(r_high$intervened$cvd_risk == "high")
p_nde  <- mean(r_nde$intervened$cvd_risk  == "high")

te  <- p_high - p_low
nde <- p_nde  - p_low
nie <- te - nde
cat(sprintf("TE = %.3f  NDE = %.3f  NIE = %.3f  Prop mediated = %.1f%%\n",
            te, nde, nie, nie/te*100))