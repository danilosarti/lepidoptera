%% jss.cls -- Journal of Statistical Software class file
%% Reconstructed from public JSS style specifications for compilation purposes.
%% Replace with the official file from https://www.jstatsoft.org/style before submission.
%%
%% Based on: Zeileis et al., JSS style guide (2023).
%%
\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{jss}[2023/01/01 v3.2 Journal of Statistical Software]

%% ── Options ───────────────────────────────────────────────────────────────────
\newif\if@article  \@articletrue
\newif\if@codesnippet \@codesnippetfalse
\newif\if@bookreview  \@bookreviewfalse
\newif\if@softwarereview \@softwarereviewfalse

\DeclareOption{article}{\@articletrue}
\DeclareOption{codesnippet}{\@articlefalse\@codesnippettrue}
\DeclareOption{bookreview}{\@articlefalse\@bookreviewtrue}
\DeclareOption{softwarereview}{\@articlefalse\@softwarereviewtrue}
\DeclareOption*{\PassOptionsToClass{\CurrentOption}{article}}
\ProcessOptions

\LoadClass[11pt,a4paper,twoside]{article}

%% ── Required packages ─────────────────────────────────────────────────────────
\RequirePackage[T1]{fontenc}
\RequirePackage{lmodern}
\RequirePackage{microtype}
\RequirePackage{geometry}
\geometry{a4paper, top=30mm, bottom=30mm, left=25mm, right=25mm,
          headheight=14pt, headsep=10mm, footskip=12mm}
\RequirePackage{amsmath,amssymb}
\RequirePackage{graphicx}
\RequirePackage{fancyhdr}
\RequirePackage{xcolor}
\RequirePackage{booktabs}
\RequirePackage{array}
\RequirePackage{verbatim}
\RequirePackage{fancyvrb}
\RequirePackage{tcolorbox}
\RequirePackage{listings}
\RequirePackage{hyperref}
\RequirePackage[round]{natbib}
\RequirePackage{setspace}
\RequirePackage{titlesec}
\RequirePackage{enumitem}

%% ── Colours ───────────────────────────────────────────────────────────────────
\definecolor{jssblue}{RGB}{0,81,158}
\definecolor{jsslightblue}{RGB}{205,222,239}
\definecolor{jsscodebg}{RGB}{248,248,248}
\definecolor{jssoutputbg}{RGB}{240,248,240}
\definecolor{jssheaderbg}{RGB}{0,81,158}

%% ── Fonts and spacing ─────────────────────────────────────────────────────────
\setlength{\parskip}{0pt}
\setlength{\parindent}{15pt}
\renewcommand{\baselinestretch}{1.1}

