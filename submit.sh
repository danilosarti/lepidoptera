#!/bin/bash
set -e

echo "=== R package: document + check ==="
cd /Users/danilosarti/lepidoptera/lepidoptera/r-pkg

Rscript -e 'if (!requireNamespace("devtools", quietly=TRUE)) install.packages("devtools")'
Rscript -e 'if (!requireNamespace("roxygen2", quietly=TRUE)) install.packages("roxygen2")'
Rscript -e 'devtools::document()'
Rscript -e 'devtools::check()'

echo ""
echo "=== Python package: build + check ==="
cd /Users/danilosarti/lepidoptera/lepidoptera/python

pip install --upgrade hatchling build twine
python -m build
twine check dist/*

echo ""
echo "Done. To publish Python: twine upload dist/*"
echo "To submit R to CRAN:     Rscript -e 'devtools::submit_cran()'"
