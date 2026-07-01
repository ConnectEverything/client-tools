// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2026 Phil Pennock

import { defineWorkersConfig } from '@cloudflare/vitest-pool-workers/config'

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        main: './src/worker.js',
        miniflare: {
          kvNamespaces: ['ASSETS'],
        },
      },
    },
  },
})
