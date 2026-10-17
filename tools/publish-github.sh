#!/bin/sh
# Publish this repo to GitHub (6Leokk/changxing60-linux) from a sanitized clone.
#
# WHY A CLONE AND NOT PUSHING THIS REPO. The history here contains the factory Wi-Fi/BT MACs of one
# specific device (docs/FINDINGS.md and the wifi-fix test recorded them before the redaction policy
# reached MACs -- the original credential sweep only covered passwords/PSK/IMEI/serials, and a MAC
# slipped through that net). Pushing this repo directly would publish those bytes forever. Rewriting
# the live repo's history in place would change every commit hash our docs and state snapshots cite
# (84dd770, 0931300, ...), so instead we rewrite a throwaway clone every time: deterministic
# (same inputs + same replace rules -> same output hashes), so incremental pushes stay fast and
# --force-with-lease is only ever a no-op re-apply.
#
# WHAT IT DOES
#   0. shallow guard (see the note at the end)
#   1. fresh clone of this repo (branches + reachable tags)
#   2. git filter-repo over that clone: --replace-text (credential redaction, rules file below),
#      --mailmap-file (all authors/committers collapse to the one project account) and a
#      message-callback that strips AI co-author trailers -- see the filter step for why
#   3. a hard verification sweep: every pattern in the credential-pattern file, -a binary-aware,
#      across every revision of the clone. Any hit aborts before anything leaves the machine.
#   4. push OUR line (mainline-5.4) + tags to the GitHub repo (idempotent); no other branch is
#      mirrored -- see the push step
#
# NONE OF THE TRUTH-BEARING FILES IS IN THE REPO. The replace rules quote the real MACs, the pattern
# file quotes every credential the policy covers, and the mailmap quotes the real person-identities
# it collapses; all live outside the checkout (~/.local/share/zte7552n-private/). This script
# knowing their paths is by design -- a publish tool that embeds the secrets it hunts would leak
# exactly what it is guarding, and a sweep that "exempted" its own source would be a guard that had
# already lost.
#
# Requires: git, git-filter-repo (https://github.com/newren/git-filter-repo, a single python file).
# Never pushes to origin (the fork-base remote) -- that remote is only ever fetched from.
#
# 2026-10-17: the inner repo was cloned SHALLOW (grafted) without anyone noticing, so "the full
# upstream history" was actually a 46-commit stub and every GitHub push failed with
# "remote: fatal: did not receive expected object ..." -- GitHub refuses shallow input. Run
# `git fetch --unshallow origin` first if step 0 says the repo is still shallow.

set -eu
TOP=$(cd "$(dirname "$0")/.." && pwd)
PRIVATE=${CHANGXING60_PRIVATE_DIR:-$HOME/.local/share/zte7552n-private}
RULES=${CHANGXING60_REDACT_RULES:-$PRIVATE/publish-redact.txt}
PATTERN_FILE=${CHANGXING60_SWEEP_PATTERNS:-$PRIVATE/credential-patterns.txt}
MAILMAP=${CHANGXING60_MAILMAP:-$PRIVATE/publish-mailmap.txt}
GITHUB_URL=${GITHUB_URL:-https://github.com/6Leokk/changxing60-linux}
WORK=$(mktemp -d /tmp/changxing60-publish.XXXXXX)

say() { printf 'publish: %s\n' "$*"; }
die() { printf 'publish: %s\n' "$*" >&2; rm -rf "$WORK"; exit 1; }

command -v git-filter-repo >/dev/null 2>&1 || command -v git-filter-repo.py >/dev/null 2>&1 \
	|| die "git-filter-repo not found (pip install git-filter-repo, or drop the script on PATH)"
[ -s "$RULES" ] || die "redact rules missing: $RULES (see the WHY-NO-SECRETS-IN-REPO note above)"
[ -s "$PATTERN_FILE" ] || die "credential pattern file missing: $PATTERN_FILE"
[ -s "$MAILMAP" ] || die "mailmap file missing: $MAILMAP (author-unification rules; see step 2)"

if [ "$(git -C "$TOP" rev-parse --is-shallow-repository)" = true ]; then
	die "this repo is a shallow clone; run: git -C $TOP fetch --unshallow origin"
fi

say "cloning $TOP into $WORK"
git clone -q --no-hardlinks "$TOP" "$WORK/repo" || die "clone failed"
cd "$WORK/repo"

say "filter-repo: replace-text + mailmap + Claude co-author trailers"
# --mailmap maps every non-owner author/committer email (fork base, bots) onto the one project
# account (newer filter-repo renames this flag to --mailmap-file), and the message-callback drops
# the Co-Authored-By: Claude trailers that GitHub would otherwise count as a contributor.
# Together: Contributors shows exactly one person. This rewrites EVERY hash -- hence the --force on
# the branch push below. The live repo keeps its true authorship.
git filter-repo --force --replace-text "$RULES" --mailmap "$MAILMAP" \
	--message-callback 'import re; message = re.sub(rb"Co-[Aa]uthored-[Bb]y: Claude[^\n]*\n?", b"", message); message = re.sub(rb"\n{3,}", b"\n\n", message); return message' \
	>/dev/null || die "filter-repo failed"

say "verification sweep over every revision (pattern file: $PATTERN_FILE)"
ARGS=""; while IFS= read -r p; do [ -n "$p" ] && [ "${p#\#}" = "$p" ] && ARGS="$ARGS -e $p"; done < "$PATTERN_FILE"
HITS=$(git grep -a -l $ARGS $(git rev-list --all) 2>/dev/null || true)
[ -z "$HITS" ] || die "pattern hits remain in the rewritten history:
$HITS"
say "sweep clean ($(printf '%s\n' "$ARGS" | wc -w) patterns, all revisions)"

say "pushing our line + tags to $GITHUB_URL"
# The repo has exactly one line we publish: mainline-5.4 (renamed from mainline-6.18 on 2026-10-18,
# named after the production kernel 5.4.254). The old `mainline-6.18`, the early-history branch
# `7552n-port`, and the fork base's `main` are all ancestors of the tip or not ours to mirror --
# nothing else goes out.
# (The mailmap rewrite changes all hashes, so this is --force, not a fast-forward push: the rules
# are deterministic, nobody else writes to this remote, and a no-op re-apply is still identical.)
git push -q --force "$GITHUB_URL" refs/heads/mainline-5.4:refs/heads/mainline-5.4 || die "branch push failed"
# Tags: push ONLY our own (frozen-*) -- a bare `--tags` would re-publish the fork base's ~40 daily
# v2026.* tags and its test leftovers, which are upstream's release ceremony, not ours. (Moved a
# frozen tag before: the push is per-tag and --force, so a re-creatable release target still lands.)
for t in $(git tag -l 'frozen-*'); do
	git push -q --force "$GITHUB_URL" "refs/tags/$t" || say "tag push failed for $t (branches are out)"
done

cd /
rm -rf "$WORK"
say "done: $GITHUB_URL"
