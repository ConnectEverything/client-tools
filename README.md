Client Tools
============

```sh
curl -fSs https://get-nats.io/install.sh | sh
```

This git repository holds build scripts and installers for client tools, as a
unified approach replacing the old nsc+ngs+nats installers.
(For now, we do not install ngs, per instruction from Derek.)

The nsc installer for open source remains in place.

Our goal is to create assets with a reliable installer, following one of two
channels: "nightly", "stable".

Our model: a "channels" file in this repository, defining the two, where the
"stable" needs to be edited when we want to cut a new stable release, and a
GitHub Actions integration does nightlies from cron and a stable upon an
explicit action.

The installer has to be able to work with minimal dependencies, so the
channels file does not use JSON.  Instead, everything is KEY=VALUE, one per
line, as straight shell (but not sourced as such, for security reasons).
We do make JSON files too, for ease of use by other installers.

To handle synchronizing the time of the nightly with availability, and not
pointing to invalid nightlies after a failed build, we publish a simple
nightly version file to the CDN too.


## Deploy on: push

The script `cdn-site-build` is run by CloudFlare to build content to
include as the static site contents.  That script uses `cdn-files.txt` to list
which files from this repo to make available.  It's deliberately very simple,
no renaming, no processing, just copying into a new tree.
It does invoke `make-json-files` for some extra work though.

The glue is that CF is told
 1. run this command
 2. deploy this sub-directory

So if we change the command, we can do whatever we want.
There is no `.sh` suffix on the command, so it can be rewritten in whatever
language makes sense and we can do more.

* <https://developers.cloudflare.com/pages/framework-guides/deploy-anything>
* <https://developers.cloudflare.com/pages/platform/build-configuration>

### View Deployment Status

Visit <https://dash.cloudflare.com/32578e55e8e251552382924d4855e414/pages/view/nats-tools>


## Deploy on: cron

The file `.github/workflows/nightly.yaml` manages a daily invocation of the
script `build-nightlies.sh`.

The script checks out a "pretty shallow" clone of the nsc and nats repos, and
runs `goreleaser build --snapshot --rm-dist` to build the binaries.  Once that
has successfully completed, it creates ZIP files of all of them and creates a
checksum file, with both the zips and the checksum having today's date as part
of the filename.

These are then uploaded to a CloudFlare KV namespace and, when done, the KV
entry for `CURRENT` is updated to refer to the date put into the scripts.

There is an account-level authentication token granting minimal sufficient
privileges for this, in CloudFlare, which is populated as a GitHub Secret on
this repo.

Clients can then pull <https://get-nats.io/current-nightly> to get the version
string to use as a datestamp, referring to the last successfully uploaded
version of the nightlies.

The nightly assets are given a two week TTL in CF's KV store, so will
automatically expire after two weeks.

We include `SHA256SUMS-${YYYYMMDD}.txt` and `COMMITS-${YYYYMMDD}.txt` as
assets for each nightly build.  We expect the installer to use the former.
Nothing uses the COMMITS file (yet); it's simply a record of what git commit
each tool repo was at, when that nightly build was made.

### View Deployment Status

Visit <https://github.com/ConnectEverything/client-tools/actions/workflows/nightly.yaml>


## CloudFlare Workers Site

See [CLOUDFLARE.md](CLOUDFLARE.md) for documentation on the setup of
CloudFlare.

The nightly assets, and a bit more, live in a KV Namespace bound into our
`get-nats.io` site.

You will need the Wrangler CLI tool, and credentials.  For credentials, you
can use a token as Phil setup (see the README) or just give Wrangler your
account credentials.

```sh
cargo install wrangler
wrangler login
```

Then to deploy the site:

```sh
cd nightlies-serving
wrangler publish
```

The site is small enough and the end-points well-enough defined that we could
consider switching to a language which compiles down to WASM if we want.


## get-nats.io overview

So in the end:

1. `get-nats.io` is registered through CloudFlare and entirely hosted there
2. The files inside this repo, listed in the file `cdn-files.txt`, are
   uploaded to a static site in CloudFlare on every git push.  This includes
   the shell installer and the channel definitions file, including the current
   version numbers of the released tools.
   + The release assets are currently served straight from GitHub
   + The `_redirects` file controls where people who visit
     <https://get-nats.io/> in a browser are sent.
