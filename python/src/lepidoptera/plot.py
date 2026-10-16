"""Visualization utility.

Secondary utility, not core functionality. See SPEC.md section 1.2.
"""

from __future__ import annotations

from .system import System


def plot_graph(system: System):
    """Plot a system's dependency graph.

    Requires the optional ``graph``/``plot`` extras
    (``pip install "lepidoptera[plot]"``): networkx + matplotlib.

    Parameters
    ----------
    system:
        A :class:`~lepidoptera.system.System`.

    Returns
    -------
    matplotlib.axes.Axes
        The axes the graph was drawn on (also shown via ``plt.show()`` is
        left to the caller).
    """
    try:
        import networkx as nx
    except ImportError as exc:
        raise ImportError(
            'plot_graph() requires networkx: pip install "lepidoptera[graph]"'
        ) from exc
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise ImportError(
            'plot_graph() requires matplotlib: pip install "lepidoptera[plot]"'
        ) from exc

    graph = nx.DiGraph()
    graph.add_nodes_from(system.features.keys())
    graph.add_edges_from(system.edges)

    try:
        pos = nx.nx_agraph.graphviz_layout(graph, prog="dot")
    except Exception:
        pos = nx.spring_layout(graph, seed=0)

    fig, ax = plt.subplots()
    type_colors = {
        "continuous": "#6baed6",
        "categorical": "#fd8d3c",
        "ordinal": "#74c476",
    }
    node_colors = [
        type_colors.get(system.features[name].type, "#cccccc")
        for name in graph.nodes
    ]
    nx.draw_networkx(
        graph,
        pos=pos,
        ax=ax,
        with_labels=True,
        node_color=node_colors,
        node_size=1200,
        font_size=8,
        arrows=True,
    )
    ax.set_axis_off()
    return ax
