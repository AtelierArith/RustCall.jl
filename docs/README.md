# Documentation languages

English (`src/en`) is the source of truth. Japanese overrides live in `src/ja`
with the same relative filenames. Each translation records its source commit in
an HTML comment; update that marker after checking changes to the English page.
The initial Japanese guides are introductory adaptations, not full translations.

`julia --project=docs docs/make.jl` builds both languages into `build/en` and
`build/ja`. `i18n.jl` stages complete source trees in a temporary directory,
overlays translations and marks untranslated Japanese pages as English originals.
API docstrings and the generated type matrix remain shared English content.
Do not copy generated fallback pages into `src/ja`.

Navigation lives in `navigation.jl`; Japanese section labels are in `i18n.jl`.
Keep corresponding filenames and explicit heading IDs stable. Cross-references
are resolved independently within each language. Language links preserve the
version and page but clear the anchor because translated headings can differ.
Source edit links are disabled because builds use staged sources.

Deployment runs sequentially in one CI job, using `dirname = "en"` and `"ja"`.
Each language has its own `stable`, release versions, `dev` and PR previews.
New release documentation appears on the next tag; existing historical releases
are not rebuilt. The root language chooser links to `dev` so it works before the
first bilingual release. `publish_docs_landing.py` updates only the root file,
without replacing language trees. It runs only after deployment on main.

Preview with `python3 -m http.server --directory docs/build`; local URLs are
`/en/index.html` and `/ja/index.html` (CI uses pretty URLs).
