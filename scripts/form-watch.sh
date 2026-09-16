#!/bin/bash

set -u

# -----------------------------------------------------------------------------
# FORM macOS development/release watcher
#
# Watches:
#   /Users/smielniczuk/Documents/works/form/archive/form-v*.zip
#
# Updates/tests/releases the local Git checkout, then deploys the verified
# source to root@mail:/var/www/mojoworks/labs/form.
#
# No environment variables are required.
# -----------------------------------------------------------------------------
WATCH_DIR="/Users/smielniczuk/Documents/works/form/archive"
DEST_DIR="/Users/smielniczuk/Documents/works/form"
ZIP_PATTERN="form-v*.zip"
REMOTE_HOST="root@mail"
REMOTE_DIR="/var/www/mojoworks/labs/form"
GIT_REMOTE="origin"
GIT_BRANCH="main"
GH_REPO="sylwesterdigital/form"

STATE_DIR="$DEST_DIR/.watch-state"
STATE_FILE="$STATE_DIR/last-processed"
LOCK_DIR="/tmp/form-watch.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
POLL_SECONDS=5
STABLE_SECONDS=3

# Do not retry a broken package every five seconds in the same watcher process.
# Restarting the watcher deliberately retries it.
LAST_ATTEMPT_SIGNATURE=""

mkdir -p "$WATCH_DIR" "$STATE_DIR"

acquire_lock() {
    local old_pid=""

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_PID_FILE"
        return 0
    fi

    if [[ -f "$LOCK_PID_FILE" ]]; then
        old_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
    fi

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "form-watch is already running (PID $old_pid)."
        return 1
    fi

    echo "Removing stale form-watch lock."
    rm -rf "$LOCK_DIR"

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "ERROR: could not create $LOCK_DIR"
        return 1
    fi

    printf '%s\n' "$$" > "$LOCK_PID_FILE"
}

