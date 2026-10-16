"""Graph engine layer (internal).

Dependency graph representation, acyclicity check, topological sort, and
transitive closure (ancestors/descendants). Used by system.py and
intervention.py. See SPEC.md section 7, layer 2.
"""

from __future__ import annotations

from typing import Iterable, Sequence


def _adjacency(
    nodes: Sequence[str], edges: Iterable[tuple[str, str]]
) -> dict[str, list[str]]:
    adj: dict[str, list[str]] = {node: [] for node in nodes}
    for parent, child in edges:
        adj.setdefault(parent, []).append(child)
    return adj


def topological_sort(nodes: Sequence[str], edges: Iterable[tuple[str, str]]) -> list[str]:
    """Topologically sort a dependency graph (Kahn's algorithm).

    Parameters
    ----------
    nodes:
        All feature names in the system (including isolated ones with no
        edges).
    edges:
        Iterable of ``(from, to)`` pairs, ``from`` being the parent.

    Returns
    -------
    list[str]
        Features in topological order (parents before children).

    Raises
    ------
    ValueError
        If the graph induced by ``edges`` contains a cycle.
    """
    edges = list(edges)
    in_degree = {node: 0 for node in nodes}
    adj = _adjacency(nodes, edges)
    for _parent, child in edges:
        in_degree[child] = in_degree.get(child, 0) + 1

    # Deterministic order: process zero-in-degree nodes in the order they
    # were declared in `nodes`.
    queue = [node for node in nodes if in_degree[node] == 0]
    order: list[str] = []
    while queue:
        node = queue.pop(0)
        order.append(node)
        for child in adj.get(node, []):
            in_degree[child] -= 1
            if in_degree[child] == 0:
                queue.append(child)

    if len(order) != len(nodes):
        remaining = sorted(set(nodes) - set(order))
        raise ValueError(
            "Dependency graph has a cycle involving (at least) these "
            f"features: {remaining}."
        )
    return order


def is_acyclic(nodes: Sequence[str], edges: Iterable[tuple[str, str]]) -> bool:
    """Check whether a dependency graph is acyclic.

    Parameters
    ----------
    nodes:
        All feature names.
    edges:
        Iterable of ``(from, to)`` pairs.
    """
    try:
        topological_sort(nodes, edges)
    except ValueError:
        return False
    return True


def downstream_closure(
    edges: Iterable[tuple[str, str]], targets: Sequence[str]
) -> list[str]:
    """Downstream transitive closure of a set of nodes (including targets).

    Used to compute ``affected_features`` when an intervention targets a
    node. See SPEC.md section 5, step 4.

    Parameters
    ----------
    edges:
        Iterable of ``(from, to)`` pairs.
    targets:
        Feature names.

    Returns
    -------
    list[str]
        Targets plus all descendant feature names, in the order they were
        first discovered by a breadth-first search starting at `targets`.
    """
    adj: dict[str, list[str]] = {}
    for parent, child in edges:
        adj.setdefault(parent, []).append(child)

    visited: list[str] = []
    seen: set[str] = set()
    queue = list(targets)
    for target in targets:
        seen.add(target)
    while queue:
        node = queue.pop(0)
        visited.append(node)
        for child in adj.get(node, []):
            if child not in seen:
                seen.add(child)
                queue.append(child)
    return visited
