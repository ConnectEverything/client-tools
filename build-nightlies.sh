#!/usr/bin/env bash
set -euo pipefail

progname="$(basename "$0" .sh)"
stderr() { printf >&2 '%s: %s\n' "$progname" "$*"; }
warn() { stderr "$@"; }
die() { warn "$@"; exit 1; }
die_n() { local ev="$1"; shift; warn "$@"; exit "$ev"; }
have_command() { command -v "$1" >/dev/null 2>&1 ; }
readonly EX_USAGE=64 EX_SOFTWARE=70

# We capture the initial pwd at the very beginning for reuse
start_cwd="$(pwd)"
readonly start_cwd

# ========================================================================
# CONFIG

readonly BUILD_DIR='build'
readonly CLOUDFLARE_VARS_FILE='cloudflare.conf'
readonly HTTP_USER_AGENT='client-tools-builder/0.1 (@philpennock, ConnectEverything)'
readonly CLOUDFLARE_API_URL='https://api.cloudflare.com/client/v4'

readonly -a NEEDED_COMMANDS=(jq curl zip sha256sum)

# These will be set readonly at the end of parse_options:
USE_EXISTING_BUILD=0
: "${NIGHTLY_DATE:=$(date +%Y%m%d)}"

# We keep nightlies in CF for a limited amount of time, letting CF auto-expire them.
declare -i NIGHTLY_EXPIRATION_TTL=$(( 14 * 24 * 3600 ))
readonly NIGHTLY_EXPIRATION_TTL

readonly -A tool_repo_slugs=(
  [nats]='nats-io/natscli'
  [nsc]='nats-io/nsc'
)
declare -A tool_current_commit=()

# ========================================================================
# FUNCTIONS ONLY, NO DIRECT EXECUTION IN THIS SECTION

usage() {
  local ev="${1:-1}"
  [[ $ev -eq 0 ]] || exec >&2
  cat <<EOUSAGE
Usage: $progname [-d <date>] [-rP]
  -d DATE     override date from ${NIGHTLY_DATE@Q}
  -r          reuse existing build
  -P          don't publish (don't need API keys)

The DATE should be in YYYYMMDD format.
If publishing, expect the credentials in: \$CLOUDFLARE_AUTH_TOKEN
EOUSAGE
  exit "$ev"
}

