NATS Client Tools Security Policy
=================================

This repository contains an installer for the open source NATS client tools,
and manages nightly builds by Synadia of those tools, for use by that
installer.

So that you know who you're talking to:

 * NATS is an open source project under CNCF aegis
 * Synadia Communications, Inc are the primary developers of NATS
 * `ConnectEverything` is the GitHub Organization of Synadia Communications

The open source tools are:

 1. nats: <https://github.com/nats-io/natscli>
 2. nsc: <https://github.com/nats-io/nsc>

The security policy for _those tools_, together with past advisories, etc can
be found at:

  <https://advisories.nats.io/>

If you use the GitHub private reporting on _this_ repository, for an open
source tool, then the maintainers here will route your request to the right
people, but it's not ideal.

## Email

#### Address

 1. Open Source: <mailto:security@nats.io>
 2. Synadia: <mailto:security@synadia.com>

(As an implementation detail, they might happen to be the same thing.)


#### Email Security

 * Both `synadia.com` and `nats.io` can safely be configured in your
   mail-systems to coerce TLS.
 * Most folks reading that list do not use OpenPGP.  If you believe that the
   use of OpenPGP is warranted, then, since security@ is a non-reencrypting
   mailing-list (sorry)
   + Reach out to find who will take your report
   + Both domains have WKD set up to provide OpenPGP keys via a trusted path


## This Repo

In this repository,
[client-tools](https://github.com/ConnectEverything/client-tools),
you will find:

 1. An installer script for end-users to run on their machines
    1. `install.sh` for POSIX-ish systems
    1. `install.ps1` for Windows systems
 1. Copies of the public keys used to sign artifacts
 1. The configuration which creates nightly builds of the open source tools
 1. The website framework for `get-nats.io`
 1. Example completion files and shell configuration for zsh

Any of the things specific to this repository can and should be reported to
Synadia.

You can use the private-report functionality of this repo, or the mailing-list
above, at your discretion.


## Bounties

At this time, there is no bug bounty system in place for either
Synadia or NATS.

If you'd like some swag, we can happily oblige.

