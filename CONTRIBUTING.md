## HT Fork Management

This repository is an [HT fork](https://github.com/heiervang-technologies/ht-vibe). See the [Fork Management Guide](https://github.com/orgs/heiervang-technologies/discussions/3) for full details.

### Branch Conventions

- **`main`** — Clean fast-forward mirror of upstream. Never commit directly.
- **`ht`** — Default branch with HT-specific changes. All PRs target `ht`.
- **Feature branches** — Create from `ht`, squash-merge back via PR.

### Sync Workflow

```bash
git checkout main
git fetch upstream
git merge --ff-only upstream/main
git push origin main

git checkout ht
git rebase main
git push --force-with-lease origin ht
```

### Commit Standards

- Use [conventional commits](https://www.conventionalcommits.org/) (e.g. `feat:`, `fix:`, `docs:`)
- Maintain linear history — rebase, don't merge
- One logical change per commit

For questions or discussion about this fork, use the [HT Discussions](https://github.com/orgs/heiervang-technologies/discussions) page.

---

Thank you for considering to contribute :D

Here's a rough overview: More detailed instructions can be seen in the their respective directory:

- `vibe-audio`: Is the audio-"engine" which fetches and processes the audio.
- `vibe-renderer`: Is the renderer which renders each component/effect.
- `vibe`: Is the desktop application which makes use of the other crates.

For non-fork-specific changes, please follow the upstream contribution guidelines at [TornaxO7/vibe](https://github.com/TornaxO7/vibe).
