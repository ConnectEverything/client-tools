// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2026 Phil Pennock
//
// Smoke tests running against the real workerd runtime via
// @cloudflare/vitest-pool-workers, with an in-memory KV namespace seeded per
// test. This replaces the old jest + service-worker-mock suite.

/// <reference types="@cloudflare/vitest-pool-workers" />
import { env, createExecutionContext, waitOnExecutionContext } from 'cloudflare:test'
import { beforeEach, describe, expect, it } from 'vitest'
import worker from '../src/worker.js'

/**
 * @param {string} path
 * @param {string} method
 * @returns {Promise<Response>}
 */
async function call(path, method = 'GET') {
  const ctx = createExecutionContext()
  const request = new Request(`https://get-nats.io${path}`, { method })
  const response = await worker.fetch(request, env, ctx)
  await waitOnExecutionContext(ctx)
  return response
}

describe('nightlies worker', () => {
  beforeEach(async () => {
    // Clear anything a prior test seeded.
    const { keys } = await env.ASSETS.list()
    await Promise.all(keys.map((k) => env.ASSETS.delete(k.name)))
  })

  it('serves /current-nightly from the CURRENT key', async () => {
    await env.ASSETS.put('CURRENT', 'nats-nightly-20260701')
    const res = await call('/current-nightly')
    expect(res.status).toBe(200)
    expect(await res.text()).toBe('nats-nightly-20260701')
  })

  it('404s /current-nightly when CURRENT is absent', async () => {
    const res = await call('/current-nightly')
    expect(res.status).toBe(404)
  })

  it('serves a nightly asset with a content-type derived from the name', async () => {
    await env.ASSETS.put('nats-server.zip', 'PK pretend zip')
    const res = await call('/nightly/nats-server.zip')
    expect(res.status).toBe(200)
    expect(res.headers.get('Content-Type')).toBe('application/zip')
    expect(await res.text()).toBe('PK pretend zip')
  })

  it('404s an unknown asset', async () => {
    const res = await call('/nightly/does-not-exist.zip')
    expect(res.status).toBe(404)
  })

  it('404s unknown paths and disallowed methods', async () => {
    expect((await call('/')).status).toBe(404)
    expect((await call('/current-nightly', 'POST')).status).toBe(404)
    expect((await call('/nightly/foo/bar')).status).toBe(404)
  })
})
