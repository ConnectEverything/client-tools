#!/bin/sh
# shellcheck disable=SC3043,SC2237

set -eu

# Copyright 2020-2022 The NATS Authors
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This is an installer script for client tools for the NATS.io ecosystem.
# By default, we install binaries to ~/.local/bin (per XDG), unless
# invoked as root, in which case we install to /usr/local/bin.
# Invoke with -h to see help.

# We are sh, not bash; we might want bash/zsh for associative arrays but some
# OSes are currently on bash3 and removing bash, while we don't want a zsh
# dependency; so we're sticking to "pretty portable shell" even if it's a
# little more convoluted as a result.
#
# We rely upon the following beyond basic POSIX shell:
#  1. A  `local`  command (built-in to shell; almost all sh does have this)
#  2. A  `curl`   command (to download files)
#  3. An `unzip`  command (to extract content from .zip files)
#  4. A  `mktemp` command (to stage a downloaded zip-file)
#  5. A tool to verify checksums; any of: openssl, shasum, sha256sum, etc
#
# We do not use JSON because we can't depend upon any particular tools for
# parsing it for channel updates.
#
# We require various tools mandated by POSIX, such as `uname`, `sed`, etc.

# Shellcheck:
#   SC2064: we are deliberately expanding the trap string at set time
#   SC2237: I've too many memories of [ -z "..." ] not being available,
#           so am sticking with negated -n
#   SC3043: we use `local`.  It's a known portability limitation but it's sane.
#
# Based on knowledge that we won't put non-ASCII, quotes,
# or internal whitespace into our channel files, we'll use:
#   SC2018/SC2019: we're using ASCII for our artifacts and OS/arch names
#   SC2086: we're using space-delimited arrays-in-strings, not ksh-ish arrays
#           (oh how we wish general shell arrays could be assumed available)

# This location is temporary during development, we will have a better name
# when we pick one, but this lets me get started with integration on the free
# tier and figure out the moving pieces
#
# The CHANNELS_URL is the file defining current versions of stuff, and is edited
# by humans and deployed
readonly CHANNELS_URL='https://get-nats.io/synadia-nats-channels.conf'
# The NIGHTLY_URL is expected to be edited as a result of GitHub Actions cron-jobs,
# updating the current version as a simple .txt file (containing YYYYMMDD) on
# successful builds.
readonly NIGHTLY_URL='https://get-nats.io/current-nightly'

readonly HTTP_USER_AGENT='synadia_install/0.3 (@ConnectEverything)'

# This is a list of the architectures we support, which should be listed in
# the Go architecture naming format.
# When we add 32-bit arm, the 6 or 7 GOARM gets included here
readonly SUPPORTED_ARCHS="amd64 arm64"
# This is a list of the known OSes, to validate user input
readonly SUPPORTED_OSTYPES="linux darwin freebsd windows"

# Where to install to, by default
: "${HOME:=/home/$(id -un)}"
readonly DEFAULT_USER_BINARY_INSTALL_DIR="$HOME/.local/bin"
readonly DEFAULT_ROOT_BINARY_INSTALL_DIR="/usr/local/bin"
readonly DEFAULT_NATS_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/nats"

readonly COMPLETION_ZSH_NATS_URL='https://get-nats.io/zsh.complete.nats'
readonly ZSH_EXTRA_SETUP_URL='https://get-nats.io/zshrc'

# Shell variables referenced below as optional:
#  SECRET -- used for loading an account generated elsewhere
#  NSC_OPERATOR_NAME -- used to override the operator when using $SECRET loading

if [ "$(id -u)" -eq "0" ]; then
  readonly DEFAULT_BINARY_INSTALL_DIR="$DEFAULT_ROOT_BINARY_INSTALL_DIR"
else
  readonly DEFAULT_BINARY_INSTALL_DIR="$DEFAULT_USER_BINARY_INSTALL_DIR"
fi

### END OF CONFIGURATION ###

progname="$(basename "$0" .sh)"
note() { printf >&2 '%s: %s\n' "$progname" "$*"; }
die() { note "$@"; exit 1; }

# Handle the "pipe to shell" pattern
case "$progname" in
  sh | bash | ksh | zsh | dash)
    progname="nats-install"
    ;;
esac