3. The GitHub Action inside this repo builds assets every day and uploads
   those to a KV namespace in CloudFlare; these are the "nightlies"
4. CF maps `get-nats.io/nightly/*` and `get-nats.io/current-nightly` to be
   served from the KV store
   + One currently nightly version exists, across all tools
   + For consistency, there are still separate zip files, one for each tool
   + `SHA256SUMS-${YYYYMMDD}.txt` has checksums for all the zip files of that night
   + `COMMITS-${YYYYMMDD}.txt` records which commit each tool was built at
     - `curl https://get-nats.io/nightly/COMMITS-20220203.txt`

The end-user runs:

```sh
curl -fSs https://get-nats.io/install.sh | sh
```

Alternatively, the end-user runs:

```sh
curl -O https://get-nats.io/install.sh
less install.sh
chmod -v +x ./install.sh
./install.sh -h
./install.sh -c nightly -f
# use nats nightly a bit, then switch back:
./install.sh -c stable -f
```

The channel is persisted on disk locally and future runs will remain in the
same channel.

### Monitoring

We have monitoring in Checkly which retrieves the
<https://get-nats.io/current-nightly> URL and checks that it's "not too old",
so if we lose more than a couple of builds then alerts will fire and let us
know.

If it hasn't been recreated, then the monitoring history should be visible at:
<https://app.checklyhq.com/checks/305ea176-b06d-436a-8d8f-f49f53168ed7/>


## Installer API

An installer needs to be able to fetch:

 1. <https://get-nats.io/synadia-nats-channels.conf>
    + Variants possible, see below
 2. <https://get-nats.io/current-nightly>

and to write the current channel out to `~/.config/nats/install-channel.txt`
(as perhaps modified by ADR-22).

On start-up, if `~/.config/nats/install-channel.txt` exists then it should be
read and parsed and used as the _default_ NATS channel, unless explicitly
overridden.

The `synadia-nats-channels.conf` file was created for the needs of a shell
script which could not rely upon JSON handling tools being available.  We
fully expect that other installers would prefer this data be available in
other formats.  That's easy to arrange: we just need to decide on a schema and
the level of normalization to do in creating something better for tools.  As
long as interpolation still needs to happen in the results, we probably
shouldn't expand it too much.  We can change the interpolation markup in the
new file to whatever is easiest to handle in the programming language
involved.  **See below, under "Experimental JSON Files"**

To make new data formats for the channels information, add the conversion into
the `cdn-site-build` script so that the CF site builder will automatically
make the extra file when GitHub notifies it of the site push.
This should not require removing the existing `.conf` file: it remains in use
for the shell installer.  We can make 30 different config files from the same
source, if need be.
The `cdn-site-build` script is currently as simple as it can be, to make it
"very unlikely to break" as CloudFlare updates the execution environment of
site builders; or if we move to a different CDN.
But, unlike the installers which run on whatever system end-users are running,
we can depend upon more tools, as we think makes sense.

The `synadia-nats-channels.conf` file defines both which channels exist and
which tools exist.  An installer needs to special-case the channel `nightly`
to have a version number _not_ supplied by the config file.

Because we don't know what `date` will return for someone in a given place on
the planet, and because we want to continue serving "the last successful
build" if a nightly build fails, an installer **MUST NOT** just use "today's
date" as the nightly version.  An installer **MUST** fetch
<https://get-nats.io/current-nightly> and extract the date from the single
POSIX text line contained in that ASCII file.

```sh
curl -fSs https://get-nats.io/current-nightly | \
  hexdump -ve '10/1 "%02X " "  : "' -e '10/1 "%_c""\n"'
```

Running that might yield results like:

```
32 30 32 32 30 32 30 33 0A     : 20220203\n
```

in which case the version to use _for the nightly channel_ would be
`20220203`, even if today's date were `20220210`.  This version would then be
`%VERSIONTAG%` (and `%VERSIONNOV%`) for the interpolations.

The `synadia-nats-channels.conf` defines at the end
`ZIPFILE_{channel}_{toolname}` and `CHECKSUMS_{channel}_{toolname}` for each
combination, and then `URLDIR_{channel}_{toolname}`.

The installer should fetch both the zipfile and the checksums file from that
URL directory (separate with `/`) and then verify the zipfile, before
installing to a location which makes sense for this platform.


