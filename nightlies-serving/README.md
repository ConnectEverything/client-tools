# nightlies-serving

A Cloudflare Worker that serves the nats.io nightly build assets out of a
Workers KV namespace, behind `get-nats.io`.

## Design

Deliberately minimal and **dependency-free at runtime**. The worker is a single
hand-written ES module, [`src/worker.js`](./src/worker.js), with no router
library and no bundler:

- `GET|HEAD /current-nightly` → returns the `CURRENT` key from the KV namespace.
- `GET /nightly/:id` → streams the named asset back, with a `Content-Type`
  guessed from the file extension.
- everything else → `404`.

This replaced an earlier TypeScript setup (webpack + `ts-loader` + `itty-router`
+ jest + `service-worker-mock` + eslint). That toolchain contributed nothing to
the ~40 lines of edge code but was a perpetual source of npm audit churn and
eventually developed irreconcilable version conflicts. There is now **zero**
runtime dependency; the only npm packages are dev tooling (wrangler, vitest),
none of which ships to the edge.

### Why not Go / WASM?

Cloudflare Workers run JS/WASM on V8 isolates. Go's stdlib knows nothing about
the Workers `fetch` event or KV bindings, so a Go worker requires TinyGo plus a
third-party bridge (`syumai/workers`) and still has a build step — trading npm
churn for a heavier toolchain, for 40 lines of glue. Not worth it. Plain JS with
no build step is the simpler, smaller target.

## Development

Requires Node (for the tooling) and a Cloudflare account for deploys.

```bash
npm install
npm test          # vitest, runs against the real workerd runtime via
                  # @cloudflare/vitest-pool-workers, with an in-memory KV
npm run typecheck # tsc --noEmit over the JSDoc-annotated JS (checkJs)
npm run dev       # wrangler dev, local preview
npm run deploy    # wrangler deploy
```

There is no build/bundle step: `wrangler` uploads `src/worker.js` directly (see
`main` in [`wrangler.toml`](./wrangler.toml)).

## License

MIT OR Apache-2.0. See `LICENSE_MIT` and `LICENSE_APACHE`.
