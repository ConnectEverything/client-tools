// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2026 Phil Pennock
//
// Declares the bindings available to tests via `cloudflare:test`'s `env`,
// mirroring the miniflare.kvNamespaces list in vitest.config.js.

declare module 'cloudflare:test' {
  interface ProvidedEnv {
    ASSETS: KVNamespace
  }
}
