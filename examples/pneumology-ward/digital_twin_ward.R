# ============================================================
# digital_twin_ward.R
# Digital Twin — Pneumology Ward
# ============================================================
# Temporal wrapper over the lepidoptera system:
# each hour, patient vitals evolve (Markov) and staff can
# apply clinical interventions before each time step.
#
# Public API:
#   new_ward(hospital_system, n_patients, seed)
#   step_ward(ward, decisions, dt)
#   apply_decision(patient, decision)
#   can_apply(patient, decision)
#   export_ward_json(ward, path)
#   summary.ward_twin(ward)
#
# Usage:
#   source("digital_twin_ward.R")
#   hospital <- .build_hospital()
#   w <- new_ward(hospital, n_patients = 12, seed = 42)
#   w <- step_ward(w, decisions = list(P01 = c("antibiotic","oxygen_therapy")))
#   export_ward_json(w, "ward_state_h01.json")
# ============================================================

suppressPackageStartupMessages(library(lepidoptera))

# ── 1. Rebuild the hospital system (lepidoptera) ─────────────

.build_hospital <- function() {

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

  severity_fn <- function(pv) {
    cs  <- switch(as.character(pv$comorbidity),
                  none   = 0,
                  mild   = 0.6,
                  severe = 1.5,
                  0)
    lat <- (95 - as.numeric(pv$spo2)) * 0.18 + cs + rlogis(1)
    if (lat < 0.9) "mild" else if (lat < 2.3) "moderate" else "severe"
  }
  severity_mech <- register_mechanism(
    "severity_spo2_comorbidity", severity_fn,
    parent_types = c("continuous", "ordinal"), output_type = "ordinal"
  )

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

  outcome_fn <- function(pv) {
    lvls  <- c("discharge", "improvement", "worsening", "death")
    probs <- if (as.character(pv$icu) == "yes") {
      c(0.08, 0.32, 0.38, 0.22)
    } else {
      switch(as.character(pv$severity),
             mild     = c(0.880, 0.100, 0.015, 0.005),
             moderate = c(0.550, 0.350, 0.080, 0.020),
             severe   = c(0.180, 0.420, 0.280, 0.120),
             c(0.550, 0.350, 0.080, 0.020))
    }
    delta    <- (switch(as.character(pv$comorbidity),
                        none   = 0,
                        mild   = 0.03,
                        severe = 0.08,
                        0) +
                 (as.numeric(pv$age) - 50) * 0.001)
    probs[1] <- probs[1] - delta
    probs[4] <- probs[4] + delta
    probs    <- pmax(0.001, probs)
    sample(lvls, 1L, prob = probs / sum(probs))
  }
  outcome_mech <- register_mechanism(
    "outcome_icu_sev_comor_age", outcome_fn,
    parent_types = c("categorical", "ordinal", "ordinal", "continuous"),
    output_type  = "ordinal"
  )

  new_system() |>
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
                             list(min = 8, max = 50))) |>
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
    add_dependency(character(0), "age",
                   mechanism_library_get("normal")(mean = 58, sd = 18)) |>
    add_dependency(character(0), "sex",
                   mechanism_library_get("categorical_marginal")(
                     levels = c("M", "F"), probs = c(0.53, 0.47))) |>
    add_dependency("age", "comorbidity",
                   mechanism_library_get("ordered_logit")(
                     levels    = c("none", "mild", "severe"),
                     coefs     = list(age = 0.055),
                     cutpoints = c(2.8, 4.6))) |>
    add_dependency("comorbidity", "pneumonia",   pneumonia_mech)        |>
    add_dependency("pneumonia",   "temp",
                   mechanism_library_get("group_effect")(list(
                     yes = list(mean = 38.9, sd = 0.7),
                     no  = list(mean = 36.7, sd = 0.4)))) |>
    add_dependency("pneumonia",   "resp_rate",
                   mechanism_library_get("group_effect")(list(
                     yes = list(mean = 27, sd = 5),
                     no  = list(mean = 16, sd = 2)))) |>
    add_dependency(c("pneumonia", "comorbidity"),       "spo2",            spo2_mech)            |>
    add_dependency(c("spo2",      "comorbidity"),       "severity",        severity_mech)        |>
    add_dependency(c("severity",  "age"),               "hospitalization", hospitalization_mech) |>
    add_dependency(c("severity",  "hospitalization"),   "icu",             icu_mech)             |>
    add_dependency(c("icu", "severity", "comorbidity", "age"), "outcome",  outcome_mech)         |>
    finalize_system()
}