main() {
  parse_options "$@"

  # error early if missing commands; put it after option processing
  # so that if we need to, we can add options to handle alternatives.
  check_have_external_commands

  # We do not chdir to the tmp_dir, because the caller can provide
  # command-line flags with paths to files which might be relative,
  # and normalizing those in truly portable shell is iffy.

  setup_tmp_dir

  extract_previous_channel

  fetch_and_parse_channels

  fetch_and_validate_files

  install_files

  store_channel

  write_completions

  show_instructions

  load_context
}

usage() {
  local ev="${1:-1}"
  [ "$ev" = 0 ] || exec >&2
  cat <<EOUSAGE
Usage: $progname [-fqv] [-c <channel>] [-d <dir>] [-C <dir>] [-a <arch>] [-o <ostype>]
 -f           force, don't prompt before installing over files
              (if the script is piped in on stdin, force will be forced on)
 -v           be more verbose
 -q           be more quiet
 -c channel   channel to install ("stable", "nightly")
 -d dir       directory to download into [default: $DEFAULT_BINARY_INSTALL_DIR]
 -C configdir directory to keep configs in [default: $DEFAULT_NATS_CONFIG_DIR]
 -o ostype    override the OS detection [allowed: $SUPPORTED_OSTYPES]
 -a arch      force choosing a specific processor architecture [allowed: $SUPPORTED_ARCHS]
EOUSAGE
# Developer only, not documented in help:
#  -F chanfile  use a local channel file instead of the hosted URL
  exit "$ev"
}

VERBOSE=1
opt_install_dir=''
opt_config_dir=''
opt_channel=''
opt_channel_file=''
opt_nightly_date=''
opt_arch=''
opt_ostype=''
opt_force=false
nsc_env_secret="${SECRET:-}"
nsc_env_operator_name="${NSC_OPERATOR_NAME:-synadia}"
parse_options() {
  while getopts ':a:c:d:fho:qvC:F:N:' arg; do
    case "$arg" in
      (h) usage 0 ;;

      (a)
        if validate_arch "$OPTARG"; then
          opt_arch="$OPTARG"
        else
          die "unsupported arch for -a, try one of: $SUPPORTED_ARCHS"
        fi ;;

      (c) opt_channel="$OPTARG" ;;
      (d) opt_install_dir="$OPTARG" ;;
      (f) opt_force=true ;;
      (o) opt_ostype="$OPTARG" ;;
      (q) VERBOSE=$(( VERBOSE - 1 )) ;;
      (v) VERBOSE=$(( VERBOSE + 1 )) ;;
      (C) opt_config_dir="$OPTARG" ;;
      (F) opt_channel_file="$OPTARG" ;;
      (N) opt_nightly_date="$OPTARG" ;;

      (:) die "missing required option for -$OPTARG; see -h for help" ;;
      (\?) die "unknown option -$OPTARG; see -h for help" ;;
      (*) die "unhandled option -$arg; CODE BUG" ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ $# -gt 0 ]; then
    note "WARNING: all directives are parameters to flag, something was ignored"
  fi

  if [ "$opt_install_dir" = "" ]; then
    opt_install_dir="${DEFAULT_BINARY_INSTALL_DIR:?}"
  fi
  if [ "$opt_config_dir" = "" ]; then
    opt_config_dir="${DEFAULT_NATS_CONFIG_DIR:?}"
  fi
  if ! [ -t 0 ]; then
    # we won't be able to prompt the user; curl|sh pattern
    opt_force=true
  fi
  if [ -n "${SECRET:-}" ]; then
    # in nsc load mode, there's enough later important things that
    # we want to be quieter early on; this is an issue at the intersection of
    # style/taste and usability.
    VERBOSE=$(( VERBOSE - 1 ))
  fi
}

have_command() { command -v "$1" >/dev/null; }