cleanup() {
    if [[ -f "$LOCK_PID_FILE" ]] && [[ "$(cat "$LOCK_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

acquire_lock || exit 1
trap cleanup EXIT INT TERM HUP

get_signature() {
    shasum -a 256 "$1" | awk '{print $1}'
}

get_latest_zip() {
    find "$WATCH_DIR" \
        -maxdepth 1 \
        -type f \
        -name "$ZIP_PATTERN" \
        -exec stat -f '%m|%N' {} \; 2>/dev/null |
        sort -t'|' -k1,1nr |
        head -n 1 |
        cut -d'|' -f2-
}

wait_until_stable() {
    local file="$1"
    local sig1 sig2

    while true; do
        sig1="$(stat -f '%m|%z' "$file" 2>/dev/null || true)"
        sleep "$STABLE_SECONDS"
        sig2="$(stat -f '%m|%z' "$file" 2>/dev/null || true)"

        if [[ -n "$sig1" && "$sig1" == "$sig2" ]]; then
            return 0
        fi

        echo "ZIP is still being copied/written..."
    done
}

resolve_source_dir() {
    local tmp_dir="$1"
    local top_count only_item

    rm -rf "$tmp_dir/__MACOSX"

    top_count="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
    if [[ "$top_count" == "1" ]]; then
        only_item="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -print | head -n 1)"
        if [[ -d "$only_item" ]]; then
            printf '%s\n' "$only_item"
            return 0
        fi
    fi

    printf '%s\n' "$tmp_dir"
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

ensure_local_tools() {
    local missing=""
    local cmd

    for cmd in git python3 rsync unzip curl ssh shasum; do
        if ! check_command "$cmd"; then
            missing="$missing $cmd"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo "Missing required tools:$missing"
        if check_command brew; then
            echo ">>> Attempting to install missing tools with Homebrew"
            [[ "$missing" == *" python3"* ]] && brew install python || true
            [[ "$missing" == *" rsync"* ]] && brew install rsync || true
            [[ "$missing" == *" git"* ]] && brew install git || true
        fi
    fi

    for cmd in git python3 rsync unzip curl ssh shasum; do
        check_command "$cmd" || {
            echo "ERROR: required command '$cmd' is missing."
            return 1
        }
    done

    return 0
}

rsync_common_args() {
    # Kept as documentation only; Bash 3.2 has no safe array-return mechanism.
    :
}

sync_source() {
    local from="$1"
    local to="$2"

    rsync \
        --archive \
        --checksum \
        --delete \
        --exclude='.git/' \
        --exclude='.venv/' \
        --exclude='.env' \
        --exclude='.env.*' \
        --exclude='archive/' \
        --exclude='data/' \
        --exclude='logs/' \
        --exclude='release/' \
        --exclude='.watch-state/' \
        --exclude='.deploy-backups/' \
        --exclude='.playwright-browsers/' \
        --exclude='.pytest_cache/' \
        --exclude='__pycache__/' \
        --exclude='*.pyc' \
        --exclude='.DS_Store' \
        --exclude='scripts/form-watch.sh' \
        "$from/" \
        "$to/"
}

source_matches_repo() {
    local source_dir="$1"
    local status line path src dst

    # Recovery path for an interrupted release. Compare ONLY dirty Git paths
    # against the incoming package by file content. Do not compare the whole
    # tree with rsync: archive/runtime files and filesystem metadata (modes,
    # mtimes, etc.) can legitimately differ and previously caused false
    # "package differs" failures.
    cd "$DEST_DIR" || return 1
    status="$(git status --porcelain --untracked-files=all)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path="${line:3}"

        case "$path" in
            archive/*|.watch-state/*|.venv/*|release/*|data/*|logs/*|.deploy-backups/*|.playwright-browsers/*|.pytest_cache/*|*/__pycache__/*|*.pyc|.DS_Store|scripts/form-watch.sh)
                continue
                ;;
        esac

        # Renames/copies are deliberately treated as unsafe here. Generated
        # packages should arrive as normal add/modify/delete operations.
        case "${line:0:2}" in
            *R*|*C*)
                return 1
                ;;
        esac

        src="$source_dir/$path"
        dst="$DEST_DIR/$path"

        if [[ -e "$dst" || -L "$dst" ]]; then
            [[ -e "$src" || -L "$src" ]] || return 1

            if [[ -f "$dst" && -f "$src" ]]; then
                cmp -s "$dst" "$src" || return 1
            elif [[ -L "$dst" && -L "$src" ]]; then
                [[ "$(readlink "$dst")" == "$(readlink "$src")" ]] || return 1
            elif [[ -d "$dst" && -d "$src" ]]; then
                :
            else
                return 1
            fi
        else
            # A dirty path deleted locally is safe only if this release also
            # omits it.
            [[ ! -e "$src" && ! -L "$src" ]] || return 1
        fi
    done <<< "$status"

    return 0
}

repo_is_safe_to_update() {
    local source_dir="$1"
    local status line path blocked=""

    cd "$DEST_DIR" || return 1

    [[ -d .git ]] || {
        echo "ERROR: $DEST_DIR is not a Git repository."
        return 1
    }

    status="$(git status --porcelain --untracked-files=all)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path="${line:3}"

        case "$path" in
            archive/*|.watch-state/*|.venv/*|release/*|data/*|logs/*|.pytest_cache/*|*/__pycache__/*|*.pyc|.DS_Store|scripts/form-watch.sh)
                continue
                ;;
            *)
                blocked+="$line"$'\n'
                ;;
        esac
    done <<< "$status"

    if [[ -z "$blocked" ]]; then
        return 0
    fi

    # Important recovery behavior: if the working tree already contains exactly
    # the incoming package, the dirty files are from the previous failed watcher
    # run, not independent edits. Continue from verification/release instead of
    # trapping the repo in a permanent dirty state.
    if source_matches_repo "$source_dir"; then
        echo ">>> Existing uncommitted source matches this package; resuming interrupted release."
        return 0
    fi

    echo "ERROR: local repository has uncommitted source changes that differ from the incoming package."
    echo "Refusing to overwrite them:"
    printf '%s' "$blocked"
    return 1
}

prepare_local_python() {
    cd "$DEST_DIR" || return 1

    if [[ ! -x .venv/bin/python ]]; then
        echo ">>> Creating local Python virtual environment"
        python3 -m venv .venv || return 1
    fi

    echo ">>> Installing/updating Python dependencies"
    .venv/bin/python -m pip install --upgrade pip wheel || return 1
    .venv/bin/pip install -r requirements.txt || return 1

    if .venv/bin/python -c 'import playwright' >/dev/null 2>&1; then
        echo ">>> Ensuring Playwright Chromium is available"
        .venv/bin/python -m playwright install chromium || return 1
    fi
}

verify_local() {
    cd "$DEST_DIR" || return 1

    echo ">>> Running package verification"
    ./scripts/verify_package.sh || return 1

    echo ">>> Running tests and Flask health verification"
    ./scripts/verify.sh || return 1
}

stage_release_content() {
    local path

    cd "$DEST_DIR" || return 1

    # Clear staging left by an interrupted release without changing files.
    git reset --quiet || return 1

    # Stage modifications/deletions of tracked project files.
    git add -u || return 1

    # Stage new project files, but never runtime/generated directories.
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        case "$path" in
            archive/*|.watch-state/*|.venv/*|release/*|data/*|logs/*|.deploy-backups/*|.playwright-browsers/*|.pytest_cache/*|*/__pycache__/*|*.pyc|.DS_Store)
                continue
                ;;
        esac
        git add -- "$path" || return 1
    done <<EOF_UNTRACKED
$(git ls-files --others --exclude-standard)
EOF_UNTRACKED

    # Belt-and-braces: never allow local/runtime paths into the release commit.
    git reset --quiet -- \
        archive \
        .watch-state \
        .venv \
        release \
        data \
        logs \
        .deploy-backups \
        .playwright-browsers \
        .pytest_cache 2>/dev/null || true

    return 0
}

publish_release() {
    local zip_file="$1"
    local version="$2"
    local tag="v$version"
    local current commit tagged

    cd "$DEST_DIR" || return 1

    current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current" != "$GIT_BRANCH" ]]; then
        echo "ERROR: expected Git branch '$GIT_BRANCH', currently '${current:-detached}'."
        return 1
    fi

    git remote get-url "$GIT_REMOTE" >/dev/null 2>&1 || {
        echo "ERROR: Git remote '$GIT_REMOTE' is missing."
        return 1
    }

    git diff --name-only --diff-filter=U | grep -q . && {
        echo "ERROR: Git conflicts are present."
        return 1
    }

    echo ">>> Staging release content"
    stage_release_content || return 1

    if ! git diff --cached --quiet; then
        echo ">>> Committing $tag"
        git commit -m "Release $tag" || return 1
    else
        echo ">>> No new source changes to commit"
    fi

    commit="$(git rev-parse HEAD)"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        tagged="$(git rev-list -n1 "$tag")"
        if [[ "$tagged" != "$commit" ]]; then
            echo "ERROR: $tag already exists on a different commit."
            return 1
        fi
    else
        echo ">>> Creating tag $tag"
        git tag -a "$tag" -m "Release $tag" || return 1
    fi

    echo ">>> Pushing $GIT_BRANCH and $tag to GitHub"
    git push "$GIT_REMOTE" "$GIT_BRANCH" || return 1
    git push "$GIT_REMOTE" "$tag" || return 1

    # The incoming ZIP is already the exact verified release artifact. Reuse it
    # instead of rebuilding it on macOS (the package script is Linux-oriented).
    if check_command gh && gh auth status -h github.com >/dev/null 2>&1; then
        echo ">>> Publishing GitHub Release $tag"
        if gh release view "$tag" -R "$GH_REPO" >/dev/null 2>&1; then
            gh release upload "$tag" "$zip_file" --clobber -R "$GH_REPO" || return 1
        else
            gh release create "$tag" "$zip_file" \
                -R "$GH_REPO" \
                --title "$tag" \
                --generate-notes || return 1
        fi
    else
        echo "WARNING: Git branch/tag were pushed, but GitHub CLI is not authenticated."
        echo "         GitHub Release asset was skipped. One-time setup: gh auth login"
    fi

    return 0
}

deploy_remote() {
    echo ">>> Synchronising verified release to $REMOTE_HOST:$REMOTE_DIR"

    ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'" || return 1

    rsync \
        --archive \
        --checksum \
        --delete \
        --exclude='.git/' \
        --exclude='.venv/' \
        --exclude='.env' \
        --exclude='.env.*' \
        --exclude='archive/' \
        --exclude='data/' \
        --exclude='logs/' \
        --exclude='release/' \
        --exclude='.watch-state/' \
        --exclude='.deploy-backups/' \
        --exclude='.playwright-browsers/' \
        --exclude='.pytest_cache/' \
        --exclude='__pycache__/' \
        --exclude='*.pyc' \
        --exclude='.DS_Store' \
        "$DEST_DIR/" \
        "$REMOTE_HOST:$REMOTE_DIR/" || return 1

    echo ">>> Running remote deployment/restart/health checks"
    ssh "$REMOTE_HOST" \
        "cd '$REMOTE_DIR' && chmod +x deploy.sh scripts/*.sh && AUTO_GIT_RELEASE=0 ./deploy.sh --no-release" || return 1
}

mark_processed() {
    printf '%s\n' "$1" > "$STATE_FILE"
}

process_zip() {
    local zip_file="$1"
    local signature tmp_dir source_dir version previous_commit

    wait_until_stable "$zip_file"
    signature="$(get_signature "$zip_file")"

    if [[ -f "$STATE_FILE" && "$(cat "$STATE_FILE")" == "$signature" ]]; then
        return 0
    fi

    if [[ "$LAST_ATTEMPT_SIGNATURE" == "$signature" ]]; then
        return 0
    fi
    LAST_ATTEMPT_SIGNATURE="$signature"

    echo
    echo "============================================================"
    echo "New FORM package detected:"
    echo "$zip_file"
    echo "SHA256: $signature"
    echo "============================================================"

    ensure_local_tools || return 1

    tmp_dir="$(mktemp -d /tmp/form-update.XXXXXX)"

    echo ">>> Unpacking package"
    if ! unzip -q "$zip_file" -d "$tmp_dir"; then
        echo "ERROR: could not unzip package."
        rm -rf "$tmp_dir"
        return 1
    fi

    source_dir="$(resolve_source_dir "$tmp_dir")"

    [[ -f "$source_dir/VERSION" ]] || {
        echo "ERROR: package does not contain VERSION."
        rm -rf "$tmp_dir"
        return 1
    }
    [[ -f "$source_dir/app.py" ]] || {
        echo "ERROR: package does not contain app.py."
        rm -rf "$tmp_dir"
        return 1
    }
    [[ -x "$source_dir/scripts/verify_package.sh" ]] || {
        echo "ERROR: package verify script missing/not executable."
        rm -rf "$tmp_dir"
        return 1
    }

    version="$(tr -d '[:space:]' < "$source_dir/VERSION")"

    echo ">>> Verifying incoming package v$version"
    if ! "$source_dir/scripts/verify_package.sh"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    # This check happens after unpacking so an interrupted release can be safely
    # recognized by comparing the working tree with the exact incoming package.
    if ! repo_is_safe_to_update "$source_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    previous_commit="$(cd "$DEST_DIR" && git rev-parse HEAD)"

    echo ">>> Updating local repo: $DEST_DIR"
    if ! sync_source "$source_dir" "$DEST_DIR"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    if ! prepare_local_python || ! verify_local; then
        echo "ERROR: local verification failed. Restoring Git checkout."
        cd "$DEST_DIR" || return 1
        git reset --hard "$previous_commit"
        git clean -fd \
            -e archive/ \
            -e scripts/form-watch.sh \
            -e .venv/ \
            -e .env \
            -e data/ \
            -e logs/ \
            -e release/ \
            -e .watch-state/ \
            -e .playwright-browsers/
        return 1
    fi

    if ! publish_release "$zip_file" "$version"; then
        echo "ERROR: Git/GitHub release failed; remote deployment was NOT attempted."
        return 1
    fi

    if ! deploy_remote; then
        echo "ERROR: remote deployment failed. Git commit/tag remain published for diagnosis."
        return 1
    fi

    mark_processed "$signature"

    echo
    echo "============================================================"
    echo "FORM v$version RELEASED AND DEPLOYED SUCCESSFULLY"
    echo "Local:   $DEST_DIR"
    echo "GitHub:  $GIT_REMOTE / $GIT_BRANCH"
    echo "Server:  $REMOTE_HOST:$REMOTE_DIR"
    echo "============================================================"
}


echo "Form macOS release watcher started."
echo "Watching:    $WATCH_DIR/$ZIP_PATTERN"
echo "Local repo:  $DEST_DIR"
echo "Remote:      $REMOTE_HOST:$REMOTE_DIR"
echo "Git branch:  $GIT_REMOTE/$GIT_BRANCH"
echo

initial_zip="$(get_latest_zip)"
if [[ -n "$initial_zip" ]]; then
    echo "Latest package: $initial_zip"
else
    echo "No matching package found yet. Waiting for: $WATCH_DIR/$ZIP_PATTERN"
fi
echo

while true; do
    latest_zip="$(get_latest_zip)"
    if [[ -n "$latest_zip" && -f "$latest_zip" ]]; then
        process_zip "$latest_zip" || {
            echo
            echo "FORM UPDATE FAILED. This package will not be retried again in this watcher process."
            echo "Fix the reported issue and restart ./scripts/form-watch.sh to retry it."
            echo
        }
    fi

    sleep "$POLL_SECONDS"
done
