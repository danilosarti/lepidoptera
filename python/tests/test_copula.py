"""Placeholder tests for the copula mechanism (SPEC.md section 4.1).
Skipped when pyvinecopulib is not installed (it is an optional extra, not
a hard dependency).
"""

import pytest

pyvinecopulib = pytest.importorskip("pyvinecopulib")


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 4.1.")
def test_copula_mechanism_regression_handling_excludes_nominal_vars():
    pass


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 4.1.")
def test_copula_mechanism_conditional_sampling_respects_parent_values():
    pass


@pytest.mark.skip(reason="Not implemented yet. See SPEC.md section 4.1.")
def test_list_copula_families_reflects_installed_backend():
    pass
