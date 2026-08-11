#!/usr/bin/env bash
# change-census.sh — heuristic completeness census for a work branch.
#
# WHY: Symphony's dominant defect is incomplete propagation of a change — a
# signature/field changes but some callers or writers are never updated. The
# plan and the grader judge completeness against row states and the diff, so a
# caller in an UNTOUCHED file is invisible to them. This script re-derives, from
# the actual diff, "what else in the repo references the things this diff
# changed, and were those references left behind?"
#
# For every function/field the branch changed, it lists references ELSEWHERE in
# the repo (files the diff did NOT touch). It also flags new modules with no
# caller outside their own file (dead code) and unpushed local commits.
#
# It is EVIDENCE for a reviewer, never an auto-gate: grep-based, tuned toward
# recall, so it will over-report common names. A human/LLM reviewer decides
# which hits are real. Run from the repo working tree.
#
#   Usage: change-census.sh [base_branch]      # default: $BASE_BRANCH or main
#
# ponytail: grep census, not an AST call-graph. Upgrade to real reference
# analysis only if the false-positive rate proves unworkable in review.
set -uo pipefail

BASE="${1:-${BASE_BRANCH:-main}}"
# CENSUS_RANGE lets a caller point the census at an arbitrary git range (e.g.
# replaying a merged PR for validation: CENSUS_RANGE="<base>..<merge-sha>").
if [ -n "${CENSUS_RANGE:-}" ]; then
  RANGE="$CENSUS_RANGE"
else
  git fetch origin "$BASE" >/dev/null 2>&1 || true
  RANGE="origin/${BASE}..HEAD"
fi

CHANGED_FILES="$(git diff --name-only "$RANGE" -- '*.ex' '*.exs' 2>/dev/null)"
if [ -z "$CHANGED_FILES" ]; then
  echo "(change census: no Elixir changes vs origin/${BASE})"
  exit 0
fi

is_changed() { grep -qxF "$1" <<<"$CHANGED_FILES"; }

# Production callers are what completeness hinges on, so the census greps `lib/`
# only — this drops the deps/, priv/migrations, storybook/, and test/ noise that
# a repo-wide grep drags in. (Tests are verified in the Test phase, not here.)
SEARCH="lib"
[ -d lib ] || SEARCH="."

# --- changed function names ---------------------------------------------------
# Functions whose def line the diff touched — the "signature/contract changed,
# did every caller follow?" case (the #1 defect). Fields are deliberately NOT
# censused here: bare-field grep is mostly noise, and the un-updated-writer case
# is better caught by the cold-review lens. Skip framework callbacks (no
# app-code callers) and keep names >=3 chars. Cap to bound the grep loop.
SYMBOLS="$(git diff -U0 "$RANGE" -- '*.ex' '*.exs' 2>/dev/null \
  | grep -E '^[+-][[:space:]]*defp?[[:space:]]' \
  | sed -E 's/^[+-][[:space:]]*defp?[[:space:]]+([a-z_][A-Za-z0-9_]*[?!]?).*/\1/' \
  | grep -E '^[a-z_][A-Za-z0-9_]{2,}[?!]?$' \
  | grep -Ev '^(mount|render|handle_event|handle_info|handle_call|handle_cast|init|changeset|new|call)$' \
  | sort -u | head -60)"

echo "## Change census (heuristic — references OUTSIDE this diff)"
echo
echo "The branch changed the symbols below; each is still referenced from lib/ by"
echo "files the diff did NOT touch. If the change altered a signature, return shape,"
echo "or field meaning, those references likely need updating too. Verify each"
echo "before approving — a green suite does not prove the callers were carried."
echo "(Ultra-common names with >25 external refs are dropped as low-signal.)"
echo

