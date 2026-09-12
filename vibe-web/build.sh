#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building vibe-web with wasm-pack..."
# Emit pkg/ into www/ so the relative `./pkg/vibe_web.js` import in index.html
# resolves and the page can be served from www/ directly.
wasm-pack build --target web --out-dir www/pkg

echo
echo "Build complete!"
echo "To test: cd www && python3 -m http.server 8080"
echo "Then open http://localhost:8080"