# ── 2. Name banks ────────────────────────────────────────────

.NAMES_M <- c("James", "John", "Robert", "Michael", "William",
              "David", "Richard", "Thomas", "Charles", "Daniel",
              "Matthew", "Anthony", "Mark", "Donald", "Steven")
.NAMES_F <- c("Mary", "Patricia", "Jennifer", "Linda", "Barbara",
              "Elizabeth", "Susan", "Jessica", "Sarah", "Karen",
              "Lisa", "Nancy", "Betty", "Margaret", "Sandra")
.SURNAMES <- c("S.", "O.", "L.", "P.", "C.", "R.", "A.", "F.", "M.", "B.",
               "N.", "G.", "T.", "V.", "D.")

# ── 3. Utilities ─────────────────────────────────────────────

# Simplified NEWS score (National Early Warning Score)
.compute_news <- function(p) {
  s <- 0L
  # SpO2
  s <- s + if (p$spo2 >= 96) 0L else if (p$spo2 >= 94) 1L else if (p$spo2 >= 92) 2L else 3L
  # Temperature
  s <- s + if (p$temp <= 36.0) 3L else if (p$temp <= 36.5) 1L else
           if (p$temp <= 37.9) 0L else if (p$temp <= 38.9) 1L else 2L
  # Respiratory rate
  s <- s + if (p$resp_rate < 9) 3L else if (p$resp_rate <= 11) 1L else
           if (p$resp_rate <= 20) 0L else if (p$resp_rate <= 24) 2L else 3L
  # Heart rate
  s <- s + if (p$hr < 41) 3L else if (p$hr <= 50) 1L else
           if (p$hr <= 90) 0L else if (p$hr <= 110) 1L else if (p$hr <= 130) 2L else 3L
  # Systolic BP
  s <- s + if (p$sbp <= 90) 3L else if (p$sbp <= 100) 2L else
           if (p$sbp <= 110) 1L else if (p$sbp <= 219) 0L else 3L
  s
}

.compute_alerts <- function(p) {
  a <- character(0)
  if (p$spo2 < 88)          a <- c(a, sprintf("Critical SpO2: %.0f%%", p$spo2))
  else if (p$spo2 < 92)     a <- c(a, sprintf("Low SpO2: %.0f%%", p$spo2))
  if (p$temp > 39.0)        a <- c(a, sprintf("High fever: %.1f C", p$temp))
  if (p$resp_rate > 25)     a <- c(a, sprintf("Tachypnea: %d brpm", p$resp_rate))
  if (p$hr > 110)           a <- c(a, sprintf("Tachycardia: %d bpm", p$hr))
  if (p$sbp < 90)           a <- c(a, "Hypotension!")
  if (p$severity == "severe" && !p$antibiotic)
                             a <- c(a, "Severe — no antibiotic coverage")
  a
}

# Status colour for the UI (hex)
.patient_color <- function(p) {
  if (p$status == "deceased")   return("#444444")
  if (p$status == "discharged") return("#888888")
  if (p$news_score >= 7)        return("#cc0000")
  if (p$news_score >= 5)        return("#dd6600")
  if (p$news_score >= 3)        return("#ccaa00")
  return("#229944")
}

.patient_badge <- function(p) {
  if (p$status == "deceased")   return("X")
  if (p$status == "discharged") return("o")
  if (p$news_score >= 7)        return("!")
  if (p$news_score >= 5)        return("*")
  if (p$news_score >= 3)        return("-")
  return("+")
}

# ── 4. Initialise a patient from a simulation row ────────────