check_have_external_commands() {
  local cmd
  local considered_list=''

  # These are so essential we fail without them.
  # nb: xargs is part of POSIX and should always be available,
  #     but Fedora docker images omit it, but we worked around its absence
  for cmd in curl unzip
  do
    have_command "$cmd" || die "missing command: $cmd"
  done

  # Our invocation of mktemp has to handle multiple variants; if that's not
  # installed, let it fail later.
  # PORTABILITY ISSUE: WINDOWS?
  test -e /dev/stdin || die "missing device /dev/stdin"

  if have_command install; then
    # Busybox limits flags to: -c -d -D -s -p -o -g -m -t
    # FreeBSD does not have -T
    if ( install --help 2>&1 || true ) | grep -qs -- --no-target-directory ; then
      install_force() { command install -bTv "$1" "$2/${1##*/}"; }
    elif ( install --help 2>&1 || true ) | grep -qs -- '-T tags' ; then
      install_force() { command install -bv "$1" "$2/${1##*/}"; }
    else
      install_force() { command install "$1" "$2/${1##*/}"; }
    fi
    install_prompt_overwrite() { mv -i -- "$1" "$2/"; }
  else
    install_force() { mv -f -- "$1" "$2/"; }
    install_prompt_overwrite() { mv -i -- "$1" "$2/"; }
  fi

  # After this point, we exit as soon as we find a valid means to verify a
  # checksums file.
  # The --ignore-missing flag to sha256sum and friends is _fairly_ portable,
  # but we always know exactly which file we want and we need the framework
  # to support other checker commands, so we always extract the entry from
  # the checksums file and individually check it.

  if have_command openssl; then
    # nb: using '--' to stop the arguments is "more correct", but older versions of OpenSSL do not support it,
    # and the default openssl on macOS is one such.
    checksum_one_binary() { local cs; cs="$(openssl dgst -r -sha256 "$1")"; printf '%s\n' "${cs%% *}"; }
    note "using openssl for checksum verification"
    return
  fi
  considered_list="${considered_list} openssl"

  for cmd in sha256sum gsha256sum; do
    # Busybox has -c but not --check, and emits to stderr on --help
    # It doesn't have a binary-mode flag, so we'll handle that next.
    if have_command "$cmd" && "$cmd" --help 2>&1 | grep -qs -- --check ; then
      eval "checksum_one_binary() { local cs; cs=\"\$(${cmd} --binary \"\$1\")\"; printf '%s\n' \"\${cs%% *}\"; }"
      note "using $cmd for checksum verification"
      return
    fi
    considered_list="${considered_list} $cmd"
  done
  if have_command sha256sum && sha256sum --help 2>&1 | grep -q -- -c ; then
    checksum_one_binary() { cs="$(sha256sum < "$1")"; printf '%s\n' "${cs%% *}"; }
    note "using sha256sum (BusyBox-ish) for checksum verification"
    return
  fi

  for cmd in shasum gshasum; do
    if have_command "$cmd" && "$cmd" --help | grep -qs -- '--algorithm.*256' ; then
      eval "checksum_one_binary() { local cs; cs=\"\$(${cmd} --algorithm 256 --binary \"\$1\")\"; printf '%s\n' \"\${cs%% *}\"; }"
      note "using $cmd for checksum verification"
      return
    fi
    considered_list="${considered_list} $cmd"
  done

  if have_command sha256; then
    # BSDish
    checksum_one_binary() { sha256 -q "$1"; }
    note "using sha256 for checksum verification"
    return
  fi
  considered_list="${considered_list} sha256"

  if have_command digest; then
    # Certain SVR4 heritage systems; but do we even support these?
    checksum_one_binary() { digest -a sha256 "$1"; }
    note "using digest(1) for checksum verification"
    return
  fi
  considered_list="${considered_list} digest"

  note "looked for:$considered_list"
  die "unable to find a means to verify checksums; please report this"
}

checksum_for_file_entry() {
  local sumfile="${1:?need a checksum file to extract from}"
  local entryname="${2:?need a filename to extract from checksum file}"
  local needle found
  # our entries will be "safe" for regular expressions, except for . being a metacharacter
  needle="$(printf '%s\n' "$entryname" | sed 's/\./\\./')"
  found="$(sed -ne "s/ .${needle}\$//p" < "$sumfile")"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  die "failed to find entry for '${entryname}' in '${sumfile}'"
}

normalized_ostype() {
  local ostype
  # We only need to worry about ASCII here
  if [ -n "${opt_ostype:-}" ]; then
    # shellcheck disable=SC2018,SC2019
    ostype="$(printf '%s' "$opt_ostype" | tr A-Z a-z)"
  else
    # shellcheck disable=SC2018,SC2019
    ostype="$(uname -s | tr A-Z a-z)"
  fi
  case "$ostype" in
    (*linux*)  ostype="linux" ;;
    (win32)    ostype="windows" ;;
    (ming*_nt) ostype="windows" ;;
  esac

  # Deliberately not quoted, setting $@ within this function
  # shellcheck disable=SC2086
  set $SUPPORTED_OSTYPES
  for x; do
    if [ "$x" = "$ostype" ]; then
      printf '%s\n' "$ostype"
      return 0
    fi
  done
  die "unsupported OS: $ostype"
}

