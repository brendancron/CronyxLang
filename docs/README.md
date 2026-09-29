# The Cronyx documentation site

[Docusaurus](https://docusaurus.io/). The prose is under `docs/`, the pages
under `src/pages/`, and `assets/` at the repo root holds the logo, which this
site serves through `staticDirectories`.

```bash
npm install
npm start          # dev server, live reload
npm run build      # static site into build/
npm run serve      # serve what build/ holds
```

`.github/workflows/deploy-docs.yml` builds and publishes to GitHub Pages on
every push to `main` that touches `docs/` or `assets/`, so there is nothing to
deploy by hand.

The generated API reference is a different thing and is not built from here:
`cx docs` renders it from what the compiler holds. See
[internal-docs/Generated Documentation.md](../internal-docs/Generated%20Documentation.md).