.row_to_patient <- function(row, id, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  sex   <- as.character(row$sex)
  names <- if (sex == "M") .NAMES_M else .NAMES_F
  name  <- paste(sample(names, 1), sample(.SURNAMES, 1))
  sev   <- as.character(row$severity)

  hr_mu    <- switch(sev, mild = 82L,    moderate = 92L,    severe = 108L, 85L)
  wbc_mu   <- switch(sev, mild = 11000L, moderate = 14000L, severe = 18000L, 11000L)
  crp_mu   <- switch(sev, mild = 20,     moderate = 60,     severe = 120,  20)

  p <- list(
    id              = id,
    name            = name,
    age             = round(as.numeric(row$age)),
    sex             = sex,
    comorbidity     = as.character(row$comorbidity),
    pneumonia       = as.character(row$pneumonia) == "yes",
    severity        = sev,
    status          = if (as.character(row$icu) == "yes") "icu" else "admitted",
    admission_hour  = sample(0:6, 1),
    # Vitals
    spo2            = round(as.numeric(row$spo2), 1),
    temp            = round(as.numeric(row$temp), 1),
    resp_rate       = round(as.numeric(row$resp_rate)),
    hr              = pmax(40L, pmin(160L, round(rnorm(1, hr_mu, 8)))),
    sbp             = pmax(70L,  pmin(210L, round(rnorm(1, 125, 15)))),
    dbp             = pmax(40L,  pmin(120L, round(rnorm(1, 78,  10)))),
    # Labs
    wbc             = pmax(3000L, round(rnorm(1, wbc_mu, wbc_mu * 0.18))),
    crp             = pmax(1,     round(rnorm(1, crp_mu, crp_mu * 0.30), 1)),
    # Treatments (none on admission)
    antibiotic            = FALSE,
    antibiotic_hours      = 0L,
    oxygen_therapy        = FALSE,
    oxygen_therapy_hours  = 0L,
    corticosteroid        = FALSE,
    corticosteroid_hours  = 0L,
    # Derived state
    history    = list(),
    alerts     = character(0),
    news_score = 0L
  )
  p$news_score <- .compute_news(p)
  p$alerts     <- .compute_alerts(p)
  p$history    <- list(list(
    hour      = 0L,
    spo2      = p$spo2,
    temp      = p$temp,
    resp_rate = p$resp_rate,
    hr        = p$hr,
    severity  = p$severity,
    news      = p$news_score
  ))
  p
}

# ── 5. Hourly Markov transition ──────────────────────────────

