"""Intervention engine layer.

Constructing interventions and propagating their effects through the
dependency structure. See SPEC.md sections 3.6 and 5, step 4.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Literal, Optional, Sequence

import pandas as pd

from .graph import downstream_closure
from .mechanism import Mechanism
from .simulate import _to_typed_frame, _unit_rngs, simulate
from .system import System

InterventionKind = Literal["do_fix", "do_distribution", "shift", "mechanism_override"]


@dataclass(frozen=True)
class Intervention:
    """A modification applied to one or more features. See SPEC.md
    section 3.6. Construct via :func:`do_fix`, :func:`do_distribution`,
    :func:`shift`, or :func:`mechanism_override` rather than directly.
    """

    target: str | Sequence[str]
    kind: InterventionKind
    params: Any

    def target_list(self) -> list[str]:
        return [self.target] if isinstance(self.target, str) else list(self.target)


def do_fix(target: str | Sequence[str], value: Any) -> Intervention:
    """Intervention: fix a feature to a constant value.

    Classic do-operator: disconnects ``target`` from its parents and sets
    it to ``value`` for every unit.

    Parameters
    ----------
    target:
        Feature name (or sequence of names).
    value:
        The fixed value (or sequence of values, one per target).
    """
    return Intervention(target=target, kind="do_fix", params={"value": value})


def do_distribution(target: str, distribution: Mechanism) -> Intervention:
    """Intervention: replace a feature's generative distribution.

    v1 scope: `distribution` must be a *marginal* mechanism (no parents)
    — the feature is resampled from `distribution` independently of its
    original parents. Use :func:`mechanism_override` for a conditional
    replacement.

    Parameters
    ----------
    target:
        Feature name.
    distribution:
        A marginal :class:`~lepidoptera.mechanism.Mechanism` (e.g. from
        ``mechanism_library.get("normal")(mean=..., sd=...)``).
    """
    return Intervention(
        target=target, kind="do_distribution", params={"distribution": distribution}
    )


def shift(target: str, fn: Callable[[Any], Any]) -> Intervention:
    """Intervention: shift the value a feature would otherwise take.

    Preserves the dependency on parents; applies ``fn`` to the value that
    the original mechanism would have produced.

    Parameters
    ----------
    target:
        Feature name.
    fn:
        Function applied to the originally generated value.
    """
    return Intervention(target=target, kind="shift", params={"fn": fn})


def mechanism_override(target: str, mechanism: Mechanism) -> Intervention:
    """Intervention: override a feature's mechanism entirely.

    The replacement `mechanism` must declare the same number and types of
    parents that `target` was originally given in ``add_dependency`` (the
    parent set itself is not changed by this intervention) — mismatches
    surface as a validation error when the derived system is finalized.

    Parameters
    ----------
    target:
        Feature name.
    mechanism:
        A :class:`~lepidoptera.mechanism.Mechanism` replacing the current
        one.
    """
    return Intervention(
        target=target, kind="mechanism_override", params={"mechanism": mechanism}
    )


def _make_constant_mechanism(output_type: str, value: Any) -> Mechanism:
    def fn(parent_values, rng):
        return value

    return Mechanism(name="do_fix", fn=fn, parent_types=(), output_type=output_type)


def _make_shifted_mechanism(original: Mechanism, shift_fn: Callable[[Any], Any]) -> Mechanism:
    def fn(parent_values, rng):
        return shift_fn(original.fn(parent_values, rng))

    return Mechanism(
        name="shift", fn=fn, parent_types=original.parent_types, output_type=original.output_type
    )


def _apply_intervention(derived: System, iv: Intervention) -> None:
    targets = iv.target_list()

    if iv.kind == "do_fix":
        values = iv.params["value"]
        if not isinstance(values, (list, tuple)):
            values = [values] * len(targets)
        if len(values) != len(targets):
            raise ValueError("do_fix(): `value` must have one entry per target.")
        for target, value in zip(targets, values):
            output_type = derived.features[target].type
            derived.mechanisms[target] = _make_constant_mechanism(output_type, value)
            derived.parents[target] = []

    elif iv.kind == "do_distribution":
        distribution = iv.params["distribution"]
        if distribution.parent_types:
            raise NotImplementedError(
                "do_distribution() v1 only supports marginal (parentless) "
                "replacement distributions. Use mechanism_override() for a "
                "conditional replacement."
            )
        for target in targets:
            if distribution.output_type != derived.features[target].type:
                raise ValueError(
                    f"do_distribution(): replacement outputs "
                    f"{distribution.output_type!r}, but {target!r} is "
                    f"declared as {derived.features[target].type!r}."
                )
            derived.mechanisms[target] = distribution
            derived.parents[target] = []

    elif iv.kind == "shift":
        shift_fn = iv.params["fn"]
        for target in targets:
            derived.mechanisms[target] = _make_shifted_mechanism(
                derived.mechanisms[target], shift_fn
            )
            # parents unchanged

    elif iv.kind == "mechanism_override":
        mechanism = iv.params["mechanism"]
        for target in targets:
            derived.mechanisms[target] = mechanism
            # parents unchanged; mismatches caught by System.finalize()

    else:  # pragma: no cover - exhaustive by construction
        raise ValueError(f"Unknown intervention kind: {iv.kind!r}")


def _derive_system(system: System, interventions: Sequence[Intervention]) -> System:
    derived = system.copy()
    for iv in interventions:
        _apply_intervention(derived, iv)
    derived.finalize()
    return derived


@dataclass
class SimulationResult:
    """Comparable artifact: baseline vs. intervened population, plus
    metadata. See SPEC.md section 3.8.
    """

    baseline: pd.DataFrame
    intervened: pd.DataFrame
    interventions: list[Intervention]
    affected_features: list[str]
    propagation_order: list[str]

    def compare(self) -> dict[str, Any]:
        """Compare baseline and intervened populations.

        For each feature in ``affected_features``: mean/std shift for
        continuous features, level-frequency shift for
        categorical/ordinal features.

        Returns
        -------
        dict[str, Any]
            ``{feature_name: summary_dict}``.
        """
        summary: dict[str, Any] = {}
        for name in self.affected_features:
            base_col = self.baseline[name]
            interv_col = self.intervened[name]
            if pd.api.types.is_categorical_dtype(base_col):
                base_freq = base_col.value_counts(normalize=True).sort_index()
                interv_freq = interv_col.value_counts(normalize=True).sort_index()
                summary[name] = {
                    "type": "categorical",
                    "baseline_freq": base_freq.to_dict(),
                    "intervened_freq": interv_freq.to_dict(),
                }
            else:
                summary[name] = {
                    "type": "continuous",
                    "baseline_mean": float(base_col.mean()),
                    "intervened_mean": float(interv_col.mean()),
                    "baseline_sd": float(base_col.std()),
                    "intervened_sd": float(interv_col.std()),
                    "mean_diff": float(interv_col.mean() - base_col.mean()),
                }
        return summary


def propagate(
    system: System,
    interventions: Sequence[Intervention],
    n: Optional[int] = None,
    seed: Optional[int] = None,
    mode: Literal["full", "partial"] = "full",
) -> SimulationResult:
    """Apply interventions and propagate their effects.

    Parameters
    ----------
    system:
        A finalized :class:`~lepidoptera.system.System`.
    interventions:
        Sequence of :class:`Intervention` objects (see :func:`do_fix`,
        :func:`do_distribution`, :func:`shift`,
        :func:`mechanism_override`).
    n:
        Number of units to simulate for the baseline (required).
    seed:
        Optional seed, shared between baseline and intervened population
        for paired comparison.
    mode:
        ``"full"`` resamples the whole population from the derived
        system. ``"partial"`` keeps unaffected features exactly equal to
        the baseline and recomputes only the downstream closure of the
        targeted features. The two modes are each internally
        reproducible given the same seed, but are not bit-identical to
        each other (they consume the per-unit random stream differently).

    Returns
    -------
    SimulationResult
    """
    if not system.finalized:
        raise RuntimeError("System must be finalized before propagate().")
    if mode not in ("full", "partial"):
        raise ValueError("`mode` must be 'full' or 'partial'.")
    if n is None:
        raise ValueError("`n` is required.")
    if not interventions:
        raise ValueError("`interventions` must be non-empty.")

    baseline = simulate(system, n, seed)
    derived = _derive_system(system, interventions)

    targets: list[str] = []
    for iv in interventions:
        for t in iv.target_list():
            if t not in targets:
                targets.append(t)

    affected_features = downstream_closure(system.edges, targets)
    affected_set = set(affected_features)
    propagation_order = [f for f in system.topo_order if f in affected_set]

    if mode == "full":
        intervened = simulate(derived, n, seed)
    else:
        intervened = _propagate_partial(derived, baseline, n, seed, propagation_order)

    return SimulationResult(
        baseline=baseline,
        intervened=intervened,
        interventions=list(interventions),
        affected_features=affected_features,
        propagation_order=propagation_order,
    )


def _propagate_partial(
    derived: System,
    baseline: pd.DataFrame,
    n: int,
    seed: Optional[int],
    propagation_order: list[str],
) -> pd.DataFrame:
    rngs = _unit_rngs(n, seed)
    rows = baseline.to_dict("records")
    new_rows = []
    for row, rng in zip(rows, rngs):
        row = dict(row)
        for name in propagation_order:
            mechanism = derived.mechanisms[name]
            parent_values = {p: row[p] for p in derived.parents[name]}
            row[name] = mechanism.sample(parent_values, rng)
        new_rows.append(row)
    return _to_typed_frame(derived, new_rows)


def compare(result: SimulationResult) -> dict[str, Any]:
    """Module-level convenience wrapper around ``result.compare()``."""
    return result.compare()
