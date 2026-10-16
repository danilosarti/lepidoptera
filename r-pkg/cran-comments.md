# CRAN Submission Comments

## Test environments

* macOS 14 (Apple M-series), R 4.4.0
* R-hub: windows-x86_64-release, ubuntu-gcc-release, fedora-clang-devel
* win-builder: R-devel

## R CMD check results

0 errors | 0 warnings | 0 notes

(or, if a NOTE appears: "New submission.")

## Downstream dependencies

None. This is a new package.

## Notes to CRAN

* The package has a companion preprint on arXiv (arXiv:XXXX.XXXXX) and a
  manuscript under review at the Journal of Statistical Software.
* The `rvinecopulib` dependency is in `Suggests`, not `Imports`, because the
  vine copula mechanism is optional; the rest of the package runs without it.
* `jsonlite` and `yaml` are in `Suggests` for the same reason (used only in
  `export_system()` / `import_system()`).
