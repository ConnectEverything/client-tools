#!/bin/sh
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
# By default, we install binaries to ~/.local/bin (per XDG).
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
#
# We do not use JSON because we can't depend upon any particular tools for
# parsing it for channel updates.
#
# We require various tools mandated by POSIX, such as `uname`, `sed`, etc.

readonly CHANNELS_URL=FIXME
readonly NIGHTLY_URL=FIXME
readonly HTTP_USER_AGENT='synadia_install/0.3 (@ConnectEverything)'

# This is a list of the architectures we support, which should be listed in
# the Go architecture naming format.
readonly SUPPORTED_ARCHS="amd64 arm64"
# This is a list of the known OSes, to validate user input
readonly SUPPORTED_OSTYPES="linux darwin freebsd windows"

# Where to install to, by default
: "${HOME:=/home/$(id -un)}"
readonly DEFAULT_BINARY_INSTALL_DIR="$HOME/.local/bin"

### END OF CONFIGURATION ###

progname="$(basename "$0" .sh)"
note() { printf >&2 '%s: %s\n' "$progname" "$*"; }
die() { note "$@"; exit 1; }

main() {
  parse_options "$@"

  # error early if missing commands; put it after option processing
  # so that if we need to, we can add options to handle alternatives.
  check_have_external_commands

  # We do not chdir to the tmp_dir, because the caller can provide
  # command-line flags with paths to files which might be relative,
  # and normalizing those in truly portable shell is iffy.

  setup_tmp_dir

  fetch_and_parse_channels

  fetch_and_validate_files

  install_files

  show_instructions
}

usage() {
  local ev="${1:-1}"
  [ "$ev" = 0 ] || exec >&2
  cat <<EOUSAGE
Usage: $progname [-f] [-c <channel>] [-d <dir>] [-a <arch>] [-o <ostype>]
 -f           force, don't prompt before installing over files
 -c channel   channel to install ("stable", "nightly")
 -d dir       directory to download into [default: $DEFAULT_BINARY_INSTALL_DIR]
 -o ostype    override the OS detection [allowed: $SUPPORTED_OSTYPES]
 -a arch      force choosing a specific processor architecture [allowed: $SUPPORTED_ARCHS]
EOUSAGE
# Developer only, not documented in help:
#  -F chanfile  use a local channel file instead of the hosted URL
  exit "$ev"
}

opt_install_dir=''
opt_channel=''
opt_channel_file=''
opt_nightly_date=''
opt_arch=''
opt_ostype=''
opt_force=false
parse_options() {
  while getopts ':a:c:d:fho:F:N:' arg; do
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
}

check_have_external_commands() {
  local cmd

  # Only those commands which take --help :
  for cmd in curl unzip
  do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
  done

  # Our invocation of mktemp has to handle multiple variants; if that's not
  # installed, let it fail later.
  # PORTABILITY ISSUE: WINDOWS?
  test -e /dev/stdin || die "missing device /dev/stdin"
}

normalized_ostype() {
  local ostype
  if [ -n "${opt_ostype:-}" ]; then
    ostype="$(printf '%s' "$opt_ostype" | tr A-Z a-z)"
  else
    # We only need to worry about ASCII here
    ostype="$(uname -s | tr A-Z a-z)"
  fi
  case "$ostype" in
    (*linux*)  ostype="linux" ;;
    (win32)    ostype="windows" ;;
    (ming*_nt) ostype="windows" ;;
  esac
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
    (*) die "Unhandled architecture '$narch', use -a flag to select a supported arch" ;;
  esac
  if validate_arch "$narch"; then
    printf '%s\n' "$narch"
  else
    die "Unhandled architecture '$narch', use -a flag to select a supported arch"
  fi
}

exe_filename_per_os() {
  # FIXME
  local fn="$NSC_BINARY_BASENAME"
  case "$(normalized_ostype)" in
    (windows) fn="${fn}.exe" ;;
  esac
  printf '%s\n' "$fn"
}

curl_cmd() {
  curl --user-agent "$HTTP_USER_AGENT" "$@"
}

dir_is_in_PATH() {
  local needle="$1"
  local oIFS="$IFS"
  local pathdir
  case "$(normalized_ostype)" in
    (windows) IFS=';' ;;
    (*)       IFS=':' ;;
  esac
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
  # POSIX does not give rm(1) a `-v` flag.
  trap "rm -rf -- '${WORK_DIR}'" EXIT
}

# SIDE EFFECT: sets $ALL_TOOLS
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
    curl_cmd --progress-bar --location --output "$chanfile" "$CHANNELS_URL"
  fi
  [ -f "$chanfile" ] || die "missing a channels file"

  known="$WORK_DIR/known-channels"
  grab_channelfile_line CHANNELS | xargs -n 1 > "$known"
  count="$(wc -l < "$known" | xargs)"
  if [ "$count" -eq 0 ]; then
    die "unable to parse any channels from '${chan_origin}'"
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

  if [ "$channel" = "nightly" ]; then
    if [ -n "$opt_nightly_date" ]; then
      nightly_version="$opt_nightly_date"
    elif [ "$NIGHTLY_URL" = "FIXME" ]; then
      # XXX FIXME dev data assistance
      nightly_version="$(date +%Y%m%d)"
    else
      nightly_version="$(cmd_curl -fSs "$NIGHTLY_URL")"
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
  local vars here
  here="$(pwd)"
  cd "$WORK_DIR"

  INSTALL_FILES=''
  for tool in $ALL_TOOLS; do
    note "fetching: $tool"
    varfile="./vars-${tool}.sh"
    unzip_dir="./extract-${tool}"
    vars="$(sed -n 's/=.*//p' < "$varfile")"
    local $vars
    . "$varfile"

    if [ -n "$checksumfile" ]; then
      curl_cmd --progress-bar --location \
        --output "./$zipfile" "${urldir%/}/$zipfile" \
        --output "./$checksumfile" "${urldir%/}/$checksumfile"
      note "FIXME: need to validate checksums in $checksumfile"
    else
      curl_cmd --progress-bar --location \
        --output "./$zipfile" "${urldir%/}/$zipfile"
    fi

    unzip -j -d "$unzip_dir" "./$zipfile"

    # FIXME: any other validation here

    INSTALL_FILES="${INSTALL_FILES}${INSTALL_FILES:+ }$WORK_DIR/$unzip_dir/$executable"

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

  for fn in $INSTALL_FILES; do
    note "installing: ${fn##*/}"
    # prompt the user to overwrite if need be
    chmod 0755 "$fn"
    if $opt_force; then
      mv -f -- "$fn" "$opt_install_dir/"
    else
      mv -i -- "$fn" "$opt_install_dir/"
    fi
    installed="${installed}${installed:+ }$opt_install_dir/${fn##*/}"
    echo >&2
  done

  ls -ld $installed
  echo >&2
}

show_instructions() {
  if dir_is_in_PATH "$opt_install_dir"; then
    note "installation dir '${opt_install_dir}' already in PATH"
    note "all done"
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
}

main "$@"
