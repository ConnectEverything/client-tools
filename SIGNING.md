Signing Artifacts
=================

In deciding what security measures to add, and what complexity to add to
installers, we need a threat model, which requires understanding what our
current exposure is.

The question is around Object Signing, not Transaction Integrity.  HTTPS
provides transaction integrity, but says nothing about the security of the
objects provided over HTTPS.  Without object signing, there are a lot of
pieces of infrastructure which need to be perfect, to protect the integrity of
the served resources.

With object signing, if an attacker who can modify resources can also use the
object signing key, then performing object signing only provides a fake layer
of protection; if an attacker can automate attacks against unsigned objects
but would need to know how to target our configuration to do the signing, then
the speed bump introduced might still provide some protection, in preventing
mass exploits which include us as incidental victims rather than as direct
targets.

Any signing mechanism needs to consider how the verifier will fetch the
signatures and how the verifier will fetch the public keys used to verify the
signatures.  If the attacker can just use a new signing key and supply its
public key to the script, then again only a fake layer of protection is
provided.  In this scenario, without a federated or trusted-third-party
attestation system for the public keys, the most we can do is to cache the
public keys on disk on the client systems, to have the installer complain
bitterly if they change in future and require intervention to replace them.
(For key-systems with expiration dates, automatic safe updates need to be
considered)

For clarity: this author is generally in favour of signing objects, has setup
cosign signing for container image manifests which get copied around, so this
is definitely not a document against object signing: this is a threat model
document to make sure we understand what signing will and won't do for us in
this repository, to help guide us to choosing the right security approach to
actively make life safer for the people who depend upon us.

In the below, I will refer to `curl | sh` and this should be understood to
include other shells as appropriate, such as PowerShell on Windows.  The
principles are identical.

Many of the sections will not repeat information from previous blocks; this
document should be read as a whole, instead of jumping to sections to see only
issues for that scenario.


## Cryptographic breaks

All public-key cryptography and cryptographic hashes is built around
primitives where the security comes from "as far as we know, there's no
way to reverse this without the key, absent approaches 'not much' better than
brute force".  Over time, flaws are found and cryptographic knowledge
advances.  All cryptographic engineering should be built with an understanding
that there are various deprecation lifecycles in play.

For signatures, usually multiple signatures can be provided.  Some systems
support multiple hash algorithms or signatures in one object and those systems
are usually built with algorithmic agility in mind.  Others, the method to
handle weakness is to just replace the system in-toto.  So we would need to
provide multiple signatures.

Loosely, here that just means to not name files `CHECKSUMS` but instead
`SHA256SUMS`, and to avoid `.sig` or `.asc` without some kind of system/hash
identifier.


## Keyed vs Keyless

There are two types of signing:

 1. Proof of possession of a signing key which has been trusted
 2. Proof via public ledger that some organization was willing to say you had
    an identifier in that organization, at the time of signing

### Keyed

Case 1 is the classic signature system used for decades.  It requires some
framework for introducing the public keys as suitable to be trusted, but once
you have a trust-path and if you trust the secret key management, then the
signatures are fairly absolute.

Verifiers do not need to be able to talk to the network to get details to
validate the signature; if the public key is available locally, then any
artifact signed by that key can be directly verified.

Examples include:
 * Code signing in macOS, Windows, iOS, etc
 * OpenPGP implementations (eg, GnuPG)
 * OpenBSD signify, minisign, etc; cosign with a key
 * The NATS account system's hierarchy
   + The Operator key being tightly restricted, and then Account signing being
     federated out within that.

Keys have to be "owned" by someone and in open source projects there might be
issues around who owns and who can access the signing key.

### Keyless

Case 2 involves generating a transient signing key, getting it signed by
something proving that you're in an organization,  making the signature, and
recording the details in a public ledger.  You no longer have a key to manage
forever, but clients need to be able to talk to the network to verify the
presence in a ledger, or have the public key of a timestamping service.

The "signed by something providing you're in an organization" is a short-lived
identity proof from an OIDC provider, such as Google or GitHub.  This is then
used to get a certificate, and the details are recorded on public transparency
ledgers which provides a timestamping proof that this was done within the
lifetime of the proof.

The only current example here is `cosign`, from the SigStore project.

If the email address is not validated in keyless mode then this becomes
equivalent to verifying a keyed signature against a random public key of
unknown provenance _except_ that the public keys (in certs) are recorded in
public transparency logs.  So if things go wrong, you at least have an audit
trail providing some evidence of how things went wrong.

