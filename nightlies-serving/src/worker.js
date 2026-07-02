// @ts-check
// SPDX-License-Identifier: MIT OR Apache-2.0
// Copyright 2022, 2026 Phil Pennock
//
// Cloudflare Worker for serving nats.io nightly builds out of a KV namespace.
//
// Deliberately dependency-free: a single ES-module worker, no bundler, no
// router library. Routing is a couple of pathname checks; that is all this
// needs. See README.md for the history (this replaced a webpack + itty-router
// + jest toolchain that was a perpetual source of npm audit churn).

/**
 * Pick a Content-Type for a nightly asset based on its name. We only serve a
 * handful of shapes, so an explicit switch beats pulling in a mime library.
 * Returns null when we have nothing better to say than the default.
 *
 * @param {string} assetId
 * @returns {string | null}
 */
function contentType(assetId) {
  if (assetId.endsWith('.zip')) return 'application/zip'
  if (assetId.endsWith('.txt')) return 'text/plain; charset=US-ASCII'
  if (assetId === 'CURRENT') return 'text/plain; charset=US-ASCII'
  if (assetId.endsWith('.tar.gz')) return 'application/x-tar-gz'
  if (assetId.endsWith('.asc')) return 'application/pgp-signature'
  // cosign has no standard extension for blob attestations; signify uses .sig,
  // as do a few other things. We leave those to the default.
  return null
}

/**
 * @param {import('@cloudflare/workers-types').KVNamespace} assets
 * @returns {Promise<Response>}
 */
async function current(assets) {
  const value = await assets.get('CURRENT', { type: 'text' })
  if (value === null) {
    console.log(
      'saw a request for CURRENT, does not exist in KV store, fatal expectation violation',
    )
    return new Response('Current value not found, please report this\n', { status: 404 })
  }
  return new Response(value)
}

/**
 * @param {string} assetId
 * @param {import('@cloudflare/workers-types').KVNamespace} assets
 * @returns {Promise<Response>}
 */
async function nightlyAsset(assetId, assets) {
  const value = await assets.get(assetId, { type: 'stream' })
  if (value === null) {
    return new Response('Asset not found\n', { status: 404 })
  }
  const ctype = contentType(assetId)
  return ctype === null
    ? new Response(value)
    : new Response(value, { headers: { 'Content-Type': ctype } })
}

export default {
  /**
   * @param {Request} request
   * @param {{ ASSETS: import('@cloudflare/workers-types').KVNamespace }} env
   * @param {ExecutionContext} [ctx]
   * @returns {Promise<Response>}
   */
  async fetch(request, env, ctx) {
    const { pathname } = new URL(request.url)

    if (pathname === '/current-nightly') {
      if (request.method === 'GET' || request.method === 'HEAD') {
        return current(env.ASSETS)
      }
      return new Response('Not found\n', { status: 404 })
    }

    // We cannot cheaply get KV key metadata (existence / size), so no HEAD for
    // individual assets, matching the original behaviour.
    if (request.method === 'GET') {
      const match = pathname.match(/^\/nightly\/([^/]+)$/)
      if (match) {
        let assetId
        try {
          assetId = decodeURIComponent(match[1])
        } catch {
          return new Response('Not found\n', { status: 404 })
        }
        return nightlyAsset(assetId, env.ASSETS)
      }
    }

    return new Response('Not found\n', { status: 404 })
  },
}
