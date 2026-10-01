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

### Running the rendering tests

Use the pinned software-rendering shell to run the full Rust test suite without
a physical GPU or desktop session:

```sh
nix develop .#ci --command cargo test -j 2 -- --test-threads=2
```

This shell selects Mesa's Lavapipe Vulkan driver. The rendering tests already
request a software adapter; the driver makes that adapter available consistently
on local machines and GitHub-hosted runners. The default development shell keeps
its usual adapter selection.

The textured fragment-canvas and wallpaper reference images use the shared
nearest-neighbor sampler selected for pixel art. Their references were refreshed
after checking the renders against CPU sampling calculations and confirming that
the old linear sampler reproduced the previous references. Keep the existing
FLIP comparison threshold when updating reference images.
