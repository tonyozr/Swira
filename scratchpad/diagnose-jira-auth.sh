#!/usr/bin/env bash
# Diagnoses "getting a login page instead of JSON" against a production Jira instance.
#
# Usage:
#   JIRA_URL='https://jira.example.com' JIRA_PAT='<token>' ./diagnose-jira-auth.sh
#
# Does not print the token. Read-only GET requests only.

set -u

if [[ -z "${JIRA_URL:-}" ]]; then
  echo "JIRA_URL is not set." >&2
  exit 1
fi
if [[ -z "${JIRA_PAT:-}" ]]; then
  echo "JIRA_PAT is not set." >&2
  exit 1
fi

# Normalize: strip trailing slash.
BASE="${JIRA_URL%/}"

echo "== Target =="
echo "JIRA_URL: $BASE"
echo "Token length: ${#JIRA_PAT} chars"
echo

# describe <label> <curl-args...>
# Runs the request without following redirects first (to catch SSO redirects),
# then reports status, content-type, any Location header, and a body snippet.
describe() {
  local label="$1"; shift
  echo "---- $label ----"
  local out
  out=$(curl -s -D - -o /tmp/diagnose_body.$$ --max-time 15 "$@" 2>&1)
  local curl_status=$?
  if [[ $curl_status -ne 0 ]]; then
    echo "curl failed (exit $curl_status) — network/TLS/DNS issue, not an auth issue."
    echo "$out"
    echo
    return
  fi
  local status_line
  status_line=$(echo "$out" | head -1)
  local content_type
  content_type=$(echo "$out" | grep -i '^content-type:' | head -1)
  local location
  location=$(echo "$out" | grep -i '^location:' | head -1)
  echo "$status_line"
  [[ -n "$content_type" ]] && echo "$content_type"
  [[ -n "$location" ]] && echo "$location"
  echo "Body snippet:"
  head -c 300 /tmp/diagnose_body.$$ | tr -d '\r'
  echo
  echo
  rm -f /tmp/diagnose_body.$$
}

# 1. Is the site reachable at all, unauthenticated?
describe "Base URL, no auth, no redirects followed" \
  -i "$BASE/"

# 2. Bearer auth (what swira-web sends when JIRA_PAT is set without JIRA_EMAIL)
#    against each plausible API version/base, no redirects followed so a 302 to
#    an SSO login page is visible instead of silently followed into an HTML page.
describe "Bearer + /rest/api/3/myself (Cloud-style path, no redirect)" \
  -H "Authorization: Bearer $JIRA_PAT" -H "Accept: application/json" \
  "$BASE/rest/api/3/myself"

describe "Bearer + /rest/api/2/myself (Data Center-style path, no redirect)" \
  -H "Authorization: Bearer $JIRA_PAT" -H "Accept: application/json" \
  "$BASE/rest/api/2/myself"

describe "Bearer + /rest/api/latest/myself, no redirect" \
  -H "Authorization: Bearer $JIRA_PAT" -H "Accept: application/json" \
  "$BASE/rest/api/latest/myself"

# 3. Same, but following redirects — shows what the login page actually is
#    (SSO provider, Jira's own login form, a WAF challenge, etc.) and its final URL.
describe "Bearer + /rest/api/2/myself, following redirects" \
  -H "Authorization: Bearer $JIRA_PAT" -H "Accept: application/json" \
  -L -w '\nFinal URL: %{url_effective}\n' \
  "$BASE/rest/api/2/myself"

# 4. Sidebar's actual endpoints, in case /myself works but filter search doesn't
#    (permission/plugin issue rather than a blanket auth issue).
describe "Bearer + /rest/api/2/filter/my, no redirect" \
  -H "Authorization: Bearer $JIRA_PAT" -H "Accept: application/json" \
  "$BASE/rest/api/2/filter/my"

# 5. Basic auth fallback, in case this is actually a Cloud-style site that wants
#    email:token rather than a bearer PAT (misconfigured JIRA_PAT vs JIRA_API_TOKEN).
describe "Basic (token as password, blank user) + /rest/api/2/myself, no redirect" \
  -u ":$JIRA_PAT" -H "Accept: application/json" \
  "$BASE/rest/api/2/myself"

echo "== How to read this =="
echo "- 200 + application/json body  -> that combination works; point swira-web at it."
echo "- 302/303 + Location header    -> a proxy/SSO is intercepting the request before"
echo "  it reaches Jira. The Location tells you where (login IdP, Jira's own login"
echo "  form, a WAF). This is the likely cause of 'HTML login page instead of JSON'."
echo "- 401 + JSON body               -> reached Jira, but the PAT itself is rejected"
echo "  (expired, revoked, wrong site)."
echo "- 200 + text/html body, no redirect -> Jira (or a proxy in front of it) is"
echo "  serving its login form directly for this path/version — often means the"
echo "  API path/version is wrong for this deployment, or anonymous access is denied"
echo "  and the server degrades to a login page instead of a 401 for API calls."
