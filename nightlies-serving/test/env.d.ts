// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2026 Phil Pennock
//
// Declares the bindings available to tests via `cloudflare:test`'s `env`,
// mirroring the miniflare.kvNamespaces list in vitest.config.js. As of
// vitest-pool-workers 0.17 / vitest 4, `env` is typed as `Cloudflare.Env`
// rather than the old `ProvidedEnv`, so we augment that namespace.

declare namespace Cloudflare {
  interface Env {
    ASSETS: KVNamespace
  }
}