# SIDE-EFFECT: sets $opt_* and $parse_options_caller_shift
# SIDE-EFFECT: updates $NIGHTLY_DATE
# SIDE-EFFECT: updates $USE_EXISTING_BUILD
parse_options() {
  local arg OPTIND
  opt_publish=1
  while getopts ':d:hrP' arg; do
    case "$arg" in
      h) usage 0 ;;
      d) NIGHTLY_DATE="$OPTARG" ;;
      r) USE_EXISTING_BUILD=1 ;;
      P) opt_publish=0 ;;
      :) die_n "$EX_USAGE" "missing required option for -$OPTARG; see -h for help" ;;
      \?) die_n "$EX_USAGE" "unknown option -$OPTARG; see -h for help" ;;
      *) die_n "$EX_SOFTWARE" "unhandled option -$arg; CODE BUG" ;;
    esac
  done
  parse_options_caller_shift=$((OPTIND - 1))
  shift "$parse_options_caller_shift"
  if [[ $# -gt 0 ]]; then
    die_n "$EX_USAGE" "unexpected command-line parameters"
  fi

  readonly USE_EXISTING_BUILD NIGHTLY_DATE
}

ua_curl() { command curl --user-agent "${HTTP_USER_AGENT:?}" "$@"; }
cf_curl_noct() { ua_curl -H "Authorization: Bearer $CLOUDFLARE_AUTH_TOKEN" "$@"; }
cf_curl() { cf_curl_noct -H "Content-Type: application/json" "$@"; }
gh_curl() { ua_curl --user "${GITHUB_TOKEN}:x-oauth-basic" "$@"; }

is_known_tool() { [[ -n "${tool_repo_slugs[$1]:+isset}" ]]; }
require_known_tool() { is_known_tool "$1" || die "unknown tool ${1@Q}"; }

dir_for_tool() {
  printf '%s/%s/%s\n' "$start_cwd" "$BUILD_DIR" "$1"
}

nightly_dir() {
  printf '%s/%s/%s-%s\n' "$start_cwd" "$BUILD_DIR" nightly "$NIGHTLY_DATE"
}

fetch_one_github_repo() {
  local tool="$1"
  shift
  local clone_dir repo_clone_url too_old_tag commit
  cd "$start_cwd"
  require_known_tool "$tool"
  clone_dir="$(dir_for_tool "$tool")"
  if [[ -d "$clone_dir/.git" ]]; then
    # not the normal case, but handle it during dev
    stderr "update in ${clone_dir@Q} (expect is github:${tool_repo_slugs[$tool]})"
    git -C "$clone_dir" remote update -p
    git -C "$clone_dir" merge --ff-only @{u}
  else
    stderr "clone github:${tool_repo_slugs[$tool]} -> ${clone_dir@Q}"
    repo_clone_url="https://github.com/${tool_repo_slugs[$tool]}.git"
    # Let's hope that version tags are only on the main branch;
    # worst case scenario, we exclude based on a branch and clone more depth than optimal, which is acceptable.
    too_old_tag="$(git ls-remote --tags --sort=-refname "$repo_clone_url" | grep -Fv '^' | grep -E 'refs/tags/(v|[0-9])' | head -n 3 | tail -n 1 | sed 's:^.*refs/tags/::')"
    git clone \
      --single-branch \
      --shallow-exclude="$too_old_tag" \
      "$repo_clone_url" "$clone_dir"
  fi
  commit="$(git -C "$clone_dir" rev-parse HEAD)"
  tool_current_commit[$tool]="$commit"
}

# nsc overrides the dist dir from 'dist'.
# Rather than parse all YAML, let's cheat for now and use sed.
# If we need better parsing, it should only be in this function.
dist_dir_for_tool() {
  local tool="$1"
  shift
  local d clone_dir
  clone_dir="$(dir_for_tool "$tool")"

  dist_dir="$(sed -n 's/dist: *//p' < "${clone_dir}/.goreleaser.yml")"
  [[ -n "$dist_dir" ]] || dist_dir='dist'

  printf '%s/%s\n' "$clone_dir" "$dist_dir"
}

build_one_tool() {
  local tool="$1"
  shift
  local clone_dir dist_dir
  clone_dir="$(dir_for_tool "$tool")"
  cd "$clone_dir"
  if [[ -n "${SKIP_BUILD:-}" ]]; then
    stderr "skipping build (per request) in ${clone_dir@Q}"
    return
  fi
  dist_dir="$(dist_dir_for_tool "$tool")"
  if [[ -f "${dist_dir}/artifacts.json" ]] && (( USE_EXISTING_BUILD )); then
    stderr "reusing existing build in ${clone_dir@Q}"
    return
  fi

  goreleaser build --snapshot --rm-dist
}

check_have_publish_credentials() {
  local verify label status
  [[ -n "${CLOUDFLARE_AUTH_TOKEN:-}" ]] || die "missing content in \$CLOUDFLARE_AUTH_TOKEN (use -P to skip publish; -h for help)"
  stderr 'checking $CLOUDFLARE_AUTH_TOKEN against CF verify end-point'
  label='cloudflare[user/tokens/verify]'
  verify="$(cf_curl -fSs https://api.cloudflare.com/client/v4/user/tokens/verify)" || die "$label failed"
  jq <<<"$verify" -er .success >/dev/null || die "$label not successful $(jq <<<"$verify" -r '.errors[]')"
  status="$(jq <<<"$verify" -er .result.status)"
  [[ "$status" == "active" ]] || die "$label says \$CLOUDFLARE_AUTH_TOKEN is not active"
  stderr 'creds okay'
}

collect_nightly_zips_of_tool() {
  local tool="$1"
  shift
  local binary_dir zip_dir zipfn binpath fn_date
  binary_dir="$(dist_dir_for_tool "$tool")"
  zip_dir="$(nightly_dir)"

  # We want YYYYMMDD in the filenames, using - to separate components such as
  # date from OS, not used within the date.
  fn_date="${NIGHTLY_DATE//-/}"

  [[ -f "$binary_dir/artifacts.json" ]] || die "missing artifacts.json for ${tool@Q}"
  [[ -d "$zip_dir" ]] || mkdir -pv -- "$zip_dir"

  jq < "$binary_dir/artifacts.json" -er \
    --arg Tool "$tool" --arg Date "$fn_date" \
      '.[] | select(.type == "Binary") |
       "\($Tool)/\(.goos)-\(.goarch)\(.goarm // "")  \($Tool)-\($Date)-\(.goos)-\(.goarch)\(.goarm // "").zip  \(.path)"' \
  | while read -r label zipfn binpath; do
    # -j to junk paths and just store the filename
    stderr "zip for: $label"
    if [[ -f "$zip_dir/$zipfn" ]]; then
      if (( USE_EXISTING_BUILD )); then
        stderr " ... skipping, using existing"
        continue
      fi
      die "duplicate attempt to write to same .zip file ${zipfn@Q}"
    fi
    zip -j "$zip_dir/$zipfn" "$binpath"
  done
}

write_checksums() {
  cd "$(nightly_dir)"
  stderr "writing checksums file(s)"
  sha256sum -b *.zip > "SHA256SUMS-$NIGHTLY_DATE.txt"
}

# TODO: we're using KV store for now, but this probably belongs in R2, once we get access to that.
# R2 is currently on a waitlist.
#
# Expect: already in correct directory; key == filename
publish_one_file_to_cloudflare() {
  local key="${1:?}"
  local url api ct params

  case "$key" in
    *.zip) ct='application/zip' ;;
    *) ct='text/plain' ;;
  esac

  # <https://api.cloudflare.com/#workers-kv-namespace-write-key-value-pair>
  # "permission needed: com.cloudflare.edge.storage.kv.key.update"

  api="accounts/$CF_ACCOUNT/storage/kv/namespaces/$CF_NIGHTLIES_KV_NAMESPACE/values/$key"
  params="expiration_ttl=$NIGHTLY_EXPIRATION_TTL"
  url="$CLOUDFLARE_API_URL/$api?$params"
  stderr "uploading: ${key@Q}"
  cf_curl_noct -X PUT "$url" -H "Content-Type: $ct" --data-binary "@$key"
}

