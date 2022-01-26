Client Tools
============

This git repository holds build scripts and installers for client tools, as a
unified approach replacing the old nsc+ngs+nats installers.

The nsc installer for open source remains in place.

Our goal is to create assets with a reliable installer, following one of two
channels: "nightles", "stable".

Our model: a "channels" file in this repository, defining the two, where the
"stable" needs to be edited when we want to cut a new stable release, and a
GitHub Actions integration does nightlies from cron and a stable upon an
explicit action.

The installer has to be able to work with minimal dependencies, so the
channels file does not use JSON.  Instead, everything is KEY=VALUE, one per
line, as straight shell (but not sourced as such, for security reasons).

To handle synchronizing the time of the nightly with availability, and not
pointing to invalid nightlies after a failed build, we publish a simple
nightly version file to the CDN too.


