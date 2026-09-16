#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
BRANCH="${RELEASE_BRANCH:-main}"
GH_REPO="${GH_REPO:-sylwesterdigital/form}"
STRICT="${STRICT_RELEASE:-0}"

fail_or_warn() {
  if [[ "$STRICT" == 1 ]]; then
    echo "ERROR: $*" >&2
    exit 1
  fi
  echo "WARNING: $*" >&2
  exit 0
}

command -v git >/dev/null 2>&1 || fail_or_warn "git is not installed; skipping Git release."
[[ -d .git ]] || fail_or_warn "$ROOT is not a Git checkout; skipping Git release."

git diff --name-only --diff-filter=U | grep -q . && fail_or_warn "Git conflicts are present."

current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ "$current" == "$BRANCH" ]] || fail_or_warn "Expected branch $BRANCH, current branch is ${current:-detached}."

if ! git remote get-url origin >/dev/null 2>&1; then
  fail_or_warn "Git remote origin is missing."
fi

# Commit synchronized release content if it changed.
git add -A -- . ':(exclude)archive' ':(exclude)data' ':(exclude)release' ':(exclude).env'
if ! git diff --cached --quiet; then
  git commit -m "Release $TAG"
fi

commit="$(git rev-parse HEAD)"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  tagged="$(git rev-list -n1 "$TAG")"
  [[ "$tagged" == "$commit" ]] || fail_or_warn "$TAG already exists on a different commit."
else
  git tag -a "$TAG" -m "Release $TAG"
fi

echo ">>> Pushing $BRANCH and $TAG"
git push origin "$BRANCH" || fail_or_warn "Could not push $BRANCH."
git push origin "$TAG" || fail_or_warn "Could not push $TAG."

"$ROOT/scripts/package_release.sh" >/dev/null
asset="$ROOT/release/form-v$VERSION.zip"

if command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1; then
  if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$asset" --clobber -R "$GH_REPO" || fail_or_warn "Could not upload release asset."
  else
    gh release create "$TAG" "$asset" -R "$GH_REPO" --title "$TAG" --generate-notes || fail_or_warn "Could not create GitHub release."
  fi
  echo "GitHub release published: $GH_REPO $TAG"
else
  echo "WARNING: GitHub CLI is not installed/authenticated; Git branch/tag were pushed but GitHub Release was skipped." >&2
fi
