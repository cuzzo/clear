# site — Zola site (GitHub Pages)

Published at **https://cuzzo.github.io/clear**.

Content is **not** authored here. The single source of truth is
[`docs/`](../docs). `tools/gen_site.rb` maps source markdown into Zola
sections with injected TOML front matter (title from the first `# `
heading; `date`/`updated` from git history; markdown links between
any two generated files — including cross-section — rewritten to Zola
internal links). Generated files are git-ignored; only the section
`_index.md` files are authored here.

| Section | Source | URL |
|---|---|---|
| `blog` | `docs/retrospective/*.md` | `/blog/` |
| `docs` | `docs/**/*.md` except `docs/agents` and the retrospective blog | `/docs/` |

## Local preview

```bash
ruby tools/gen_site.rb        # from repo root
cd site && zola serve         # http://127.0.0.1:1111
```

`zola build` outputs to `site/public/`.

## Publishing

`.github/workflows/pages.yml` runs the generator, `zola build`, and
deploys `site/public/` as a GitHub Pages artifact on every push to
`master` (and via manual dispatch). Enable Pages once in
**Settings → Pages → Source: GitHub Actions**.

To add a blog post, drop a file in `docs/retrospective/`. To add a
doc page, drop a file anywhere in `docs/` (outside `docs/agents`).
Nothing here changes.