publish_nightly_files_to_cloudflare() {
  local tool key
  cd "$(nightly_dir)"

  # remove all indices
  rm -vf CURRENT COMMITS-*.txt

  # Include a key which identifies which commits this nightly corresponds to
  for tool in "${!tool_repo_slugs[@]}"; do
    printf '%s: %s\n' "$tool" "${tool_current_commit[$tool]}"
  done | tee "COMMITS-$NIGHTLY_DATE.txt"

  # TODO: loop first, check sizes, complain if any are over 100MB, the size limit here

  for key in *; do
    publish_one_file_to_cloudflare "$key"
    sleep 0.5
  done

  # ONLY AT END!
  # Do not update the CURRENT key until all the assets have been uploaded.
  # We don't want to update the CURRENT seen by clients before their binaries
  # are in place.
  printf > 'CURRENT' '%s\n' "$NIGHTLY_DATE"
  publish_one_file_to_cloudflare 'CURRENT'

  stderr "uploaded all"
}

# ========================================================================
# MAIN FLOW

main() {
  local -i parse_options_caller_shift
  local cmd tool
  parse_options "$@"
  shift "$parse_options_caller_shift"

  [[ -f "$CLOUDFLARE_VARS_FILE" ]] || die "bad starting dir? missing file ${CLOUDFLARE_VARS_FILE@Q}"
  for cmd in "${NEEDED_COMMANDS[@]}"; do
    have_command "$cmd" || die "missing tool: ${cmd@Q}"
  done
  if (( opt_publish )); then
    . "./$CLOUDFLARE_VARS_FILE"
    check_have_publish_credentials
    [[ -n "${CF_ACCOUNT:-}" ]] || die "missing cloudflare account in config"
    [[ -n "${CF_NIGHTLIES_KV_NAMESPACE:-}" ]] || die "missing cloudflare KV namespace in config"
  fi
  case "$NIGHTLY_DATE" in
    */*) die "the NIGHTLY_DATE value contains a directory separator, do not do that: ${NIGHTLY_DATE@Q}" ;;
  esac

  stderr "building $NIGHTLY_DATE"

  [[ -d "$BUILD_DIR" ]] || mkdir -pv -- "$BUILD_DIR"

  # We do not publish in the first loop, so that we have complete consistent sets
  for tool in "${!tool_repo_slugs[@]}"; do
    fetch_one_github_repo "$tool"
    build_one_tool "$tool"
    collect_nightly_zips_of_tool "$tool"
  done
  write_checksums

  # Now we can publish
  if (( opt_publish )); then
    publish_nightly_files_to_cloudflare
    # can point nightly-$NIGHTLY_DATE at that commit, and nightly too ... if we're happy to have a dynamically moving git tag in our repos (a big if)
  else
    stderr "skipping publishing, per request"
  fi

  stderr "done"
}

# Don't run main if sourced; easier to test
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
