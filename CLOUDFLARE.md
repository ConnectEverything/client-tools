CloudFlare
==========

We are paying for the $200/month team for the "get-nats.io" website.

Some notes.

Identifiers are in [cloudflare.conf](cloudflare.conf).

## General Flow

CloudFlare is linked to the client-tools git repository on GitHub, so gets
told about every push, and will auto-deploy.  Deploys are slow to start as it
takes 2 minutes to rebuild the running environment before they even clone the
repo.

We decouple the logic to build the site by running `./cdn-site-build` inside
the repo, which generates `/public` (excluded from git) and the contents of
that are deployed as a CF Pages site, `nats-tools.pages.dev`.

One file within the area is `_redirects`, used so that requests to the root
page issue a redirect to <https://www.synadia.com>.
We can revisit this as needed.

We have a domain `get-nats.io` registered through CF.
In CF DNS, there is an "apex CNAME" (which gets flattened), pointing the
domain at the `nats-tools.pages.dev` site.


### www

There is a rewrite rule in place for `www.get-nats.io` to redirect to `get-nats.io`;
for client traffic to reach the rewrite rule, we need something in DNS.

The `www` entry is an A pointing as CF-proxied to `192.0.2.1`, because as
<https://community.cloudflare.com/t/redirecting-one-domain-to-another/81960>
points out, we don't need a real backend here.

(That's in the documentation/example reserved range.)

So we configure 192.0.2.1 because it acts as a sentinel, we know something is
up when we see it and no backend traffic will flow out from this proxied host;
the **Rules** item for the site has the redirect.

**NOTE WELL**: this means that any curl invocation touching `www` will need
the `-L` option to follow redirects, and we don't specify `-L` by default.


### misc DNS

We enable DNSSEC.

We let CF turn on the "no outbound mail" records.
They were sane and what I was about to do manually.
I added an MX of `0 .` to disable inbound email.
The SRV support isn't flexible enough to let us publish `_client._smtp`.

DNS history is kept via periodic state-dumps in the `ops-info` repository,
in the `StateDumps/DNS/` directory.
See the `dump_cloudflare` script there.


### misc other

* SSL/TLS:
  + Switched encryption from "Flexible" to "Full (Strict)"
    - This affects how CF validates the connection to the origin server.
    - Currently we're hosting entirely on CF so is a no-op, but given that
    - We're serving installable assets and scripts, if that changes then we
      want strict by default unless/until we decide otherwise
  + Edge: enabled "Always use HTTPS"
  + Edge: enabled HSTS, 6 months, not including sub-domains
  + Edge: minimum TLS left on 1.0, the default
    - While NATS itself might be fine with 1.2, we don't know if the people
      installing will be behind corporate proxies, and so while I'm itching
      to change this, I think the risk is high enough that for broadest
      compatibility we leave this alone.
    - When CF change the default, we should roll with it and accept the new
      default
  + Edge: TLS 1.3 (I don't remember if this defaulted on or I enabled it)
  + Edge: CT monitoring, added `pdp+cf-ct@synadia.com` to receive notices

* Network:
  + HTTP/3 enabled
  + WebSockets disabled (not used by us)
  + other settings left on default (HTTP/2 on, IPv6 on, onion on, IP geo on
    (`CF-IPCountry:` header)

* Scrape Shield
  + left all on defaults; the MIME restrictions etc look sane enough


## Credentials

Use API Tokens, **not** API Keys.  The Keys are legacy, per-user, full access.
The tokens are scoped across both actions and targets.

For development use visit <https://dash.cloudflare.com/profile/api-tokens> to
create a token.  I've gone with a token having:

    Synadia Communications - Workers R2 Storage:Edit, Workers KV Storage:Edit

Since R2 storage isn't available without waitlists yet, and wants to know
expected usage in TB, we're _probably_ not using that, but I've scoped my
development to be able to access that just in case.


There doesn't appear to be a fixed standard for what the environment variable
should be called; the CF `wrangler` tool just writes it into
`~/.wrangler/config/default.toml`.  The two common names found in searching
are `CF_API_KEY` and `CLOUDFLARE_AUTH_TOKEN`.  I've gone with
`$CLOUDFLARE_AUTH_TOKEN` for the nightlies script.


A second token with the exact same scopes has been created, and given the name:

    github CE/client-tools secret (for nightlies)

This has been populated into
<https://github.com/ConnectEverything/client-tools/settings/secrets/actions>
as a secret named `CLOUDFLARE_AUTH_TOKEN`.

### Later staff workstation changes

Later, the workstation token was updated to gain new permissions, to manage
the workers and work with the _wrangler_ CLI tool.  These were not applied to
the token configured into GitHub, because the nightly cronjob only needs to
update the KV store.

Added:
 * Account `Workers Scripts:Edit` : to manage the scripts
 * User `User Details:Read` : because Wrangler errors out without this
 * Zone

Result:

```
Synadia Communications - Workers R2 Storage:Edit, Workers KV Storage:Edit, Workers Scripts:Edit
  get-nats.io - Workers Routes:Edit
All users - User Details:Read
```

## KV

Created namespace "client-nightlies".

The nightly build data can thus be seen at:

<https://dash.cloudflare.com/32578e55e8e251552382924d4855e414/workers/kv/namespaces/eb4407c72ba74904b9602a60813a42ee>

To force "current" to go back, in the event of a bad nightly, you can manually
edit the key named `CURRENT` at that URL.


## Workers

Note that there are two contexts in which "Workers" shows up in the left-hand
navigation panel: within a domain, and at the account level.  
To manage routes, we do that within a domain/website.  
To manage the code, we do so at the account level.


Account level, Workers: "Create a Service"  
Named it: `nightlies-serving`
> Your service is now deployed globally at nightlies-serving.synadia.workers.dev

We get one environment to start, named `production`, and I didn't change that.

Three things to do:
 * bind to the KV namespace
 * set up HTTP routes to use in our own domain
 * set up code to route requests to the KV assets

Under `Settings`, `Variables`
<https://dash.cloudflare.com/32578e55e8e251552382924d4855e414/workers/services/view/nightlies-serving/production/settings/bindings>
I bound variable `ASSETS` to KV Namespace `client-nightlies`.
(Can bind multiple variable:KVN so can use other namespaces easily too).

I got the worker running via direct editing inside the browser, instead of
setting up Wrangler management.
The source **was** (but is no longer):

```javascript
addEventListener("fetch", event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  return handleCurrentRequest(request)
}

async function handleCurrentRequest(request) {
  const value = await ASSETS.get("CURRENT", {type: "text"})
  if (value === null) {
    return new Response("Current value not found", {status: 404})
  }

  return new Response(value)
}
```

Then in
<https://dash.cloudflare.com/32578e55e8e251552382924d4855e414/get-nats.io/workers>
I added a route:
 * Route `get-nats.io/nightly/*`
 * Service `nightlies-serving`
 * Environment `production`

At this point, <https://get-nats.io/nightly/current> works.

Then in this repo:

```sh
wrangler generate nightlies-serving \
  https://github.com/cloudflare/worker-typescript-template
```

and then we work on the worker within that area.

The end result, self-contained within the `nightlies-serving/` directory here,
is a node/webpack typescript HTTP handler which can be deployed with
`wrangler publish`.  That will build a service-worker, upload it, and make
sure the routes are correct.

The code in `nightlies-serving/src/handler.ts` pretty much just front-ends
HTTP requests onto the KV store.