.transition_patient <- function(p, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)
  if (!p$status %in% c("admitted", "icu")) return(p)

  # ── SpO2 ────────────────────────────────────────────────────
  drift_spo2 <- if (!p$pneumonia) {
    rnorm(1,  0.08, 0.25)
  } else {
    switch(p$severity,
           mild     = rnorm(1, -0.10, 0.40),
           moderate = rnorm(1, -0.25, 0.60),
           severe   = rnorm(1, -0.50, 0.80),
           rnorm(1, -0.25, 0.60))
  }
  if (p$oxygen_therapy) {
    boost      <- if (p$oxygen_therapy_hours <= 2) rnorm(1, 2.5, 0.8) else rnorm(1, 0.4, 0.4)
    drift_spo2 <- drift_spo2 + boost
  }
  if (p$antibiotic && p$antibiotic_hours >= 12) drift_spo2 <- drift_spo2 + rnorm(1, 0.2, 0.1)
  p$spo2 <- round(pmin(99, pmax(55, p$spo2 + drift_spo2)), 1)

  # ── Temperature ─────────────────────────────────────────────
  drift_temp <- rnorm(1, if (p$pneumonia) 0.01 else -0.03, 0.12)
  if (p$antibiotic && p$antibiotic_hours >= 18) drift_temp <- drift_temp - 0.06
  if (p$corticosteroid)                          drift_temp <- drift_temp - 0.08
  p$temp <- round(pmin(41.5, pmax(35.0, p$temp + drift_temp)), 1)

  # ── Respiratory rate ─────────────────────────────────────────
  p$resp_rate <- pmax(8L, pmin(45L, round(
    p$resp_rate + rnorm(1, if (p$oxygen_therapy) -0.2 else 0.05, 0.5))))

  # ── Heart rate ───────────────────────────────────────────────
  hr_drift <- rnorm(1, 0, 1.5)
  if (p$antibiotic && p$antibiotic_hours >= 12) hr_drift <- hr_drift - 0.4
  p$hr <- pmax(40L, pmin(160L, round(p$hr + hr_drift)))

  # ── Severity (hourly Markov, small probabilities) ────────────
  sev       <- p$severity
  p_worsen  <- switch(sev, mild = 0.025, moderate = 0.040, severe = 0.0, 0.0)
  p_improve <- switch(sev, mild = 0.010, moderate = 0.025, severe = 0.02, 0.0)

  if (p$antibiotic && p$antibiotic_hours >= 12) {
    p_worsen  <- p_worsen  * 0.35
    p_improve <- p_improve * 2.0
  }
  if (p$corticosteroid) {
    p_worsen  <- p_worsen  * 0.75
    p_improve <- p_improve * 1.4
  }
  if (p$spo2 < 88)       p_worsen <- p_worsen * 1.6
  if (p$status == "icu") {
    p_worsen  <- p_worsen  * 0.50
    p_improve <- p_improve * 1.50
  }

  u <- runif(1)
  if (u < p_worsen) {
    p$severity <- switch(sev, mild = "moderate", moderate = "severe", "severe")
  } else if (u < p_worsen + p_improve) {
    p$severity <- switch(sev, severe = "moderate", moderate = "mild", "mild")
  }

  # ── Death (severe patients without adequate support) ─────────
  if (p$severity == "severe") {
    p_death <- if (p$status == "icu") 0.003 else 0.007
    if (!p$antibiotic) p_death <- p_death * 1.6
    if (p$spo2 < 80)   p_death <- p_death * 2.0
    if (runif(1) < p_death) p$status <- "deceased"
  }

  # ── Treatment hour counters ──────────────────────────────────
  if (p$antibiotic)      p$antibiotic_hours     <- p$antibiotic_hours     + 1L
  if (p$oxygen_therapy)  p$oxygen_therapy_hours <- p$oxygen_therapy_hours + 1L
  if (p$corticosteroid)  p$corticosteroid_hours <- p$corticosteroid_hours + 1L

  p$news_score <- .compute_news(p)
  p$alerts     <- .compute_alerts(p)
  p
}

# ── 6. Apply a clinical decision to a patient ────────────────

#' Apply a clinical decision to a patient
#'
#' @param p Patient list
#' @param decision One of: "antibiotic" | "oxygen_therapy" | "stop_o2" |
#'   "corticosteroid" | "admit_icu" | "transfer_from_icu" | "discharge"
#' @return Updated patient list
#' @export
apply_decision <- function(p, decision) {
  switch(decision,
    antibiotic         = { p$antibiotic      <- TRUE },
    oxygen_therapy     = { p$oxygen_therapy  <- TRUE },
    stop_o2            = { p$oxygen_therapy  <- FALSE; p$oxygen_therapy_hours <- 0L },
    corticosteroid     = { p$corticosteroid  <- TRUE },
    admit_icu          = { p$status <- "icu" },
    transfer_from_icu  = {
      if (p$severity != "severe") p$status <- "admitted"
    },
    discharge = {
      if (p$severity == "mild" && p$spo2 >= 94 && p$temp <= 37.8)
        p$status <- "discharged"
    }
  )
  p
}

#' Check whether a decision is applicable to the current patient state
#' @export
can_apply <- function(p, decision) {
  if (!p$status %in% c("admitted", "icu")) return(FALSE)
  switch(decision,
    antibiotic        = !p$antibiotic,
    oxygen_therapy    = !p$oxygen_therapy,
    stop_o2           = p$oxygen_therapy,
    corticosteroid    = !p$corticosteroid,
    admit_icu         = p$status == "admitted",
    transfer_from_icu = p$status == "icu" && p$severity != "severe",
    discharge         = p$severity == "mild" && p$spo2 >= 94 && p$temp <= 37.8,
    FALSE
  )
}

# ── 7. new_ward ──────────────────────────────────────────────