# Collect "name<TAB>count<TAB>samples" then show the modest-count ones first —
# a handful of stray callers is high signal; hundreds is a common name, noise.
report="$(
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    # Match call syntax `name(` (incl. `.name(`, `Mod.name(`, `|> name(`), not
    # the bare word — this drops comment prose and same-named local variables.
    hits="$(grep -rnE --include='*.ex' --include='*.exs' -e "\b${name}\(" "$SEARCH" 2>/dev/null | sed 's|^\./||')"
    [ -z "$hits" ] && continue
    # Files that DEFINE their own `def/defp name(` — a `name(` call in such a
    # file is that file's own same-named helper (or a different module's
    # function that merely shares the name), not a caller of the changed
    # function. Excluding them is the single biggest noise cut.
    deffiles="$(grep -rlE --include='*.ex' --include='*.exs' -e "^[[:space:]]*(def|defp)[[:space:]]+${name}[( ]" "$SEARCH" 2>/dev/null | sed 's|^\./||')"
    ext=""
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      f="${line%%:*}"
      is_changed "$f" && continue
      grep -qxF "$f" <<<"$deffiles" && continue           # own/same-name helper
      case "$line" in *"${name}(s)"*) continue ;; esac    # plural prose: job(s), table(s)
      ext+="$line"$'\n'
    done <<<"$hits"
    ext="$(grep -v '^$' <<<"$ext" 2>/dev/null || true)"
    [ -z "$ext" ] && continue
    cnt="$(grep -c . <<<"$ext")"
    { [ "$cnt" -lt 1 ] || [ "$cnt" -gt 25 ]; } && continue
    samples="$(head -3 <<<"$ext" | sed 's/^/    /')"
    printf '%s\t%s\t%s\n' "$cnt" "$name" "$samples" | tr '\n' '\v'
    echo
  done <<<"$SYMBOLS" | sort -n | head -20
)"

if [ -n "$report" ]; then
  while IFS=$'\t' read -r cnt name samples; do
    [ -z "$name" ] && continue
    printf -- '- `%s` — %s ref(s) in untouched lib/ files:\n' "$name" "$cnt"
    printf '%s\n' "$samples" | tr '\v' '\n' | grep -v '^$'
  done <<<"$report"
else
  echo "(no changed symbol has 1–25 external lib/ references — self-contained change)"
fi

# --- possibly-dead new modules ----------------------------------------------
# Only lib/ modules — a new module under test/ or test/support/ has no lib/
# caller by construction and would always false-flag as dead.
NEW_MODULES="$(git diff -U0 "$RANGE" -- 'lib/' 2>/dev/null \
  | grep -E '^\+[[:space:]]*defmodule[[:space:]]' \
  | sed -E 's/^\+[[:space:]]*defmodule[[:space:]]+([A-Za-z0-9_.]+).*/\1/' \
  | sort -u)"
if [ -n "$NEW_MODULES" ]; then
  dead=""
  while IFS= read -r mod; do
    [ -z "$mod" ] && continue
    short="${mod##*.}"
    # Count references in a MODULE position — full dotted name, `Short.` call,
    # an `alias`, or a list/router slot (`, Short`, `{.., Short}`). A bare word
    # match falsely counts prose/other identifiers and hides genuinely-dead
    # modules; the aliased forms are how routers/LiveViews wire a module in.
    nfiles="$(grep -rlE --include='*.ex' --include='*.exs' \
                -e "${mod//./\\.}" \
                -e "\b${short}\." \
                -e "alias[[:space:]].*\b${short}\b" \
                -e "[,{][[:space:]]*${short}\b" \
                "$SEARCH" 2>/dev/null \
              | grep -v '_test\.exs$' | grep -c .)"
    [ "$nfiles" -le 1 ] && dead+="- \`$mod\` — referenced in ≤1 non-test file; likely defined but never wired in."$'\n'
  done <<<"$NEW_MODULES"
  if [ -n "$dead" ]; then
    echo
    echo "### Possibly dead code (new module, no caller outside its own file)"
    printf '%s' "$dead"
  fi
fi

# --- delivery integrity ------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -n "$BRANCH" ] && git rev-parse --verify -q "origin/$BRANCH" >/dev/null 2>&1; then
  ahead="$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    echo
    echo "### Delivery"
    echo "- ⚠ local HEAD is ${ahead} commit(s) ahead of origin/${BRANCH} — unpushed work."
  fi
fi
