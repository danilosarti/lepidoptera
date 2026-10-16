# I/O / serialization layer ------------------------------------------------
#
# Exporting and importing a System (structure only, no simulated data) in a
# format shared with the Python implementation, to serve as the R/Python
# parity contract. See SPEC.md section 7.7.
#
# Serialized shape:
#   {
#     "features": [{"name", "type", "domain", "metadata"}, ...],
#     "dependencies": [
#       {"child": ..., "parents": [...], "mechanism": {"factory": ..., "kwargs": {...}}},
#       ...
#     ]
#   }
#
# Only mechanisms built from a pre-built factory (i.e. with a non-NULL
# `mechanism$spec`) are serializable -- mechanisms created via
# register_mechanism() carry an arbitrary R closure and have no `spec`, so
# exporting a system that uses one raises a clear error.

.system_to_list <- function(system) {
  unserializable <- Filter(
    function(name) is.null(system$mechanisms[[name]]$spec),
    names(system$mechanisms)
  )
  if (length(unserializable) > 0) {
    stop(sprintf(
      paste(
        "Cannot serialize a system that uses custom (register_mechanism)",
        "mechanisms for these features: %s. Only pre-built",
        "mechanism_library_get() factories are serializable."
      ),
      paste(sort(unserializable), collapse = ", ")
    ))
  }

  features <- lapply(system$features, function(spec) {
    list(name = spec$name, type = spec$type, domain = spec$domain, metadata = spec$metadata)
  })

  dependencies <- lapply(names(system$features), function(child) {
    if (is.null(system$mechanisms[[child]])) return(NULL)
    list(
      child = child,
      parents = as.list(system$parents[[child]]),
      mechanism = system$mechanisms[[child]]$spec
    )
  })
  dependencies <- Filter(Negate(is.null), dependencies)

  list(features = unname(features), dependencies = dependencies)
}

.system_from_list <- function(data) {
  system <- new_system()
  for (feature in data$features) {
    system <- add_feature(system, feature_spec(
      name = feature$name, type = feature$type,
      domain = feature$domain, metadata = feature$metadata
    ))
  }
  for (dependency in data$dependencies) {
    mechanism <- mechanism_from_spec(dependency$mechanism)
    system <- add_dependency(
      system,
      parents = unlist(dependency$parents),
      child = dependency$child,
      mechanism = mechanism
    )
  }
  system
}

#' Export a system to JSON or YAML
#'
#' @param system A `system` object (need not be finalized).
#' @param path Output file path.
#' @param format Character. `"json"` or `"yaml"`.
#' @return Invisibly, `path`.
#' @export
export_system <- function(system, path, format = c("json", "yaml")) {
  format <- match.arg(format)
  data <- .system_to_list(system)
  if (format == "json") {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      stop('export_system(format = "json") requires the jsonlite package.')
    }
    jsonlite::write_json(data, path, auto_unbox = TRUE, pretty = TRUE, null = "null")
  } else {
    if (!requireNamespace("yaml", quietly = TRUE)) {
      stop('export_system(format = "yaml") requires the yaml package.')
    }
    yaml::write_yaml(data, path)
  }
  invisible(path)
}

#' Import a system from JSON or YAML
#'
#' @param path Input file path.
#' @param format Character. `"json"` or `"yaml"`.
#' @return A `system` object. Not yet finalized -- call
#'   [finalize_system()] before simulating.
#' @export
import_system <- function(path, format = c("json", "yaml")) {
  format <- match.arg(format)
  if (format == "json") {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
      stop('import_system(format = "json") requires the jsonlite package.')
    }
    data <- jsonlite::read_json(path, simplifyVector = FALSE)
  } else {
    if (!requireNamespace("yaml", quietly = TRUE)) {
      stop('import_system(format = "yaml") requires the yaml package.')
    }
    data <- yaml::read_yaml(path)
  }
  .system_from_list(data)
}
