# Cronyx Docs

Docusaurus site, deployed to https://brendancron.github.io/compiler/ via GitHub Actions on push to `main`.

## Local development

```bash
cd docs
npm install        # first time, generates package-lock.json
npm start          # dev server with hot reload
npm run build      # production build into ./build
npm run serve      # serve the production build locally
```

## Adding content

Drop markdown files into `docs/`. The sidebar is auto-generated from the directory tree. Use `sidebar_position` frontmatter to control ordering.