So just as keyed mode requires a framework for introducing public keys to the
end-users, keyless mode requires a framework for distributing a set of allowed
signers' "email addresses" (which might be a cloud ID for an automated
system).

Ideally, we'd be able to have an OIDC identity from GitHub identifying a build
as part of the Organization owning the repo, so that we could have stable
builds use an identifier clearly saying "nats-io".  That's not there yet.
Should that ability appear, we should reconsider.


## Prior State

Our players are:

 * Maintainer laptop
 * GitHub
   + GitHub Actions
   + GitHub Secrets
   + GitHub Artifact Hosting
 * CloudFlare
   + Serving
   + Page-Building
   + K/V store
 * Clients installing the tools

In addition, long-term valuable signing keys are stored in an
organization-wide password manager, for recovery purposes.  We inherently
trust the administrators of that service to not deliver updates which let them
view the secrets.


### Maintainers / GitHub

No commits to the `client-tools` repo are required to be signed.  All changes
which can be merged to main on GitHub will be made available.

The GitHub permissions model on being able to create branches means that we
allow all of Engineering within Synadia Communications to write to the
repository, but we have a branch protection rule on the `main` branch,
restricting who can merge.

_One future possibility, once the repository is stable enough that changes are
rare, is to switch to requiring signed commits._


### Installer Flow

The `curl -fSs https://get-nats.io/install.sh | sh` flow retrieves a script
and then runs it.

The script retrieves a configuration file, which lays out tools to install and
version numbers thereof; for the nightly channel, it retrieves a tag at a
second URL.  It then fetches the zip files and checksum files, verifies the
checksums, and installs the files.

Every URL accessed directly by the script is HTTPS.  Every URL in the
configuration files _happens to be_ HTTPS, but we don't actively enforce that.

Our script, configuration files, and nightly resources are all on the domain
`get-nats.io`, which is DNSSEC signed and uses HTTPS, both managed by
CloudFlare.

The stable versions are (currently) retrieved from GitHub's CDN, which is
HTTPS but is not using DNSSEC.


### Builder Flow: Static

CloudFlare manage a GitHub integration which provides them with:
 * Read access to code and metadata
 * Read and write access to checks, deployments, and pull requests

As of 2022-02-08, two other "Integrated Apps" on GitHub have access to this
repository and neither permits write access; one is a CI system with all-repo
access to CI-appropriate fields, while the other is a compliance auditing app
with read-only access.  Prior to writing this doc, on this date, another
app had complete read/write access because of overly broad permissions, but it
has been changed to only have access to the specific repositories it is used
with.  The total access rights here can be audited at:
<https://github.com/ConnectEverything/client-tools/settings/installations>

GitHub notifies CloudFlare upon pushes on the main branch, and CloudFlare
initiates a Pages build.  That build clones the repository and runs scripts
within the repository.

Both GitHub and CloudFlare are configured to require two-factor authentication
for all members within the respective organizations/accounts; this is not a
panacea but does limit how stolen credentials can be used (unless credentials
are stolen from a laptop password manager which also holds TOTP secrets).

Contents can be tampered with:
 * By people who can convince GitHub to let them merge to main
 * Social engineering or other confusion attacks on maintainers who can merge
   to main
 * By people authorized to merge to main
 * By exploiting a GitHub weakness allowing adding commits to a repo
 * By people within GitHub who can access repository contents to mutate them
 * By people who can log into CloudFlare in our account
 * By people within CloudFlare who can tamper with the build images
 * By people within CloudFlare who can tamper with the Pages build system
 * By exploiting a CloudFlare weakness allowing administrative access

The served items here are the installer script and the configuration file in
its multiple formats.

The requirement for a `curl | sh` installer to just work means that a
signature on the installer itself would be too late.  In that context, a
signature upon the configuration file would gain nothing, as the installer
could just be modified instead.

A valid stance is to tell people they can download the installer, and verify
it by inspection, and by checking object signatures.  If we do that, then the
configuration file should be signed too.  If we use a trust-on-first-use
system, then installing the public keys locally on first use could be used to
better protect later upgrades.

If the signing keys for object signatures are used on repo maintainer laptops
then we have a propagation and control issue, plus a revocation issue.
Long-term persistent keys which end-users should trust should not have their
private parts freely copyable by any NATS Developer.

I don't think we can hook into GitHub in such a way as to run before
deployment to CloudFlare: they get notified immediately upon push.  So we
can't do the signing inside GitHub.  (We have no visibility into ordering
guarantees or controls here)