## Experimental JSON Files

The site build will invoke `make-json-files`.  
This first experimental version was thrown together quickly in bash, using
logic from `install.sh` but taking advantage of arrays.
It's a bit slow, repeatedly invoking `jq` to slowly build a data string to
write out.
This can be rewritten and adjusted as we figure out what's needed.

We make two files: one is a straight reformatting of the current data, to be
expanded in the same way, without needing janky parsing of files.  The other
expands the data out so that for the non-nightly case there are direct URLs
which can be used, and in the nightly case there's a single substitution
needed.

### `synadia-nats-channels.json`

<https://get-nats.io/synadia-nats-channels.json>

The `synadia-nats-channels.json` file is a straight restatement of
`synadia-nats-channels.conf` but in JSON format.
The result looks something like:

```json
{
  "stable": {
    "nats": {
      "zipfile": "nats-%VERSIONNOV%-%OSNAME%-%GOARCH%.zip",
      "checksumfile": "SHA256SUMS",
      "urldir": "https://github.com/nats-io/natscli/releases/download/%VERSIONTAG%/",
      "version": "v0.0.28"
    },
    "nsc": {
      "zipfile": "nsc-%OSNAME%-%GOARCH%.zip",
      "checksumfile": "nsc-checksums.txt",
      "urldir": "https://github.com/nats-io/nsc/releases/download/%VERSIONTAG%/",
      "version": "2.6.1"
    }
  },
  "nightly": {
    "version_url": "https://get-nats.io/current-nightly",
    "nats": {
      "zipfile": "nats-%VERSIONNOV%-%OSNAME%-%GOARCH%.zip",
      "checksumfile": "SHA256SUMS-%VERSIONNOV%.txt",
      "urldir": "https://get-nats.io/nightly/"
    },
    "nsc": {
      "zipfile": "nsc-%VERSIONNOV%-%OSNAME%-%GOARCH%.zip",
      "checksumfile": "SHA256SUMS-%VERSIONNOV%.txt",
      "urldir": "https://get-nats.io/nightly/"
    }
  }
}
```

### `synadia-nats-platforms.json`

<https://get-nats.io/synadia-nats-platforms.json>

The `synadia-nats-platforms.json` file again has top-level keys of the channel
name, but then there's a second-level key of `platforms`, which is a map
containing an entry for each of a pre-canned list of platforms.

For any channel which is not "nightly", the URLs within are absolute and can
be retrieved as-is.
For the nightly channel, the direct key (sibling to `platforms`) of
`version_url` contains the URL documented above, and all the URLs to be
retrieved contain a single pattern of `%NIGHTLY%` to be replaced.

We can swap out `%NIGHTLY%` with whatever syntax is easiest to work with.

An abbreviated example, keeping only one platform per channel for this README,
is:

```json
{
  "stable": {
    "platforms": {
      "darwin-amd64": {
        "tools": {
          "nats": {
            "executable": "nats",
            "zip_url": "https://github.com/nats-io/natscli/releases/download/v0.0.28/nats-0.0.28-darwin-amd64.zip",
            "checksum_url": "https://github.com/nats-io/natscli/releases/download/v0.0.28/SHA256SUMS"
          },
          "nsc": {
            "executable": "nsc",
            "zip_url": "https://github.com/nats-io/nsc/releases/download/2.6.1/nsc-darwin-amd64.zip",
            "checksum_url": "https://github.com/nats-io/nsc/releases/download/2.6.1/nsc-checksums.txt"
          }
        }
      }
    }
  },
  "nightly": {
    "version_url": "https://get-nats.io/current-nightly",
    "platforms": {
      "windows-arm64": {
        "tools": {
          "nats": {
            "executable": "nats.exe",
            "zip_url": "https://get-nats.io/nightly/nats-%NIGHTLY%-windows-arm64.zip",
            "checksum_url": "https://get-nats.io/nightly/SHA256SUMS-%NIGHTLY%.txt"
          },
          "nsc": {
            "executable": "nsc.exe",
            "zip_url": "https://get-nats.io/nightly/nsc-%NIGHTLY%-windows-arm64.zip",
            "checksum_url": "https://get-nats.io/nightly/SHA256SUMS-%NIGHTLY%.txt"
          }
        }
      }
    }
  }
}
```