validate_arch() {
  local check="$1"
  local x
  # Deliberately not quoted, setting $@ within this function
  # shellcheck disable=SC2086
  set $SUPPORTED_ARCHS
  for x; do
    if [ "$x" = "$check" ]; then
      return 0
    fi
  done
  return 1
}

normalized_arch() {
  # We are normalising to the Golang nomenclature, which is how the binaries are released.
  # The main ones are:  amd64 arm64
  # There is no universal standard here.  Go's is as good as any.

  # Command-line flag is the escape hatch.
  if [ -n "${opt_arch:-}" ]; then
    printf '%s\n' "$opt_arch"
    return 0
  fi

  # Beware `uname -m` vs `uname -p`.
  # Nominally, -m is machine, -p is processor.  But what does this mean in practice?
  # In practice, -m tends to be closer to the absolute truth of what the CPU is,
  # while -p is adaptive to personality, binary type, etc.
  # On Alpine Linux inside Docker, -p can fail `unknown` while `-m` works.
  #
  #                 uname -m    uname -p
  # Darwin/x86      x86_64      i386
  # Darwin/M1       arm64       arm
  # Alpine/docker   x86_64      unknown
  # Ubuntu/x86/64b  x86_64      x86_64
  # RPi 3B Linux    armv7l      unknown     (-m depends upon boot flags & kernel)
  #
  # SUSv4 requires that uname exist and that it have the -m flag, but does not document -p.
  local narch
  narch="$(uname -m)"
  case "$narch" in
    (x86_64) narch="amd64" ;;
    (amd64) true ;;
    (aarch64) narch="arm64" ;;
    (arm64) true ;;
    (armv7l) narch='arm7' ;;  # not yet in the supported list, but this is the pattern we need
    (*) die "Unhandled architecture '$narch', use -a flag to select a supported arch" ;;
  esac
  if validate_arch "$narch"; then
    printf '%s\n' "$narch"
  else
    die "Unhandled architecture '$narch', use -a flag to select a supported arch"
  fi
}

curl_cmd() {
  curl --user-agent "$HTTP_USER_AGENT" "$@"
}

curl_cmd_progress() {
  if [ "$VERBOSE" -lt 1 ]; then
    curl_cmd --silent --show-error --fail --location "$@" || return $?
    return 0
  fi
  if ! [ -t 0 ]; then
    # we risk some strange output left-over with curl and progress bars when it can't determine
    # the full width of the terminal, so we smooth things over
    if [ -t 2 ]; then
      curl_cmd --progress-bar --fail --location "$@" <&2
    elif [ -t 1 ]; then
      curl_cmd --progress-bar --fail --location "$@" <&1
    else
      # give up
      curl_cmd --progress-bar --fail --location "$@"
    fi
  else
    curl_cmd --progress-bar --fail --location "$@"
  fi
}