If we sign within CloudFlare, then we could put the signing key into an
environment variable, shown to all CF users (so not secret) or put it into a
KV namespace, using a second namespace and making it available for publishing.
Again, this does not protect against disclosure.

CloudFlare has a secrets system, but it's only available to Workers, not to
site build.

Thus any system which can sign objects inside CF would result in secrets being
not very secret.  We get the most mileage if we can move the secret signing
into a GitHub Action, which still has some people able to tamper, but not so
many and the secret is ingress-only, unless someone takes deliberate steps to
expose it from the Action's steps.

This appears to present another argument in favor of removing the
CloudFlare Pages flow from our deployments and instead using a GitHub Action
triggered by push-to-main, which updates entries in CF KV store, much like the
nightly builds do.

Against that, by keeping the install script served without GitHub Actions in
the path, and putting public keys inside the install script, we can avoid
having a compromise of GitHub Actions also change the keys to be verified.

For GitHub Actions, note <https://github.com/security> and their audit
compliance programs.  (Disclosure: I haven't read through to see what they do
and don't claim here, I'm just vaguely waving my hand in the direction of the
big well-funded company with dedicated security staff and security compliance
processes and massive government contracts to lose if they mislead).


### Builder Flow: Nightlies

A GitHub Action scheduled job, also registered to be runnable on explicit
trigger, invokes `build-nightlies.sh`.  This uses Secrets registered in
GitHub: `$GORELEASER_KEY` and `$CLOUDFLARE_AUTH_TOKEN`.

The `GORELEASER_KEY` variable is because we support the developer of that
software by paying for a licensed version; we do not use any of the advanced
features unlocked by that.

The `CLOUDFLARE_AUTH_TOKEN` variable, per [CLOUDFLARE.md][CLOUDFLARE.md],
provides edit access to Workers KV Storage (and R2, for a hypothetical future
approach).  This might be bound to the human account of the person who set it
up, rather than to our paid entity (Synadia Communications), this is unclear.
This grants access to _all_ KV namespaces within the account: I have been
unable to find a way to restrict a token to one particular KV namespace.

The build script lightly clones the repositories it needs; these are currently
only open source repositories, so no special permissions are needed.
_(We expose `$GITHUB_TOKEN` from the auto-generated one but that doesn't really
help with access to other repositories, since at this time there are no
organization-scoped access rules.  To build from private repositories, we will
need to add a Deploy Key for accessing that repository, and register the
secret half of that as a secret in our repo, and then load the SSH key before
cloning.)_

The build flow creates the binaries using `goreleaser` in snapshot mode, then
manually zips up the results.  When it's done, it generates checksum files and
then uploads into CloudFlare KV store as objects with a two-week TTL.

In this flow, we still serve through the same path as for the static files, so
the same threats are present.  But importantly, the secrets are configured in
a system designed to only release them to the action runner, under
configuration control.  It's still _possible_ to retrieve it via malicious
runner, but that leaves audit traces.

We thus don't need staff to be able to routinely see the secret.
With a signing secret stored in GitHub Actions we reduce the threat to:

 * People who can get actively malicious code merged to main and then invoke
   the action (manually, or wait)
 * People who can access the password store for emergency recovery
 * Insider-attack within GitHub, against secret store or against the action
   runner framework

If the secret is stored at the Organization level, then it could be used in
multiple repositories and so breached by another repo, but a control on the
secret to only be visible to specific repos solves that.


### External flow: stable builds

The stable builds are not built within this repository.  
The stable builds are currently served directly from GitHub's CDN, but this is
entirely under the control of the channel configuration file, which is served
through CloudFlare.

At present, neither nats-io/natscli nor nats-io/nsc provides signatures.
Both are manual upload of artifacts by the person performing the release.
Any release signing in the current workflow would protect us against
compromise of CloudFlare or GitHub, but leave us open to issues of private key
proliferation, as discussed above for the static site flow.

Moving the release file preparation, and signing, to be done within CI builds
in GitHub moves us to instead trusting GitHub (again, as discussed above).


## Container Images

In practice, signing container images ("OCI images" or "docker images" or
whichever other variant) involves signing the _manifest_, rather than the
image itself.  In order to retrieve these and keep copies, use tools such as
[crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane.md)
instead of regular container runner command-lines.

For these, the signatures can either be based on keys, or be keyless per the
above description.  Either we distribute keys or we distribute email
identifiers.


## Object Signing Technologies

