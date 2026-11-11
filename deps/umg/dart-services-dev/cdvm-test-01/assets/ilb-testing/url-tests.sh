#!/usr/bin/env bash
#
# also zsh compatible
#
# url-tests.sh -- YAML-driven curl reachability suite.
#
# Dot-source this file to load the `url_tests` function into your shell:
#
#   . ./url-tests.sh
#   url_tests         # run every test in url-tests.yaml
#   url_tests --list      # show the test matrix, no network calls
#   url_tests -H 'public-*'   # only hosts matching a glob
#   url_tests -f 'other.yaml'
#
# It can also be executed directly (./url-tests.sh ...), which just calls the
# function with the same arguments.
#
# The YAML is a map of groups; each group is a list of {host, tests[]} and each
# test is {scheme, port?, expect?}. An absent `port` means "scheme default" (no
# :port in the URL); an absent `expect` means 200.
#
# Default YAML lives next to this file. Resolved at source/exec time because
# $0 and BASH_SOURCE mean different things once we are inside a function.
if [ -n "${ZSH_VERSION:-}" ]; then
  _URLTESTS_SELF=$(eval 'printf "%s" "${(%):-%x}"')
else
  _URLTESTS_SELF=${BASH_SOURCE[0]}
fi
_URLTESTS_DIR=$(cd -- "$(dirname -- "$_URLTESTS_SELF")" && pwd)
_URLTESTS_DEFAULT_YAML="$_URLTESTS_DIR/url-tests.yaml"
unset _URLTESTS_SELF

# _urltests_match HOST GLOB -- true if HOST matches GLOB.
# bash treats the unquoted right-hand side of [[ == ]] as a pattern even when it
# comes from a variable; zsh needs ${~var} to opt in. The zsh form is built with
# eval so bash never has to parse a substitution it considers invalid.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_urltests_match() { [[ $1 == ${~2} ]]; }'
else
  _urltests_match() { [[ $1 == $2 ]]; }
fi

# Map a curl exit status and HTTP code onto the single token that `expect:`
# is compared against. Keeping `timeout` (packet dropped) distinct from
# `refused` (RST) is the whole point -- an `expect: timeout` line is asserting
# the firewall silently drops, not that the port merely fails to answer.
_urltests_classify() {
  case "$1" in
    0)   printf '%s' "$2" ;;    # curl succeeded: report the HTTP status
    6)   printf 'dns' ;;      # could not resolve host
    7)   printf 'refused' ;;    # failed to connect / connection refused
    28)  printf 'timeout' ;;    # --connect-timeout or -m exceeded
    35|60) printf 'tls' ;;      # SSL connect error / cert verify failed
    *)   printf 'error:%s' "$1" ;;
  esac
}

_urltests_usage() {
  cat <<'EOF'
url_tests [-f FILE] [-H GLOB] [-l] [-h]

  -f, --file FILE   YAML test definition (default: url-tests.yaml beside this script)
  -H, --host GLOB   only run tests whose host matches GLOB (e.g. 'public-*')
  -l, --list    print the flattened test matrix and exit; makes no network calls
  -h, --help    this message

Exit status: 0 all passed, 1 one or more failed, 2 usage or dependency error.
EOF
}

