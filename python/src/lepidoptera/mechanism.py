"""Mechanism library layer.

Marginal and conditional mechanisms, the pre-built library covering the
most common type combinations (SPEC.md section 4), and the custom
mechanism registry.

Calling convention for ``Mechanism.fn``: ``fn(parent_values, rng) -> value``,
where ``parent_values`` is a ``dict[name, value]`` (empty for a marginal
mechanism) and ``rng`` is a :class:`numpy.random.Generator`.

v1 scope: the pre-built factories below cover continuous<->continuous,
continuous->categorical/ordinal, and a single categorical/ordinal parent
affecting a categorical/ordinal/continuous child. Arbitrary mixed-parent
combinations are supported via :func:`register_mechanism` with a custom
``fn`` (the core never requires a pre-built mechanism — see SPEC.md
section 4, closing paragraph).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Sequence

import numpy as np

ParentValues = Mapping[str, Any]
MechanismFn = Callable[[ParentValues, np.random.Generator], Any]


@dataclass(frozen=True)
class Mechanism:
    """The generative rule attached to a feature. See SPEC.md section 3.3.

    Attributes
    ----------
    name:
        Human-readable identifier (not necessarily unique).
    fn:
        ``fn(parent_values, rng) -> value``.
    parent_types:
        One :data:`~lepidoptera.type_system.FEATURE_TYPES` entry per
        declared parent, in the same order the parents will be declared
        in ``System.add_dependency(parents=..., ...)``. Empty for a
        marginal mechanism.
    output_type:
        One of :data:`~lepidoptera.type_system.FEATURE_TYPES`.
    spec:
        Optional ``{"factory": key, "kwargs": {...}}`` recorded by
        pre-built factories, used by io.py to serialize/reconstruct the
        mechanism. ``None`` for custom (registered) mechanisms, which are
        not JSON-serializable.
    """

    name: str
    fn: MechanismFn
    parent_types: tuple[str, ...]
    output_type: str
    spec: Mapping[str, Any] | None = field(default=None)

    def sample(self, parent_values: ParentValues, rng: np.random.Generator) -> Any:
        return self.fn(parent_values, rng)


_CUSTOM_MECHANISMS: dict[str, Mechanism] = {}


def register_mechanism(
    name: str,
    fn: MechanismFn,
    parent_types: Sequence[str],
    output_type: str,
) -> Mechanism:
    """Register a custom mechanism.

    Parameters
    ----------
    name:
        Key under which the mechanism is registered.
    fn:
        ``fn(parent_values, rng) -> value`` compatible with ``output_type``.
    parent_types:
        One feature-type entry per declared parent, in the order parents
        will be declared in ``add_dependency``.
    output_type:
        One of the FeatureType values.

    Returns
    -------
    Mechanism
    """
    mech = Mechanism(
        name=name, fn=fn, parent_types=tuple(parent_types), output_type=output_type
    )
    _CUSTOM_MECHANISMS[name] = mech
    return mech


# --------------------------------------------------------------------------
# Pre-built mechanism factories
# --------------------------------------------------------------------------


def _normal_factory(mean: float = 0.0, sd: float = 1.0) -> Mechanism:
    def fn(parent_values: ParentValues, rng: np.random.Generator) -> float:
        return float(rng.normal(mean, sd))

    return Mechanism(
        name="normal",
        fn=fn,
        parent_types=(),
        output_type="continuous",
        spec={"factory": "normal", "kwargs": {"mean": mean, "sd": sd}},
    )


def _categorical_marginal_factory(
    levels: Sequence[Any], probs: Sequence[float], ordinal: bool = False
) -> Mechanism:
    levels = list(levels)
    probs_arr = np.asarray(probs, dtype=float)
    if len(levels) != len(probs_arr):
        raise ValueError("`levels` and `probs` must have the same length.")
    if not math.isclose(probs_arr.sum(), 1.0, abs_tol=1e-6):
        raise ValueError("`probs` must sum to 1.")

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> Any:
        return levels[rng.choice(len(levels), p=probs_arr)]

    key = "ordinal_marginal" if ordinal else "categorical_marginal"
    return Mechanism(
        name=key,
        fn=fn,
        parent_types=(),
        output_type="ordinal" if ordinal else "categorical",
        spec={"factory": key, "kwargs": {"levels": levels, "probs": list(probs_arr)}},
    )


def _categorical_marginal(levels: Sequence[Any], probs: Sequence[float]) -> Mechanism:
    """Root mechanism for a categorical feature: P(level) given by `probs`."""
    return _categorical_marginal_factory(levels, probs, ordinal=False)


def _ordinal_marginal(levels: Sequence[Any], probs: Sequence[float]) -> Mechanism:
    """Root mechanism for an ordinal feature: P(level) given by `probs`,
    `levels` given in scale order."""
    return _categorical_marginal_factory(levels, probs, ordinal=True)


def _linear_gaussian_factory(
    coefs: Mapping[str, float], intercept: float = 0.0, sd: float = 1.0
) -> Mechanism:
    """Continuous parents -> continuous child: linear combination + Gaussian noise.

    ``parents`` declared in ``add_dependency`` must all be continuous, in
    any order matching the keys of `coefs` (lookup is by name).
    """
    parent_names = tuple(coefs.keys())

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> float:
        score = intercept + sum(
            coefs[name] * float(parent_values[name]) for name in parent_names
        )
        return float(score + rng.normal(0.0, sd))

    return Mechanism(
        name="linear_gaussian",
        fn=fn,
        parent_types=tuple("continuous" for _ in parent_names),
        output_type="continuous",
        spec={
            "factory": "linear_gaussian",
            "kwargs": {"coefs": dict(coefs), "intercept": intercept, "sd": sd},
        },
    )


def _softmax(scores: Mapping[Any, float]) -> dict[Any, float]:
    keys = list(scores.keys())
    values = np.array([scores[k] for k in keys], dtype=float)
    values = values - values.max()
    exp = np.exp(values)
    probs = exp / exp.sum()
    return dict(zip(keys, probs))


def _multinomial_logit_factory(
    levels: Sequence[Any],
    coefs: Mapping[Any, Mapping[str, float]],
    intercepts: Mapping[Any, float] | None = None,
) -> Mechanism:
    """Continuous parents -> categorical child via multinomial logit.

    `coefs` maps each level to a dict of {parent_name: coefficient}; the
    linear score for each level is ``intercepts.get(level, 0) + sum(coef *
    parent_value)``, levels' probabilities via softmax over scores.
    """
    levels = list(levels)
    intercepts = dict(intercepts or {})
    parent_names = sorted({p for level_coefs in coefs.values() for p in level_coefs})

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> Any:
        scores = {
            level: intercepts.get(level, 0.0)
            + sum(
                coefs.get(level, {}).get(p, 0.0) * float(parent_values[p])
                for p in parent_names
            )
            for level in levels
        }
        probs = _softmax(scores)
        p_arr = np.array([probs[level] for level in levels])
        return levels[rng.choice(len(levels), p=p_arr)]

    return Mechanism(
        name="multinomial_logit",
        fn=fn,
        parent_types=tuple("continuous" for _ in parent_names),
        output_type="categorical",
        spec={
            "factory": "multinomial_logit",
            "kwargs": {
                "levels": levels,
                "coefs": {k: dict(v) for k, v in coefs.items()},
                "intercepts": intercepts,
            },
        },
    )


def _ordered_logit_factory(
    levels: Sequence[Any],
    coefs: Mapping[str, float],
    cutpoints: Sequence[float],
) -> Mechanism:
    """Continuous parents -> ordinal child via proportional-odds (ordered logit).

    `levels` in scale order; `cutpoints` (length = len(levels) - 1,
    increasing) are the thresholds on the latent linear score.
    """
    levels = list(levels)
    cutpoints = list(cutpoints)
    if len(cutpoints) != len(levels) - 1:
        raise ValueError("`cutpoints` must have length len(levels) - 1.")
    parent_names = tuple(coefs.keys())

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> Any:
        score = sum(coefs[name] * float(parent_values[name]) for name in parent_names)
        latent = score + rng.logistic(0.0, 1.0)
        idx = 0
        for cut in cutpoints:
            if latent <= cut:
                break
            idx += 1
        return levels[idx]

    return Mechanism(
        name="ordered_logit",
        fn=fn,
        parent_types=tuple("continuous" for _ in parent_names),
        output_type="ordinal",
        spec={
            "factory": "ordered_logit",
            "kwargs": {
                "levels": levels,
                "coefs": dict(coefs),
                "cutpoints": cutpoints,
            },
        },
    )


def _categorical_transition_factory(
    transition: Mapping[Any, Mapping[Any, float]],
    output_type: str = "categorical",
) -> Mechanism:
    """Single categorical/ordinal parent -> categorical/ordinal child via a
    transition table: ``transition[parent_level] = {child_level: prob}``.
    """
    if len(transition) == 0:
        raise ValueError("`transition` must not be empty.")
    (parent_name_placeholder,) = (None,)  # parent name is supplied at call time

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> Any:
        (parent_value,) = parent_values.values()
        row = transition[parent_value]
        levels = list(row.keys())
        probs = np.array(list(row.values()), dtype=float)
        return levels[rng.choice(len(levels), p=probs)]

    return Mechanism(
        name="categorical_transition",
        fn=fn,
        parent_types=("categorical",),
        output_type=output_type,
        spec={
            "factory": "categorical_transition",
            "kwargs": {
                "transition": {k: dict(v) for k, v in transition.items()},
                "output_type": output_type,
            },
        },
    )


def _group_effect_factory(
    group_params: Mapping[Any, Mapping[str, float]],
) -> Mechanism:
    """Single categorical/ordinal parent -> continuous child: per-level
    Normal(mean, sd). ``group_params[level] = {"mean": ..., "sd": ...}``.
    """
    if len(group_params) == 0:
        raise ValueError("`group_params` must not be empty.")

    def fn(parent_values: ParentValues, rng: np.random.Generator) -> float:
        (parent_value,) = parent_values.values()
        params = group_params[parent_value]
        return float(rng.normal(params["mean"], params["sd"]))

    return Mechanism(
        name="group_effect",
        fn=fn,
        parent_types=("categorical",),
        output_type="continuous",
        spec={
            "factory": "group_effect",
            "kwargs": {"group_params": {k: dict(v) for k, v in group_params.items()}},
        },
    )


_LIBRARY: dict[str, Callable[..., Mechanism]] = {
    "normal": _normal_factory,
    "categorical_marginal": _categorical_marginal,
    "ordinal_marginal": _ordinal_marginal,
    "linear_gaussian": _linear_gaussian_factory,
    "multinomial_logit": _multinomial_logit_factory,
    "ordered_logit": _ordered_logit_factory,
    "categorical_transition": _categorical_transition_factory,
    "group_effect": _group_effect_factory,
}


class MechanismLibrary:
    """Registry of pre-built mechanism factories covering SPEC.md section 4.

    ``get(key)`` returns a *factory* (a callable), not a ready
    :class:`Mechanism` — pre-built mechanisms always need parameters (a
    mean, a set of coefficients, a transition table, ...). Call the
    factory with those parameters to obtain the actual `Mechanism`, e.g.
    ``mechanism_library.get("linear_gaussian")(coefs={"age": 0.1}, sd=1.0)``.
    """

    def get(self, key: str) -> Callable[..., Mechanism]:
        """Look up a pre-built mechanism factory by key.

        Parameters
        ----------
        key:
            One of ``"normal"``, ``"categorical_marginal"``,
            ``"ordinal_marginal"``, ``"linear_gaussian"``,
            ``"multinomial_logit"``, ``"ordered_logit"``,
            ``"categorical_transition"``, ``"group_effect"``.
        """
        try:
            return _LIBRARY[key]
        except KeyError as exc:
            raise KeyError(
                f"Unknown pre-built mechanism {key!r}. Available: "
                f"{sorted(_LIBRARY)}. For anything else, use register_mechanism()."
            ) from exc

    def keys(self) -> list[str]:
        return sorted(_LIBRARY)


mechanism_library = MechanismLibrary()


def mechanism_from_spec(spec: Mapping[str, Any]) -> Mechanism:
    """Rebuild a Mechanism from its serialized `spec` (io.py helper)."""
    factory = mechanism_library.get(spec["factory"])
    return factory(**spec.get("kwargs", {}))
