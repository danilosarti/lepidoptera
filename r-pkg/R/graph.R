# Graph engine layer ------------------------------------------------------
#
# Dependency graph representation, acyclicity check, topological sort, and
# transitive closure (ancestors/descendants). Internal layer used by
# system.R and intervention.R. See SPEC.md section 7.2.
#
# Edge representation used throughout this package: a data.frame with
# character columns `parent` and `child` (zero rows when there are no
# edges), as returned by `system_edges()` in system.R.

#' Adjacency list from nodes + edges
#' @keywords internal
.adjacency <- function(nodes, edges) {
  adj <- setNames(vector("list", length(nodes)), nodes)
  for (name in nodes) adj[[name]] <- character(0)
  if (nrow(edges) > 0) {
    for (i in seq_len(nrow(edges))) {
      p <- edges$parent[i]
      ch <- edges$child[i]
      adj[[p]] <- c(adj[[p]], ch)
    }
  }
  adj
}

#' Topologically sort a dependency graph
#'
#' Kahn's algorithm. Deterministic: zero-in-degree nodes are processed in
#' the order they appear in `nodes`.
#'
#' @param nodes Character vector of all feature names (including isolated
#'   ones with no edges).
#' @param edges A data.frame with character columns `parent`, `child`.
#' @return A character vector with features in topological order (parents
#'   before children).
#' @keywords internal
topological_sort <- function(nodes, edges) {
  in_degree <- setNames(rep(0L, length(nodes)), nodes)
  if (nrow(edges) > 0) {
    for (ch in edges$child) in_degree[[ch]] <- in_degree[[ch]] + 1L
  }
  adj <- .adjacency(nodes, edges)

  queue <- nodes[in_degree[nodes] == 0L]
  order <- character(0)
  while (length(queue) > 0) {
    node <- queue[1]
    queue <- queue[-1]
    order <- c(order, node)
    for (child in adj[[node]]) {
      in_degree[[child]] <- in_degree[[child]] - 1L
      if (in_degree[[child]] == 0L) queue <- c(queue, child)
    }
  }

  if (length(order) != length(nodes)) {
    remaining <- sort(setdiff(nodes, order))
    stop(sprintf(
      "Dependency graph has a cycle involving (at least) these features: %s.",
      paste(remaining, collapse = ", ")
    ))
  }
  order
}

#' Check whether a dependency graph is acyclic
#'
#' @param nodes Character vector of all feature names.
#' @param edges A data.frame with character columns `parent`, `child`.
#' @return `TRUE` if acyclic, `FALSE` otherwise.
#' @keywords internal
is_acyclic <- function(nodes, edges) {
  tryCatch({
    topological_sort(nodes, edges)
    TRUE
  }, error = function(e) FALSE)
}

#' Downstream transitive closure of a set of nodes
#'
#' Used to compute `affected_features` when an intervention targets a
#' node. See SPEC.md section 5, step 4.
#'
#' @param edges A data.frame with character columns `parent`, `child`.
#' @param targets Character vector of feature names.
#' @return Character vector: targets plus all descendant feature names, in
#'   the order they were first discovered by a breadth-first search
#'   starting at `targets`.
#' @keywords internal
downstream_closure <- function(edges, targets) {
  adj <- list()
  if (nrow(edges) > 0) {
    for (i in seq_len(nrow(edges))) {
      p <- edges$parent[i]
      ch <- edges$child[i]
      adj[[p]] <- c(adj[[p]], ch)
    }
  }

  visited <- character(0)
  seen <- new.env()
  for (t in targets) assign(t, TRUE, envir = seen)
  queue <- targets
  while (length(queue) > 0) {
    node <- queue[1]
    queue <- queue[-1]
    visited <- c(visited, node)
    children <- adj[[node]]
    for (child in children) {
      if (!exists(child, envir = seen, inherits = FALSE)) {
        assign(child, TRUE, envir = seen)
        queue <- c(queue, child)
      }
    }
  }
  visited
}
