// BEWARE
// This code is the author's first Node, and the author learnt web programming
// and JS in the 1990s and has used jQuery maybe twice, nothing newer than
// that.
// Help had to be gotten to deal with TS types.
// So: this is not idiomatic and is probably stupid.
// There might be cleaner ways of doing things.
// If I did something strange, it's probably ignorance on my part, not missing
// insight into the rationale on your part.

import { Router } from 'itty-router'

const router = Router()

const current = async () => {
  const value = await ASSETS.get("CURRENT", {type: "text"})
  if (value === null) {
    console.log("saw a request for CURRENT, does not exist in KV store, fatal expectation violation")
    return new Response("Current value not found, please report this\n", {status: 404})
  }

  return new Response(value)
}

const nightlyAsset = async (request: Request) => {
  // pdp note: Alberto says if I use an IDE it will auto-manage tsconfig.json
  // to adjust the import/export rules to let the
  // node_modules/itty-router/dist/itty-router.d.ts types be imported instead
  // of excluded, but managing the rules by hand to create an exception for
  // this case would be ... harder.
  // Failing that, there's a way to ignore the type failure for one line.
  // Looks to me like this then has to cascade with params being of unknown type,
  // but it works.

  // @ts-ignore: itty-router has it, can't get the imports working
  const { params } = request
  const assetId = params.id
  const value = await ASSETS.get(assetId, {type: "stream"})
  if (value === null) {
    return new Response("Asset not found\n", {status: 404})
  }

  // I'm confident there's a large library which will handle this for us, but
  // we have a very few cases to handle and I can optimize based on expected
  // payloads for this server, so let's keep it simple.
  let ctype = ""
  if (assetId.endsWith(".zip")) {
    ctype = "application/zip"
  } else if (assetId.endsWith(".txt")) {
    ctype = "text/plain; charset=US-ASCII"
  } else if (assetId == "CURRENT") {
    ctype = "text/plain; charset=US-ASCII"
  } else if (assetId.endsWith(".tar.gz")) {
    ctype = "application/x-tar-gz"
  } else if (assetId.endsWith(".asc")) {
    ctype = "application/pgp-signature"
  }
  // cosign doesn't have a standard file extension for blob attestations
  // signify uses .sig, as do a few other things

  if (ctype != "") {
    return new Response(value, { headers: {
      "Content-Type": ctype,
    }})
  }
  return new Response(value)
}

router
  .get('/current-nightly', current)
  .head('/current-nightly', current)
  .get('/nightly/:id', nightlyAsset)
  .get('*', () => new Response("Not found\n", { status: 404 }))

// I can't see a way with CloudFlare's KV store to efficiently get the metadata for a key,
// such as "exists" and "size of the value", so not coding up .head for the nightly assets.

export const handleRequest = (request: Request) => router.handle(request)