#' Create a new ward digital twin
#'
#' @param hospital_system Finalised lepidoptera system (from .build_hospital()).
#' @param n_patients Number of patients to generate (max 15).
#' @param seed Reproducibility seed.
#' @return A `ward_twin` object.
#' @export
new_ward <- function(hospital_system, n_patients = 12L, seed = 42L) {
  n_patients <- min(15L, max(1L, as.integer(n_patients)))
  df <- simulate(hospital_system, n = n_patients, seed = seed)

  patients <- lapply(seq_len(n_patients), function(i) {
    .row_to_patient(df[i, , drop = FALSE],
                    id   = sprintf("P%02d", i),
                    seed = seed + i * 97L)
  })

  n_icu <- sum(sapply(patients, function(p) p$status == "icu"))

  structure(
    list(
      hour     = 0L,
      patients = patients,
      resources = list(
        beds_total      = 15L,
        beds_occupied   = n_patients,
        icu_beds        = 5L,
        icu_beds_in_use = n_icu,
        o2_total        = 8L,
        o2_in_use       = 0L,
        antibiotics     = TRUE
      ),
      log   = character(0),
      score = list(discharges = 0L, deaths = 0L),
      seed  = seed
    ),
    class = "ward_twin"
  )
}

# ── 8. step_ward ────────────────────────────────────────────

#' Advance the digital twin by `dt` hours
#'
#' @param ward A `ward_twin` object.
#' @param decisions Named list keyed by patient id; each element is a
#'   character vector of actions:
#'   "antibiotic" | "oxygen_therapy" | "stop_o2" | "corticosteroid" |
#'   "admit_icu" | "transfer_from_icu" | "discharge"
#' @param dt Number of hours to advance (default 1).
#' @return Updated `ward_twin`.
#' @export
step_ward <- function(ward, decisions = list(), dt = 1L) {
  stopifnot(inherits(ward, "ward_twin"))
  dt <- as.integer(dt)

  idx_by_id <- setNames(
    seq_along(ward$patients),
    sapply(ward$patients, `[[`, "id")
  )

  for (h in seq_len(dt)) {
    hour_h <- ward$hour + h

    # Apply decisions (first hour of the step only)
    if (h == 1L) {
      for (pid in names(decisions)) {
        i <- idx_by_id[[pid]]
        if (is.null(i)) next
        p         <- ward$patients[[i]]
        prev_stat <- p$status
        if (!p$status %in% c("admitted", "icu")) next
        for (dec in decisions[[pid]]) {
          p <- apply_decision(p, dec)
          ward$log <- c(ward$log,
            sprintf("[H%03d] %s (%s): %s", hour_h, p$name, pid, dec))
        }
        if (p$status == "discharged" && prev_stat != "discharged") {
          ward$score$discharges <- ward$score$discharges + 1L
          ward$log <- c(ward$log,
            sprintf("[H%03d] DISCHARGE: %s (%s)", hour_h, p$name, pid))
        }
        ward$patients[[i]] <- p
      }
    }

    # Transition each active patient
    for (i in seq_along(ward$patients)) {
      p         <- ward$patients[[i]]
      prev_sev  <- p$severity
      prev_stat <- p$status

      p <- .transition_patient(p, seed = ward$seed + hour_h * 1000L + i * 7L)

      # Append vitals snapshot to history
      p$history <- c(p$history, list(list(
        hour      = hour_h,
        spo2      = p$spo2,
        temp      = p$temp,
        resp_rate = p$resp_rate,
        hr        = p$hr,
        severity  = p$severity,
        news      = p$news_score
      )))

      # Log notable events
      if (p$status == "deceased" && prev_stat != "deceased") {
        ward$score$deaths <- ward$score$deaths + 1L
        ward$log <- c(ward$log,
          sprintf("[H%03d] DEATH: %s (%s)", hour_h, p$name, p$id))
      }
      if (p$severity != prev_sev) {
        ward$log <- c(ward$log,
          sprintf("[H%03d] %s (%s): severity %s -> %s",
                  hour_h, p$name, p$id, prev_sev, p$severity))
      }

      ward$patients[[i]] <- p
    }
    ward$hour <- hour_h
  }

  # Update resource counters
  active <- sapply(ward$patients, function(p) p$status %in% c("admitted", "icu"))
  ward$resources$beds_occupied   <- sum(active)
  ward$resources$icu_beds_in_use <- sum(sapply(ward$patients, function(p) p$status == "icu"))
  ward$resources$o2_in_use       <- sum(sapply(ward$patients, function(p)
    p$oxygen_therapy && p$status %in% c("admitted", "icu")))

  ward
}

