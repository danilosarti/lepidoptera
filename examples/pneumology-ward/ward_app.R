# ============================================================
# ward_app.R  —  Pneumology Ward Digital Twin (Shiny)
# Built on top of the lepidoptera engine.
# ============================================================
# Prerequisites:
#   install.packages(c("shiny", "jsonlite"))
#   devtools::install("~/lepidoptera/lepidoptera/r-pkg")   # install engine
#   setwd("~/lepidoptera/lepidoptera/examples/pneumology-ward")
# Run:
#   shiny::runApp("ward_app.R")
# ============================================================

library(shiny)

source("digital_twin_ward.R")

message("Building hospital system (lepidoptera)...")
HOSPITAL <- .build_hospital()
message("Ready.")

# ── Dark-theme CSS ────────────────────────────────────────────
CSS <- "
body { background:#111827; color:#e5e7eb; font-family:'Segoe UI',sans-serif; margin:0; }
.navbar { background:#1f2937 !important; border-bottom:1px solid #374151; }
.well, .panel { background:#1f2937 !important; border:1px solid #374151 !important; color:#e5e7eb; }
h4,h5,label { color:#f9fafb !important; }
hr { border-color:#374151; }
.btn-primary   { background:#2563eb; border:none; }
.btn-success   { background:#16a34a; border:none; }
.btn-warning   { background:#d97706; border:none; color:#fff; }
.btn-danger    { background:#dc2626; border:none; }
.btn-default, .btn-secondary {
  background:#374151; color:#e5e7eb; border:1px solid #4b5563; }
.btn { border-radius:6px; margin-bottom:4px; }
.patient-row {
  padding:6px 10px; margin:3px 0; border-radius:6px; cursor:pointer;
  border-left:5px solid #6b7280; background:#111827;
  transition:background .15s;
}
.patient-row:hover { background:#1f2937; }
.patient-row.selected { background:#1e3a5f !important; border-left-color:#3b82f6 !important; }
.vital-box {
  display:inline-block; background:#1f2937; border:1px solid #374151;
  border-radius:8px; padding:8px 12px; margin:4px 3px; text-align:center; min-width:85px;
}
.vital-val { font-size:1.5em; font-weight:700; }
.vital-lbl { font-size:0.72em; color:#9ca3af; margin-top:2px; }
.alert-chip {
  background:#450a0a; border:1px solid #991b1b; color:#fca5a5;
  border-radius:5px; padding:4px 8px; margin:3px 0; font-size:.82em;
  display:block;
}
.treat-on  { color:#4ade80; font-weight:600; }
.treat-off { color:#6b7280; }
.news-badge {
  display:inline-block; border-radius:12px; padding:1px 9px;
  font-weight:700; font-size:.8em; color:#000;
}
.log-line {
  font-size:.78em; padding:3px 0; border-bottom:1px solid #1f2937;
}
.score-num { font-size:1.8em; font-weight:700; }
"

# ── UI helpers ───────────────────────────────────────────────

sev_color <- function(s) switch(s,
  mild     = "#4ade80",
  moderate = "#fbbf24",
  severe   = "#f87171",
  "#9ca3af")

news_bg <- function(n) {
  if (n >= 7) "#dc2626" else if (n >= 5) "#ea580c" else
  if (n >= 3) "#ca8a04" else "#15803d"
}

status_icon <- function(p) {
  if (p$status == "deceased")   return("✖")
  if (p$status == "discharged") return("✔")
  if (p$news_score >= 7)        return("!!")
  if (p$news_score >= 5)        return("!")
  if (p$news_score >= 3)        return("~")
  return("ok")
}

vital_box <- function(val, lbl, color = "#60a5fa") {
  div(class = "vital-box",
    div(val, class = "vital-val", style = paste0("color:", color, ";")),
    div(lbl, class = "vital-lbl")
  )
}

# ── UI ────────────────────────────────────────────────────────
ui <- fluidPage(
  tags$head(tags$style(HTML(CSS))),

  # Header
  div(style = "background:#1f2937;padding:10px 20px;margin-bottom:12px;border-bottom:1px solid #374151;",
    fluidRow(
      column(5, h3("🏥 Pneumology Ward", style = "margin:0;color:#60a5fa;")),
      column(4, uiOutput("header_time")),
      column(3, uiOutput("header_score"))
    )
  ),

  fluidRow(

    # ── Column 1: patient list + resources ─────────────────
    column(3,
      wellPanel(style = "padding:10px;",
        div(style = "display:flex;justify-content:space-between;align-items:center;",
          h5("Patients", style = "margin:0;"),
          actionButton("reset_btn", "↺ New ward", class = "btn-default btn-sm")
        ),
        hr(),
        uiOutput("patient_list_ui")
      ),
      wellPanel(style = "padding:10px;",
        h5("Ward Resources"),
        uiOutput("resources_ui")
      )
    ),

    # ── Column 2: patient detail + charts ──────────────────
    column(5,
      uiOutput("patient_detail_ui"),
      br(),
      plotOutput("vitals_plot", height = "190px")
    ),

    # ── Column 3: decisions + time controls ─────────────────
    column(4,
      wellPanel(style = "padding:10px;",
        h5("⚕ Decisions — selected patient"),
        uiOutput("decisions_ui")
      ),
      wellPanel(style = "padding:10px;",
        h5("⏩ Advance Time"),
        fluidRow(
          column(4, actionButton("step1",  "+1 h",  class = "btn-primary btn-block")),
          column(4, actionButton("step8",  "+8 h",  class = "btn-default btn-block")),
          column(4, actionButton("step24", "+24 h", class = "btn-default btn-block"))
        ),
        br(),
        downloadButton("dl_json", "💾 Export JSON", class = "btn-default btn-block")
      ),
      wellPanel(style = "padding:10px;max-height:240px;overflow-y:auto;",
        h5("📋 Event Log"),
        uiOutput("log_ui")
      )
    )
  )
)

# ── Server ────────────────────────────────────────────────────
server <- function(input, output, session) {

  rv <- reactiveValues(
    ward    = NULL,
    sel     = "P01",   # selected patient id
    pending = list()   # pending decisions per patient id
  )

  # Initialise
  observe({
    if (is.null(rv$ward)) {
      rv$ward <- new_ward(HOSPITAL, n_patients = 12L, seed = 42L)
      rv$sel  <- rv$ward$patients[[1]]$id
    }
  })

  # Reset with a random seed
  observeEvent(input$reset_btn, {
    rv$ward    <- new_ward(HOSPITAL, n_patients = 12L, seed = sample.int(1e5, 1))
    rv$sel     <- rv$ward$patients[[1]]$id
    rv$pending <- list()
  })

  # Select patient via list click
  observeEvent(input$sel_patient, {
    rv$sel <- input$sel_patient
  })

  # Currently selected patient
  sel_p <- reactive({
    req(rv$ward)
    idx <- which(sapply(rv$ward$patients, `[[`, "id") == rv$sel)
    if (length(idx) == 0) return(rv$ward$patients[[1]])
    rv$ward$patients[[idx]]
  })

  # ── Header ──────────────────────────────────────────────────
  output$header_time <- renderUI({
    req(rv$ward)
    h24   <- rv$ward$hour %% 24L
    shift <- if (h24 < 8) "🌙 Night" else if (h24 < 16) "☀️ Morning" else "🌆 Afternoon/Evening"
    div(style = "text-align:center;",
      div(sprintf("H%03d  —  %02d:00", rv$ward$hour, h24),
          style = "font-size:1.4em;font-weight:700;"),
      div(shift, style = "color:#9ca3af;font-size:.85em;")
    )
  })

  output$header_score <- renderUI({
    req(rv$ward)
    s <- rv$ward$score
    div(style = "text-align:right;",
      span(div(s$discharges, class = "score-num", style = "color:#4ade80;display:inline;"), " DC  "),
      span(div(s$deaths,     class = "score-num", style = "color:#f87171;display:inline;"), " Deaths")
    )
  })

  # ── Patient list ────────────────────────────────────────────
  output$patient_list_ui <- renderUI({
    req(rv$ward)
    tagList(lapply(rv$ward$patients, function(p) {
      is_sel   <- rv$sel == p$id
      brd_col  <- .patient_color(p)
      bg_extra <- if (is_sel) "background:#1e3a5f;" else ""
      div(
        class = paste0("patient-row", if (is_sel) " selected" else ""),
        style = paste0("border-left-color:", brd_col, ";", bg_extra),
        onclick = sprintf(
          "Shiny.setInputValue('sel_patient','%s',{priority:'event'});", p$id),
        span(status_icon(p),
             style = paste0("color:", brd_col, ";font-weight:700;margin-right:6px;")),
        strong(p$name), " · ", p$id,
        br(),
        span(p$severity,
             style = paste0("color:", sev_color(p$severity),
                            ";font-size:.82em;font-weight:600;")),
        span(paste0(" · SpO2 ", round(p$spo2), "%"),
             style = "color:#9ca3af;font-size:.82em;"),
        if (p$status == "icu")        span(" · ICU",        style = "color:#f87171;font-size:.82em;"),
        if (p$status == "discharged") span(" · Discharged", style = "color:#9ca3af;font-size:.82em;"),
        if (p$status == "deceased")   span(" · Deceased",   style = "color:#6b7280;font-size:.82em;")
      )
    }))
  })

  # ── Resources ───────────────────────────────────────────────
  output$resources_ui <- renderUI({
    req(rv$ward)
    r     <- rv$ward$resources
    icu_c <- if (r$icu_beds_in_use >= r$icu_beds) "#f87171" else "#4ade80"
    o2_c  <- if (r$o2_in_use >= r$o2_total)       "#f87171" else "#60a5fa"
    tagList(
      div(sprintf("🛏  Beds:  %d / %d occupied", r$beds_occupied, r$beds_total)),
      div(sprintf("🔴 ICU:   %d / %d", r$icu_beds_in_use, r$icu_beds),
          style = paste0("color:", icu_c, ";")),
      div(sprintf("💨 O₂:    %d / %d in use", r$o2_in_use, r$o2_total),
          style = paste0("color:", o2_c, ";")),
      div(sprintf("💊 Antibiotics: %s",
                  if (r$antibiotics) "✅ available" else "❌ depleted"))
    )
  })

  # ── Patient detail ──────────────────────────────────────────
  output$patient_detail_ui <- renderUI({
    p <- sel_p(); req(p)

    news_color <- news_bg(p$news_score)
    status_lbl <- switch(p$status,
      admitted   = "🛏 Admitted",
      icu        = "🔴 ICU",
      discharged = "✅ Discharged",
      deceased   = "⚫ Deceased",
      p$status)

    wellPanel(style = "padding:12px;",
      fluidRow(
        column(8,
          h4(paste(p$name, "—", p$id), style = "margin-top:0;"),
          div(p$age, "y.o. ·", p$sex, "·",
              span(paste("Comorbidity:", p$comorbidity), style = "color:#9ca3af;"))
        ),
        column(4, style = "text-align:right;",
          div(status_lbl),
          span(paste("NEWS:", p$news_score), class = "news-badge",
               style = paste0("background:", news_color, ";"))
        )
      ),

      div(
        span("Severity: ", style = "color:#9ca3af;"),
        span(p$severity, style = paste0("color:", sev_color(p$severity),
                                        ";font-weight:700;font-size:1.05em;")),
        span("  ·  ", style = "color:#374151;"),
        if (p$pneumonia) span("🫁 Active pneumonia", style = "color:#fb923c;")
        else             span("✅ No pneumonia",      style = "color:#4ade80;")
      ),
      hr(),

      # Vitals
      div(
        vital_box(sprintf("%.0f%%",  p$spo2),     "SpO₂",
                  if (p$spo2 < 88) "#f87171" else if (p$spo2 < 92) "#fb923c" else "#4ade80"),
        vital_box(sprintf("%.1f°C",  p$temp),     "Temp",
                  if (p$temp > 39) "#fb923c" else "#60a5fa"),
        vital_box(sprintf("%d",       p$resp_rate), "RR brpm",
                  if (p$resp_rate > 25) "#fb923c" else "#60a5fa"),
        vital_box(sprintf("%d",       p$hr),        "HR bpm",
                  if (p$hr > 110) "#fb923c" else "#60a5fa"),
        vital_box(sprintf("%d/%d",    p$sbp, p$dbp), "BP mmHg",
                  if (p$sbp < 90) "#f87171" else "#60a5fa")
      ),
      hr(),

      # Labs + treatments
      div(style = "color:#9ca3af;font-size:.83em;",
        sprintf("WBC: %s /µL  ·  CRP: %.1f mg/L",
                format(p$wbc, big.mark = ","), p$crp)
      ),
      br(),
      div(
        span(if (p$antibiotic)
               sprintf("💊 Antibiotic (%d h)", p$antibiotic_hours)
             else "💊 No antibiotic",
             class = if (p$antibiotic) "treat-on" else "treat-off"),
        "  ",
        span(if (p$oxygen_therapy)
               sprintf("💨 O₂ (%d h)", p$oxygen_therapy_hours)
             else "💨 No O₂",
             class = if (p$oxygen_therapy) "treat-on" else "treat-off"),
        "  ",
        span(if (p$corticosteroid)
               sprintf("💉 Corticosteroid (%d h)", p$corticosteroid_hours)
             else "💉 No corticosteroid",
             class = if (p$corticosteroid) "treat-on" else "treat-off")
      ),

      # Alerts
      if (length(p$alerts) > 0) tagList(
        hr(),
        lapply(p$alerts, function(a) span(a, class = "alert-chip"))
      )
    )
  })

  # ── Vitals chart ────────────────────────────────────────────
  output$vitals_plot <- renderPlot({
    p <- sel_p(); req(p)
    if (length(p$history) < 2) { plot.new(); return(invisible()) }

    hist_df <- do.call(rbind, lapply(p$history, as.data.frame))
    hours   <- hist_df$hour
    n_h     <- nrow(hist_df)
    x_lim   <- range(hours)

    par(mfrow = c(1, 3), bg = "#111827", fg = "#e5e7eb",
        col.axis = "#9ca3af", col.lab = "#9ca3af", col.main = "#60a5fa",
        mar = c(3, 3, 2, 1), oma = c(0, 0, 0, 0))

    # SpO2
    plot(hours, hist_df$spo2, type = "l", col = "#60a5fa", lwd = 2,
         ylim = c(max(60, min(hist_df$spo2) - 3), 100),
         main = "SpO₂ (%)", xlab = "hour", ylab = "", xlim = x_lim)
    abline(h = 92, col = "#fb923c", lty = 2, lwd = 1)
    abline(h = 88, col = "#f87171", lty = 2, lwd = 1)
    if (n_h > 1) points(hours[n_h], hist_df$spo2[n_h], pch = 19, col = "#60a5fa", cex = 1.3)

    # Temperature
    plot(hours, hist_df$temp, type = "l", col = "#fb923c", lwd = 2,
         ylim = c(max(35, min(hist_df$temp) - 0.5), min(42, max(hist_df$temp) + 0.5)),
         main = "Temperature (°C)", xlab = "hour", ylab = "", xlim = x_lim)
    abline(h = 37.5, col = "#fbbf24", lty = 2, lwd = 1)
    abline(h = 39.0, col = "#f87171", lty = 2, lwd = 1)
    if (n_h > 1) points(hours[n_h], hist_df$temp[n_h], pch = 19, col = "#fb923c", cex = 1.3)

    # Respiratory rate
    plot(hours, hist_df$resp_rate, type = "l", col = "#a3e635", lwd = 2,
         ylim = c(max(8, min(hist_df$resp_rate) - 2), min(45, max(hist_df$resp_rate) + 2)),
         main = "RR (brpm)", xlab = "hour", ylab = "", xlim = x_lim)
    abline(h = 20, col = "#fbbf24", lty = 2, lwd = 1)
    abline(h = 25, col = "#f87171", lty = 2, lwd = 1)
    if (n_h > 1) points(hours[n_h], hist_df$resp_rate[n_h], pch = 19, col = "#a3e635", cex = 1.3)

  }, bg = "#111827")

  # ── Decision panel ──────────────────────────────────────────
  output$decisions_ui <- renderUI({
    p <- sel_p(); req(p)
    pid <- p$id

    if (p$status == "discharged")
      return(div("✅ Patient has been discharged.", style = "color:#4ade80;padding:8px;"))
    if (p$status == "deceased")
      return(div("⚫ Patient is deceased.",         style = "color:#6b7280;padding:8px;"))

    pend <- rv$pending[[pid]]

    tagList(
      div(style = "color:#9ca3af;font-size:.82em;margin-bottom:8px;",
          "Decisions are applied on the next time advance (▶)."),

      # Antibiotic
      if (!p$antibiotic)
        actionButton("dec_ab",  "💊 Start Antibiotic",   class = "btn-success btn-block")
      else
        div("💊 Antibiotic in progress", class = "treat-on"),
      br(),

      # Oxygen
      if (!p$oxygen_therapy)
        actionButton("dec_o2",  "💨 Start O₂ Therapy",   class = "btn-success btn-block")
      else
        fluidRow(
          column(7, div("💨 O₂ active", class = "treat-on", style = "padding-top:6px;")),
          column(5, actionButton("dec_sus_o2", "Stop O₂", class = "btn-warning btn-sm btn-block"))
        ),
      br(),

      # Corticosteroid
      if (!p$corticosteroid)
        actionButton("dec_ct",  "💉 Corticosteroid",     class = "btn-default btn-block")
      else
        div("💉 Corticosteroid in progress", class = "treat-on"),

      hr(),

      # ICU transfer
      if (p$status == "admitted")
        actionButton("dec_icu", "🔴 Transfer to ICU",    class = "btn-danger btn-block")
      else if (can_apply(p, "transfer_from_icu"))
        actionButton("dec_from_icu", "⬆️ Transfer from ICU", class = "btn-default btn-block")
      else
        div("🔴 ICU — maintain (severe)", style = "color:#f87171;font-size:.82em;padding:4px 0;"),

      # Discharge
      if (can_apply(p, "discharge"))
        actionButton("dec_dc",  "✅ Discharge Patient",  class = "btn-primary btn-block"),

      # Pending decisions
      if (!is.null(pend) && length(pend) > 0)
        div(style = "margin-top:8px;color:#fbbf24;font-size:.82em;",
            "Pending: ", paste(pend, collapse = ", "))
    )
  })

  # ── Queue a pending decision ─────────────────────────────────
  add_pending <- function(decision) {
    pid <- rv$sel
    cur <- rv$pending[[pid]]
    if (is.null(cur)) cur <- character(0)
    if (!decision %in% cur) rv$pending[[pid]] <- c(cur, decision)
  }

  observeEvent(input$dec_ab,       { add_pending("antibiotic")        })
  observeEvent(input$dec_o2,       { add_pending("oxygen_therapy")    })
  observeEvent(input$dec_sus_o2,   { add_pending("stop_o2")           })
  observeEvent(input$dec_ct,       { add_pending("corticosteroid")    })
  observeEvent(input$dec_icu,      { add_pending("admit_icu")         })
  observeEvent(input$dec_from_icu, { add_pending("transfer_from_icu") })
  observeEvent(input$dec_dc,       { add_pending("discharge")         })

  # ── Advance time ─────────────────────────────────────────────
  do_step <- function(dt) {
    req(rv$ward)
    rv$ward    <- step_ward(rv$ward, decisions = rv$pending, dt = as.integer(dt))
    rv$pending <- list()
  }

  observeEvent(input$step1,  { do_step(1)  })
  observeEvent(input$step8,  { do_step(8)  })
  observeEvent(input$step24, { do_step(24) })

  # ── Event log ────────────────────────────────────────────────
  output$log_ui <- renderUI({
    req(rv$ward)
    lines <- rev(tail(rv$ward$log, 25))
    if (length(lines) == 0)
      return(div("No events yet.", style = "color:#6b7280;font-size:.82em;"))
    tagList(lapply(lines, function(l) {
      col <- if (grepl("DEATH",     l, ignore.case = TRUE)) "#f87171"
             else if (grepl("severe", l, ignore.case = TRUE)) "#fb923c"
             else "#d1d5db"
      div(l, class = "log-line", style = paste0("color:", col, ";"))
    }))
  })

  # ── JSON download ────────────────────────────────────────────
  output$dl_json <- downloadHandler(
    filename = function() sprintf("ward_h%03d.json", rv$ward$hour),
    content  = function(file) writeLines(export_ward_json(rv$ward), file)
  )
}

shinyApp(ui, server)
