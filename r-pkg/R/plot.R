# Visualization utility -----------------------------------------------------
#
# Secondary utility, not core functionality. See SPEC.md section 1.2.

#' Plot a system's dependency graph
#'
#' Requires the optional `igraph` package
#' (`install.packages("igraph")`).
#'
#' @param system A `system` object.
#' @return Invisibly, the `igraph` graph object plotted.
#' @export
plot_graph <- function(system) {
  if (!requireNamespace("igraph", quietly = TRUE)) {
    stop('plot_graph() requires the igraph package: install.packages("igraph")')
  }

  edges <- system_edges(system)
  nodes <- names(system$features)
  type_colors <- c(continuous = "#6baed6", categorical = "#fd8d3c", ordinal = "#74c476")
  colors <- vapply(nodes, function(n) {
    color <- type_colors[[system$features[[n]]$type]]
    if (is.null(color)) "#cccccc" else color
  }, character(1))

  graph <- igraph::graph_from_data_frame(edges, directed = TRUE, vertices = data.frame(name = nodes))
  igraph::plot.igraph(
    graph,
    vertex.color = colors,
    vertex.label = nodes,
    vertex.size = 30,
    edge.arrow.size = 0.5
  )
  invisible(graph)
}