# ── 9. export_ward_json ─────────────────────────────────────

#' Export the ward state as JSON
#'
#' The resulting JSON can be consumed by any frontend
#' (React, Unity, Godot, …) to render the ward state.
#'
#' @param ward A `ward_twin` object.
#' @param path File path. If NULL, returns the JSON string.
#' @return JSON string (invisible when `path` is provided).
#' @export
export_ward_json <- function(ward, path = NULL) {
  h24   <- ward$hour %% 24L
  shift <- if (h24 < 8L) "night" else if (h24 < 16L) "morning" else "afternoon_evening"

  state <- list(
    hour      = ward$hour,
    shift     = shift,
    resources = ward$resources,
    score     = ward$score,
    patients  = lapply(ward$patients, function(p) {
      list(
        id          = p$id,
        name        = p$name,
        age         = p$age,
        sex         = p$sex,
        comorbidity = p$comorbidity,
        pneumonia   = p$pneumonia,
        status      = p$status,
        severity    = p$severity,
        badge       = .patient_badge(p),
        color_hex   = .patient_color(p),
        news_score  = p$news_score,
        vitals = list(
          spo2      = round(p$spo2, 1),
          temp      = p$temp,
          resp_rate = p$resp_rate,
          hr        = p$hr,
          bp        = paste0(p$sbp, "/", p$dbp)
        ),
        labs = list(wbc = p$wbc, crp = p$crp),
        treatments = list(
          antibiotic            = p$antibiotic,
          antibiotic_hours      = p$antibiotic_hours,
          oxygen_therapy        = p$oxygen_therapy,
          oxygen_therapy_hours  = p$oxygen_therapy_hours,
          corticosteroid        = p$corticosteroid,
          corticosteroid_hours  = p$corticosteroid_hours
        ),
        alerts  = as.list(p$alerts),
        history = lapply(p$history, identity)
      )
    }),
    recent_log = as.list(tail(ward$log, 30))
  )

  json <- jsonlite::toJSON(state, auto_unbox = TRUE, pretty = TRUE)
  if (!is.null(path)) {
    writeLines(json, path)
    message(sprintf("Ward state H%03d exported to: %s", ward$hour, path))
    invisible(json)
  } else {
    json
  }
}

# ── 10. summary / print ─────────────────────────────────────

#' @export
summary.ward_twin <- function(object, ...) {
  w       <- object
  active  <- sum(sapply(w$patients, function(p) p$status %in% c("admitted", "icu")))
  severe  <- sum(sapply(w$patients, function(p)
    p$severity == "severe" && p$status %in% c("admitted", "icu")))
  n_alert <- sum(sapply(w$patients, function(p) length(p$alerts) > 0))
  shift   <- if (w$hour %% 24 < 8) "night" else if (w$hour %% 24 < 16) "morning" else "afternoon"

  cat(sprintf(
    "\n=== Ward Twin | Hour %d | Shift: %s ===\n  Active: %d  Severe: %d  Alerts: %d\n  ICU: %d/%d  O2: %d/%d  Deaths: %d  Discharges: %d\n",
    w$hour, shift,
    active, severe, n_alert,
    w$resources$icu_beds_in_use, w$resources$icu_beds,
    w$resources$o2_in_use,       w$resources$o2_total,
    w$score$deaths, w$score$discharges
  ))
  if (length(w$log) > 0) {
    cat("  Recent events:\n")
    for (l in tail(w$log, 4)) cat("   ", l, "\n")
  }
  invisible(w)
}

#' @export
print.ward_twin <- function(x, ...) summary.ward_twin(x, ...)