%% ── JSS macros ────────────────────────────────────────────────────────────────
\newcommand{\pkg}[1]{{\fontseries{b}\selectfont #1}}
\newcommand{\proglang}[1]{\textsf{#1}}
\newcommand{\code}[1]{\texttt{\small #1}}
\newcommand{\fct}[1]{\texttt{\small #1()}}
\newcommand{\class}[1]{\texttt{\small"#1"}}
\newcommand{\email}[1]{\normalfont\texttt{\small #1}}
\newcommand{\doi}[1]{\href{https://doi.org/#1}{\texttt{doi:#1}}}

%% ── Title / Author machinery ─────────────────────────────────────────────────
\newcommand{\@titleshort}{}
\newcommand{\@authorshort}{}
\newcommand{\titleshort}[1]{\renewcommand{\@titleshort}{#1}}
\newcommand{\authorshort}[1]{\renewcommand{\@authorshort}{#1}}
%% Plain versions for PDF bookmarks (required by official jss.cls)
\newcommand{\Plaintitle}[1]{\hypersetup{pdftitle={#1}}}
\newcommand{\Plainauthor}[1]{\hypersetup{pdfauthor={#1}}}
\newcommand{\@Keywords}{}
\newcommand{\Keywords}[1]{\renewcommand{\@Keywords}{#1}}
\newcommand{\@Plainkeywords}{}
\newcommand{\Plainkeywords}[1]{\renewcommand{\@Plainkeywords}{#1}}
\newcommand{\@Volume}{}
\newcommand{\@Issue}{}
\newcommand{\@Year}{}
\newcommand{\@Submitdate}{}
\newcommand{\@Acceptdate}{}
\newcommand{\@DOI}{}

\newcommand{\Address}[1]{%
  \begingroup
  \setlength{\parskip}{2pt}
  \setlength{\parindent}{0pt}
  \footnotesize #1
  \endgroup
}

%% ── Abstract environment ──────────────────────────────────────────────────────
\renewenvironment{abstract}{%
  \begin{tcolorbox}[
    colback=jsslightblue!40, colframe=jssblue,
    title={\textbf{\textsf{Abstract}}},
    fonttitle=\small\bfseries\sffamily,
    left=6pt, right=6pt, top=4pt, bottom=4pt,
    boxrule=0.6pt, arc=2pt
  ]
  \small
}{%
  \if\relax\@Keywords\relax\else
    \par\medskip\noindent\textbf{Keywords:}~\@Keywords.
  \fi
  \end{tcolorbox}
}

%% ── Title formatting ──────────────────────────────────────────────────────────
\renewcommand{\maketitle}{%
  \thispagestyle{empty}%
  \begin{tcolorbox}[
    colback=jssheaderbg, colframe=jssheaderbg,
    left=8pt, right=8pt, top=6pt, bottom=6pt,
    boxrule=0pt, arc=0pt
  ]
  \color{white}%
  \noindent\textsf{\textbf{\large Journal of Statistical Software}}%
  \hfill\textsf{\small MMMMMM YYYY, Volume VV, Issue II.}\\[2pt]
  \textsf{\small \doi{10.18637/jss.vVV.iII}}%
  \hfill\textsf{\small Submitted: DD MMMM YYYY; Accepted: DD MMMM YYYY.}
  \end{tcolorbox}%
  \vspace{8mm}%
  {\LARGE\bfseries\sffamily\color{jssblue}\@title\par}%
  \vspace{5mm}%
  {\large\@author\par}%
  \vspace{8mm}%
}

%% ── Section formatting ────────────────────────────────────────────────────────
\titleformat{\section}
  {\large\bfseries\sffamily\color{jssblue}}{\thesection}{1em}{}
\titleformat{\subsection}
  {\normalsize\bfseries\sffamily}{\thesubsection}{1em}{}
\titleformat{\subsubsection}
  {\normalsize\itshape}{\thesubsubsection}{1em}{}
\titlespacing*{\section}{0pt}{14pt plus 2pt minus 2pt}{6pt}
\titlespacing*{\subsection}{0pt}{10pt plus 2pt minus 2pt}{4pt}

%% ── Headers and footers ───────────────────────────────────────────────────────
\pagestyle{fancy}
\fancyhf{}
\fancyhead[LE,RO]{\small\thepage}
\fancyhead[LO]{\small\textsf{\textit{Journal of Statistical Software}}}
\fancyhead[RE]{\small\textsf{\textit{\pkg{lepidoptera}: Causal Simulation Engine}}}
\renewcommand{\headrulewidth}{0.4pt}

%% ── Code environments ─────────────────────────────────────────────────────────
\lstdefinestyle{jsscode}{%
  backgroundcolor=\color{jsscodebg},
  basicstyle=\small\ttfamily,
  breaklines=true,
  breakatwhitespace=true,
  frame=single,
  rulecolor=\color{gray!40},
  framesep=4pt,
  framextopmargin=2pt,
  framexbottommargin=2pt,
  xleftmargin=6pt,
  xrightmargin=6pt,
  aboveskip=6pt,
  belowskip=6pt,
  showstringspaces=false,
  keepspaces=true,
  columns=flexible
}

\lstdefinestyle{jssoutput}{%
  backgroundcolor=\color{jssoutputbg},
  basicstyle=\small\ttfamily,
  breaklines=true,
  breakatwhitespace=true,
  frame=single,
  rulecolor=\color{gray!30},
  framesep=4pt,
  framextopmargin=2pt,
  framexbottommargin=2pt,
  xleftmargin=6pt,
  xrightmargin=6pt,
  aboveskip=6pt,
  belowskip=6pt,
  showstringspaces=false,
  keepspaces=true,
  columns=flexible
}

\lstnewenvironment{CodeInput}{\lstset{style=jsscode}}{}
\lstnewenvironment{CodeOutput}{\lstset{style=jssoutput}}{}
\lstnewenvironment{Code}{\lstset{style=jsscode}}{}

%% ── Theorem-like environments ─────────────────────────────────────────────────
\RequirePackage{amsthm}
\newtheoremstyle{jssthm}
  {8pt}{6pt}{\itshape}{0pt}{\bfseries}{.}{ }{}
\theoremstyle{jssthm}
\newtheorem{definition}{Definition}[section]
\newtheorem{proposition}{Proposition}[section]
\newtheorem{corollary}{Corollary}[section]
\newtheorem{remark}{Remark}[section]
\newtheorem{example}{Example}[section]

%% ── Bibliography ──────────────────────────────────────────────────────────────
\bibpunct{(}{)}{;}{a}{,}{,}

\endinput