_TODO: include key rolling in here_

### cosign

 * Can sign files and OCI manifests (Docker)
 * Defaults to keyed operation
   + we use this for a private variant build of the nats-server already
     - we generated a key, and stored it in GitHub Secrets and 1Password, and
       provided the public key to the consumers of that build
 * Requires that `COSIGN_EXPERIMENTAL` be in the environment with a non-empty
   value to enable keyless
 * Verifies that signatures exist
 * can be given one email address to check the signatures for
   + it's unclear if this requires "one valid signature from this email" or
     "all must be from this email"; for our use-case, we want the former
 * Issues certs from `sigstore.dev`
 * Each outer signature has a payload body which is base64-encoding of a
   `rekord` JSON object, carrying a signature and a "public key"; the latter
   is a base64-encoding of the PEM form of an X509 cert from sigstore.dev,
   with an empty Subject and the email address in the SAN

 * Is not currently widely installed, but in the container ecosystem that will
   probably change
 * Of all the systems listed here, is the only one which can be used to
   sign/verify OCI/Docker manifests

 * In keyless mode, we need to convey the valid email address forms which the
   installation tool should verify
 * In keyed mode, we need to somehow bundle the public key in with the
   installer.
 * cosign/keyless is not designed for signing private artifacts, all
   signatures are considered public, together with the email identifier
 * Verifying a keyless signature (roughly) requires network connectivity

### signify / minisign / friends

These tend to be Ed25519 signatures, as detached items for file assets.  They
don't support Docker.

In effect, they are equivalent to cosign in keyed mode.

Only widely installed on OpenBSD.

### openssl

Just as you can use cosign/signify and distribute public keys, we could make a
private/public keypair in openssl and use `openssl sha256 -sign` to create a
detached signature.

The only thing in favor of this approach is that OpenSSL is nearly universal
and some variant will likely be installed.  Unfortunately, that might be a
very old variant or missing modern key types.  We'd probably end up back in
the land of RSA4096 keys.

### OpenPGP

A swiss-army knife which lets you build secure systems, but with many sharp
edges at unexpected angles.  It is possibly to use modern cryptographic
primitives with OpenPGP, but many people using it deliberately choose to use
an implementation which is two decades out of date and complain bitterly if
you require modern systems (but then complain that PGP is dated).

The most widespread implementation is the GnuPG suite, with the `gpg`
command-line tool, with a UX designed to be compatible with the original `pgp`
command and which is not winning any usability awards.

OpenPGP is used broadly in the open source community, from signing apt
repositories to signing release artifacts, signing git tags, and more.

GnuPG 1 should be avoided.  But we should equally be aware that if we pick
OpenPGP because of the broad support then some people will complain bitterly
if we don't support it.  We should not support it: it does not support
table-stakes basic modern cryptographic primitives.

One advantage of OpenPGP is that we can set up trust-paths to the key; while
the Web-of-Trust requires effort to set up, and some modern keyservers drop
those signatures, the WKD federated key distribution system works and we have
this setup for the `nats.io` domain.

### ssh-keygen -Y sign

OpenSSH 8.0 and newer support signing objects, such as files.  Support for
this has recently been added to git for signed objects (tags and/or commits),
as an alternative to OpenPGP.

Version 8.0 was released 2019-04-17.  So while SSH is nearly universal, we can
not rely upon SSH signed objects in all currently supported OS variants.

OpenSSH makes it easy to create modern ed25519 keys, and those are supported
in just about any variant we need to worry about, so if we want broader
support on "Ubuntu 20.04 or newer OSes" then this is a viable path to explore.


## Recommendations

1. Where developers generate signatures locally, for releases, and we don't
   already have a signature system in place (or are willing to add a second),
   we should consider cosign/keyless, if and only if we want that developer's
   nats.io email identifier hard-baked into public records.
2. We should try to sign inside GitHub Actions, not CloudFlare and probably
   not on developer machines, but as part of CI/CD automated builds upon tag
   push.
3. cosign should be used; for now, in keyed mode, but strongly considering
   keyless for the future, or now for signatures outside of GHA.
4. ssh-keygen signatures should be used, with ed25519
5. Separate keys for nightlies vs tools, and separate keys for each released
   tool (but one key for all nightlies).
6. Put the public keys inside the installer script.
7. For release artifacts, sign the checksum file.
   + rename cosign `$FILE.sig` to `$FILE.cosign.sig`
   + rename ssh `$FILE.sig` to `$FILE.ssh-ed25519.sig`