url_tests() {
  local yaml="$_URLTESTS_DEFAULT_YAML"
  local filter='*'
  local list_only=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file) yaml="$2"; shift 2 ;;
      -H|--host) filter="$2"; shift 2 ;;
      -l|--list) list_only=1; shift ;;
      -h|--help) _urltests_usage; return 0 ;;
      *) printf 'url_tests: unknown option: %s\n\n' "$1" >&2
         _urltests_usage >&2; return 2 ;;
    esac
  done

  local dep=""
  for dep in yq jq curl; do
    command -v "$dep" >/dev/null 2>&1 || {
      printf 'url_tests: required command not found: %s\n' "$dep" >&2
      return 2
    }
  done
  [ -r "$yaml" ] || {
    printf 'url_tests: cannot read YAML file: %s\n' "$yaml" >&2
    return 2
  }

  # A host block repeated inside one group means two sets of expectations for
  # the same URLs -- they cannot both hold. Warn and run both as written
  # rather than silently deduping; fixing the data is the caller's call.
  local dups
  dups=$(yq -r 'to_entries[] as $g | $g.value[] | [$g.key, .host] | join("|")' "$yaml" \
       2>/dev/null | sort | uniq -d)
  if [ -n "$dups" ]; then
    printf '%s\n' "$dups" | while IFS='|' read -r g h; do
      printf "WARN: duplicate host '%s' in group '%s' -- expectations may conflict\n" \
           "$h" "$g" >&2
    done
  fi

  # Flatten once to pipe-delimited rows: group, host, scheme, port, expect.
  # Defaults are applied here in the data layer so the loop below has no
  # special cases. Pipe rather than tab: tab is an IFS *whitespace* character,
  # so `IFS=$'\t' read` silently collapses the empty port field into the next
  # one. A non-whitespace delimiter preserves empty fields.
  local tsv=""
  tsv=$(mktemp) || return 2
  if ! yq -r '
    to_entries[] as $g
    | $g.value[] as $h
    | $h.tests[]
    | [$g.key, $h.host, .scheme, (.port // ""), (.expect // "200")]
    | map(tostring) | join("|")
  ' "$yaml" >"$tsv" 2>/dev/null; then
    printf 'url_tests: failed to parse %s\n' "$yaml" >&2
    rm -f "$tsv"
    return 2
  fi

  # Apply the host filter up front so counts and column widths reflect what
  # will actually run.
  local sel=""
  sel=$(mktemp) || { rm -f "$tsv"; return 2; }
  local group="" host="" scheme="" port="" expect=""
  while IFS='|' read -r group host scheme port expect; do
    if _urltests_match "$host" "$filter"; then
      printf '%s|%s|%s|%s|%s\n' \
           "$group" "$host" "$scheme" "$port" "$expect" >>"$sel"
    fi
  done <"$tsv"
  rm -f "$tsv"

  local total=""
  total=$(wc -l <"$sel" | tr -d ' ')
  if [ "$total" -eq 0 ]; then
    printf 'url_tests: no tests matched host filter %s\n' "$filter" >&2
    rm -f "$sel"
    return 2
  fi

  # Column widths from the data, so the table stays aligned whatever the YAML holds.
  local wgroup="" wurl=""
  wgroup=$(awk -F'[|]' 'length($1)>m{m=length($1)} END{print (m<5?5:m)}' "$sel")
  wurl=$(awk -F'[|]' '
    {u = length($3) + 3 + length($2) + ($4 == "" ? 0 : length($4) + 1)
     if (u > m) m = u}
    END {print (m < 20 ? 20 : m)}' "$sel")

  local url=""
  if [ "$list_only" -eq 1 ]; then
    printf '%-*s  %-*s  %s\n' "$wgroup" GROUP "$wurl" URL EXPECT
    while IFS='|' read -r group host scheme port expect; do
      url="$scheme://$host"
      [ -n "$port" ] && url="$url:$port"
      printf '%-*s  %-*s  %s\n' "$wgroup" "$group" "$wurl" "$url" "$expect"
    done <"$sel"
    printf '\n%s test(s)\n' "$total"
    rm -f "$sel"
    return 0
  fi

  local c_pass='' c_fail='' c_dim='' c_off=''
  if [ -t 1 ]; then
    c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
  fi

  local body="" err=""
  body=$(mktemp) || { rm -f "$sel"; return 2; }
  err=$(mktemp)  || { rm -f "$sel" "$body"; return 2; }

  # -s is deliberately omitted: --no-progress-meter drops the progress bar but
  # keeps the "curl: (28) ..." diagnostics on stderr, which we capture below.
  local -a curl_opts=()
  curl_opts=(--connect-timeout 3 -m 3 --retry 0 -k --no-progress-meter)

  printf '%-6s  %-*s  %-*s  %-8s  %-8s  %6s  %s\n' \
       RESULT "$wgroup" GROUP "$wurl" URL EXPECT ACTUAL TIME DETAIL

  local passed=0 failed=0 t0=$SECONDS
  local out="" rc="" code="" elapsed="" actual="" detail="" want="" got="" result="" colour=""

  while IFS='|' read -r group host scheme port expect; do
    url="$scheme://$host"
    [ -n "$port" ] && url="$url:$port"

    : >"$body"; : >"$err"
    out=$(curl "${curl_opts[@]}" -o "$body" -w '%{http_code} %{time_total}' \
           "$url" 2>"$err")
    rc=$?
    code=${out%% *}
    elapsed=${out##* }
    [ -n "$code" ] || code=000
    case "$elapsed" in ''|"$code") elapsed=0 ;; esac

    actual=$(_urltests_classify "$rc" "$code")

    # A 200 returns the JSON echo payload; .os.hostname names the backend
    # that actually answered, which is the interesting bit when several
    # could have. Anything else: surface curl's own diagnostic.
    if [ "$code" = 200 ]; then
      detail=$(jq -r '.os.hostname // "no hostname in response"' "$body" 2>/dev/null) \
        || detail='invalid JSON response'
    else
      detail=$(head -n1 "$err" | tr -d '\r')
    fi

    want=$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    got=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    if [ "$want" = "$got" ]; then
      result=PASS; colour=$c_pass; passed=$((passed + 1))
    else
      result=FAIL; colour=$c_fail; failed=$((failed + 1))
    fi

    printf '%s%-6s%s  %-*s  %-*s  %-8s  %-8s  %5.2fs  %s%s%s\n' \
         "$colour" "$result" "$c_off" \
         "$wgroup" "$group" "$wurl" "$url" "$expect" "$actual" \
         "$elapsed" "$c_dim" "$detail" "$c_off"
  done <"$sel"

  rm -f "$sel" "$body" "$err"

  if [ "$failed" -eq 0 ]; then colour=$c_pass; else colour=$c_fail; fi
  printf '\n%s%s tests: %s passed, %s failed%s  (%ss)\n' \
       "$colour" "$total" "$passed" "$failed" "$c_off" "$((SECONDS - t0))"

  [ "$failed" -eq 0 ] || return 1
  return 0
}

# Executed rather than sourced? Then just run it. Under zsh this file is only
# ever expected to be sourced, so the guard short-circuits there.
if [ -z "${ZSH_VERSION:-}" ] && [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  url_tests "$@"
fi