dir_is_in_PATH() {
  local needle="$1"
  local oIFS="$IFS"
  local pathdir
  case "$(normalized_ostype)" in
    (windows) IFS=';' ;;
    (*)       IFS=':' ;;
  esac
  # shellcheck disable=SC2086
  set $PATH
  IFS="$oIFS"
  for pathdir
  do
    if [ "$pathdir" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# SIDE EFFECT: sets $WORK_DIR
setup_tmp_dir() {
  local old_umask
  # The unzip command does not work well with piped stdin, we need to have
  # the complete zip-file on local disk.  The portability of mktemp(1) is
  # an unpleasant situation.
  # This is the sanest way to get a temporary directory which only we can
  # even look inside.
  old_umask="$(umask)"
  umask 077
  WORK_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'instmpdir')" || \
    die "failed to create a temporary directory with mktemp(1)"
  umask "$old_umask"
  # We don't set "readonly WORK_DIR" because readonly is sometimes also "local"
  # and we don't want that.

  # POSIX does not give rm(1) a `-v` flag.
  # We deliberately are expanding the now-readonly WORK_DIR at trap set time,
  # thus the double quotes, thus:
  # shellcheck disable=SC2064
  trap "rm -rf -- '${WORK_DIR}'" EXIT
}

# SIDE EFFECT: sets $ALL_TOOLS
# SIDE EFFECT: sets $ON_CHANNEL
fetch_and_parse_channels() {
  # This is not the most efficient, sed'ing from a temporary file repeatedly,
  # but it's very portable and the more efficient approaches suffer in
  # readability.  We're run once during initial install, it's better to be
  # something people can read and understand than to be optimal.

  local chanfile chan_origin
  local channel tool suffix version zipfile checksumfile urldir sysos sysarch
  local varfile known count found line nightly_version

  if [ -n "$opt_channel_file" ]; then
    chanfile="$opt_channel_file"
    chan_origin="$opt_channel_file"
  else
    chanfile="$WORK_DIR/channels.conf"
    chan_origin="$CHANNELS_URL"
    curl_cmd -fSs --location --output "$chanfile" "$CHANNELS_URL"
  fi
  [ -f "$chanfile" ] || die "missing a channels file"

  known="$WORK_DIR/known-channels"
  if have_command xargs; then
    grab_channelfile_line CHANNELS | xargs -n 1 > "$known"
    count="$(wc -l < "$known" | xargs)"
  else
    # xargs is part of POSIX and should always be present in supported environments,
    # but Fedora removes it in their base Docker image and ... that worries me.
    # But since xargs is only used here, we can work around it.
    # Since all traditional systems will have xargs, we will assume a modern sed
    # which works for this invocation.
    # We'll hope that this wc(1) is well-behaved around whitespace when reading stdin.
    grab_channelfile_line CHANNELS | sed 's/[ \t]/\n/g' | grep . > "$known"
    count="$(wc -l < "$known")"
  fi
  if [ "$count" -eq 0 ]; then
    die "unable to parse any channels from '${chan_origin}'"
  fi

  if [ -n "${PREVIOUS_CHANNEL?should have set PREVIOUS_CHANNEL, even if just to empty}" ]; then
    if [ -n "$opt_channel" ]; then
      true # command-line flags override previous channel
    else
      opt_channel="$PREVIOUS_CHANNEL"
    fi
  else
    true # first successful (we hope) run
  fi

  # We don't grep, the opt comes from the user and we don't trust
  # that ultimately it won't come from somewhere else automated, so might
  # contain regexp special characters.
  if [ -n "$opt_channel" ]; then
    found=0
    while read -r line; do
      [ "$line" = "$opt_channel" ] || continue
      found=1
      channel="$opt_channel"
      break
    done < "$known"
    if [ "$found" -eq 0 ]; then
      die "unknown channel '${opt_channel}'; available: $(grab_channelfile_line CHANNELS)"
    fi
  else
    channel="$(head -n 1 "$known")"
  fi

  note "channel: ${channel}"
  # this is used later to persist the chosen channel
  ON_CHANNEL="$channel"

  if [ "$channel" = "nightly" ]; then
    if [ -n "$opt_nightly_date" ]; then
      nightly_version="$opt_nightly_date"
    else
      nightly_version="$(curl_cmd -fSs "$NIGHTLY_URL")"
    fi
  fi

  sysos="$(normalized_ostype)"
  sysarch="$(normalized_arch)"

  ALL_TOOLS="$(grab_channelfile_line TOOLS)"

  for tool in $ALL_TOOLS; do
    varfile="$WORK_DIR/vars-${tool}.sh"
    suffix="${channel}_${tool}"
    # Reset these so that we can expand consistently.
    version='' zipfile='' checksumfile='' urldir='' executable=''

    # Our assumption is no single-quotes in any of these directives from the
    # channel file
    if [ "$channel" = "nightly" ]; then
      version="$nightly_version"
    else
      version="$(grab_channelfile_line "VERSION_${suffix}")"
    fi
    zipfile="$(grab_channelfile_expand "ZIPFILE_${suffix}")"
    checksumfile="$(grab_channelfile_expand "CHECKSUMS_${suffix}")"
    urldir="$(grab_channelfile_expand "URLDIR_${suffix}")"

    executable="$tool"
    case "$sysos" in
      windows) executable="${executable}.exe" ;;
    esac

    cat > "$varfile" << EOVARS
executable='${executable}'

version='${version}'
zipfile='${zipfile}'
checksumfile='${checksumfile}'
urldir='${urldir}'

sysos='${sysos}'
sysarch='${sysarch}'
EOVARS
  done
}

