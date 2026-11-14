# Documentation languages

English (`src/en`) is the source of truth. Japanese overrides live in `src/ja`
with the same relative filenames. Each translation records its source commit in
an HTML comment; update that marker after checking changes to the English page.
All English pages have Japanese counterparts, including reference introductions and
platform/developer guides. Translations retain the examples and the technical
conditions while using concise Japanese prose.

`julia --project=docs docs/make.jl` builds both languages into `build/en` and
`build/ja`. `i18n.jl` stages complete source trees in a temporary directory,
overlays translations. The build first checks translation coverage so a new
English page cannot silently appear in Japanese as an English fallback.
The staging helper retains its marked fallback for standalone use.
API docstrings remain shared English content, explicitly identified in the
Japanese API index; executable examples and their output remain unchanged.
The Japanese type-contract prose is maintained in Markdown, and the build
refreshes only the region between `TYPE_MATRIX_START` / `TYPE_MATRIX_END`
from the same contract as the English table, with Japanese column headings.

Navigation lives in `navigation.jl`; Japanese section labels are in `i18n.jl`.
Keep corresponding filenames and heading IDs stable. Japanese headings use the
English page's original IDs, retaining the three introductory pages' existing
explicit IDs (`home`, `tutorial`, `troubleshooting`). Cross-references
are resolved independently within each language. Language links preserve the
version and page but clear the anchor because translated headings can differ.
Source edit links are disabled because builds use staged sources.

Deployment runs sequentially in one CI job, using `dirname = "en"` and `"ja"`.
The options are shared in `deployment.jl`. Every build first runs
`test_deployment.jl` against Documenter's GitHub Actions deployment decision for
both development and release events; this catches silent deployment skips
(such as a repository name whose casing differs from `GITHUB_REPOSITORY`).
Each language has its own `stable`, release versions, `dev` and PR previews.
New release documentation appears on the next tag; existing historical releases
are not rebuilt. The root language chooser links to `dev` so it works before the
first bilingual release. `publish_docs_landing.py` updates only the root file,
without replacing language trees. It runs only after deployment on main.

Preview with `python3 -m http.server --directory docs/build`; local URLs are
`/en/index.html` and `/ja/index.html` (CI uses pretty URLs).
