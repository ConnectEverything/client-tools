// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2026 Phil Pennock

import { cloudflareTest } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: './src/worker.js',
      miniflare: {
        kvNamespaces: ['ASSETS'],
      },
    }),
  ],
})