grab_channelfile_line() {
  local varname="${1:?need a file to get from the channel file}"
  local t
  # sed -E is not POSIX, so we're on BREs only
  t="$(sed -n "s/${varname}[[:space:]]*=[[:space:]]*//p" < "${chanfile:?bug, chanfile not in calling context}")"
  if [ -n "$t" ]; then
    printf '%s\n' "$t"
  else
    die "missing '${varname}' in ${chan_origin:?}"
  fi
}

grab_channelfile_expand() {
  local val pre post
  val="$(grab_channelfile_line "$@")"
  # The ${variable//text/replace} expansion is a bash/zsh/other extension.
  # This is very annoying.
  val="$(expand_config_value "$val" VERSIONTAG "${version:?}")"
  val="$(expand_config_value "$val" VERSIONNOV "${version#v}")"
  val="$(expand_config_value "$val" TOOLNAME "${tool:?}")"
  val="$(expand_config_value "$val" OSNAME "${sysos:?}")"
  val="$(expand_config_value "$val" GOARCH "${sysarch:?}")"
  if [ -n "${zipfile:-}" ]; then
    val="$(expand_config_value "$val" ZIPFILE "$zipfile")"
  fi
  if [ -n "${checksumfile:-}" ]; then
    val="$(expand_config_value "$val" CHECKFILE "$checksumfile")"
  fi

  printf '%s\n' "$val"
}

expand_config_value() {
  local val="$1"
  local subst="$2"
  local replace="$3"
  local result=""
  while [ "$val" != "${val#*\%${subst}\%}" ]; do
    pre="${val%%\%${subst}\%*}"
    post="${val#*\%${subst}\%}"
    result="${result}${pre}${replace}"
    val="$post"
  done
  result="${result}${val}"
  printf '%s\n' "$result"
}

# SIDE EFFECT: sets $INSTALL_FILES
fetch_and_validate_files() {
  local tool varfile unzip_dir
  local vars here expected_cs local_cs
  here="$(pwd)"
  cd "$WORK_DIR"

  INSTALL_FILES=''
  for tool in $ALL_TOOLS; do
    note "fetching: $tool"
    varfile="./vars-${tool}.sh"
    unzip_dir="./extract-${tool}"
    vars="$(sed -n 's/=.*//p' < "$varfile")"
    # This is an array-of-variable-names in a scalar, so:
    # shellcheck disable=SC2086
    local $vars
    # shellcheck source=/dev/null
    . "$varfile"

    if [ -n "$checksumfile" ]; then
      curl_cmd_progress \
        --output "./$zipfile" "${urldir%/}/$zipfile" \
        --output "./$checksumfile" "${urldir%/}/$checksumfile"
      # NB: we are currently hard-coding an assumption of SHA256.
      expected_cs="$(checksum_for_file_entry "$checksumfile" "$zipfile")"
      local_cs="$(checksum_one_binary "$zipfile")"
      if [ "$expected_cs" = "$local_cs" ]; then
        note "checksum match: $expected_cs *$zipfile"
      else
        note "*** CHECKSUM FAILURE ***"
        note "file: $zipfile"
        note "expected SHA256: $expected_cs"
        note "   found SHA256: $local_cs"
        die "aborting rather than install corrupted file; please report this"
      fi
    else
      curl_cmd_progress \
        --output "./$zipfile" "${urldir%/}/$zipfile"
      note "!!! no checksum file available !!!"
    fi

    if [ "$VERBOSE" -ge 1 ]; then
      unzip -j -d "$unzip_dir" "./$zipfile"
    else
      unzip -q -j -d "$unzip_dir" "./$zipfile"
    fi

    INSTALL_FILES="${INSTALL_FILES}${INSTALL_FILES:+ }$WORK_DIR/$unzip_dir/$executable"

    # shellcheck disable=SC2086
    unset $vars
  done
  cd "$here"
}

install_files() {
  local fn installed
  # mkdir -m does not set permissions of parents; -v is not portable
  # We don't create anything private, so stick to inherited umask.
  mkdir -p -- "$opt_install_dir"

  echo >&2
  installed=''

  # The install command can take backups, and takes care of "text file busy"
  # problems when the target path is currently that of a running executable.
  # mv is a good second choice.  cp will more likely trigger busy problems.
  # (Someone running `nats sub '>'` would see this).
  # (Some modern systems don't trigger this any more).
  # This is why we setup install_force/install_prompt_overwrite in the
  # check_have_external_commands function.

  for fn in $INSTALL_FILES; do
    note "installing: ${fn##*/}"
    # prompt the user to overwrite if need be
    chmod 0755 "$fn"
    if $opt_force; then
      install_force "$fn" "$opt_install_dir"
    else
      install_prompt_overwrite "$fn" "$opt_install_dir"
    fi
    installed="${installed}${installed:+ }$opt_install_dir/${fn##*/}"
    echo >&2
  done

  # array-in-scalar so:
  # shellcheck disable=SC2086
  ls -ld $installed
  echo >&2
}

# SIDE EFFECT: those of write_completions_zszh
write_completions() {
  write_completions_zsh
  # need to write bash ones
}

# SIDE EFFECT: sets $WROTE_COMPLETION_ZSH
write_completions_zsh() {
  WROTE_COMPLETION_ZSH=''
  [ -f "$HOME/.zshrc" ] || [ -f "$HOME/.zshenv" ] || return 0
  have_command zsh || return 0
  local site_dir
  site_dir="$(zsh -fc 'print -r -- ${fpath[(r)*/site-functions]}')"
  if ! [ -n "$site_dir" ]; then
    note "zsh: completions: no site-functions dir found, skipping"
    return 0
  fi
  if ! [ -w "$site_dir" ]; then
    note "zsh: completions: $site_dir not writeable, not installing"
    note "zsh: if you have a personal zsh functions dir, try:"
    echo >&2
    printf >&2 '  curl -O FUNCS_DIR/_nats %s\n' "$COMPLETION_ZSH_NATS_URL"
    echo >&2
    return 0
  fi

  # Ideally, we'd have a signature for this.
  note "downloading to: $site_dir/_nats"
  curl_cmd_progress -o "$site_dir/_nats" "$COMPLETION_ZSH_NATS_URL"
  chmod 0755 "$site_dir/_nats"
  WROTE_COMPLETION_ZSH="$site_dir/_nats"
}

show_instructions() {
  if dir_is_in_PATH "$opt_install_dir"; then
    note "installation dir '${opt_install_dir}' already in PATH"
    echo
    show_instructions_completion
    note "tools installed: $ALL_TOOLS"
    return 0
  fi

  echo "Now manually add '${opt_install_dir}' to your PATH:"
  echo

  case "$(normalized_ostype)" in
    (windows) cat <<EOWINDOWS ;;
Windows Cmd Prompt Example:
  setx path %path;"${opt_install_dir}"

EOWINDOWS

    (*) cat <<EOOTHER ;;
Bash Example:
  echo 'export PATH="\${PATH}:${opt_install_dir}"' >> ~/.bashrc
  source ~/.bashrc

Zsh Example:
  echo 'path+=("${opt_install_dir}")' >> ~/.zshrc
  source ~/.zshrc

EOOTHER

  esac

  show_instructions_completion
}

show_instructions_completion() {
  show_instructions_completion_zsh
}

show_instructions_completion_zsh() {
  if [ -n "$WROTE_COMPLETION_ZSH" ]; then
    cat <<EOAUTOLOAD
For zsh, a completion function for nats has been installed.
If you already have autoloading from fpath setup, you need do nothing more.
Otherwise:

  echo 'autoload _nats' >> ~/.zshrc
EOAUTOLOAD
    echo
  fi

  echo "Also take a look at: ${ZSH_EXTRA_SETUP_URL}"
  echo
}

extract_previous_channel() {
  PREVIOUS_CHANNEL=''
  [ -f "$opt_config_dir/install-channel.txt" ] || return 0
  PREVIOUS_CHANNEL="$(cat "$opt_config_dir/install-channel.txt")"
}

store_channel() {
  if [ -n "$PREVIOUS_CHANNEL" ] && [ "$PREVIOUS_CHANNEL" = "$ON_CHANNEL" ]; then
    return 0
  fi
  [ -d "$opt_config_dir" ] || mkdir -p -- "$opt_config_dir"
  printf > "$opt_config_dir/install-channel.txt" '%s\n' "$ON_CHANNEL"
}

load_context() {
  if [ "$nsc_env_secret" = "" ]; then
    return 0
  fi
  note "setting nats context"
  "$opt_install_dir/nsc" load --profile "nsc://$nsc_env_operator_name?secret=$nsc_env_secret"
  "$opt_install_dir/nats" context ls
  "$opt_install_dir/nats" context show
  note 'All set!'
}

main "$@"
