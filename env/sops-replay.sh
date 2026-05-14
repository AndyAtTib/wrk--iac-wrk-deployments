#!/bin/bash
# sops-replay.sh — re-encrypt SOPS files commit-by-commit during a git rebase.
#
# Dot-source into the shell that drives the rebase (after sourcing the git
# toolkit so yn/read_val/_do_log are available). Each rebase --exec also
# re-sources this file so fixup-files runs in the exec subshell.
#
# Plan: /home/vscode/.claude/plans/if-you-do-sops-splendid-sutton.md
#
# Public:  init-sops-rebase, fixup-files
# Private: _sops_input_type _is_sops_path _verify_sops_file
#          _apply_added_sops _apply_modified_sops _apply_renamed_edited_sops
#          _show_plain_diff _show_sops_diff

# --- helpers ----------------------------------------------------------------

_sops_input_type() {
  # Map a path to a sops --input-type / --output-type value.
  case "$1" in
    *.yaml|*.yml) echo yaml ;;
    *.json)       echo json ;;
    *.env|*/tool.env|tool.env) echo dotenv ;;
    *)            echo yaml ;;
  esac
}

_is_sops_path() {
  # SOPS-managed iff the path's diff attribute is one of our sopsdiffer_* values.
  # .gitattributes already enumerates the full set (deps/** + gl-vars/**).
  local attr
  attr=$(git check-attr diff -- "$1" 2>/dev/null | awk -F': ' '{print $NF}')
  [[ $attr == sopsdiffer_deps || $attr == sopsdiffer_glvs ]]
}

_verify_sops_file() {
  # 1. decrypts cleanly  2. stored encrypted_regex is broad (^.+$)
  local p="$1"
  if ! sops -d -- "$p" >/dev/null 2>&1; then
    _do_log "error" "sops -d failed for $p"
    return 1
  fi
  local rx
  rx=$(awk '/^sops:/{f=1} f && /encrypted_regex:/{print; exit}' "$p")
  if [[ "$(basename "$p")" == "dep.yaml" ]]; then
    # do nothing
  elif [[ "$(basename "$p")" == "tool.env" ]]; then
    # do nothing
  elif [[ "$(basename "$p")" =~ env-.+\.sops\.json$ ]]; then
    # do nothing
  elif [[ $rx != *'^.+$'* ]]; then
    _do_log "error" "stored encrypted_regex for $p is not ^.+\$: $rx"
    return 1
  fi
  return 0
}

_apply_added_sops() {
  # A-SOPS: replace -X theirs result with ORIGINAL bytes, then decrypt+re-encrypt
  # so the file gets new IVs AND the new (broad) encrypted_regex from the
  # working-tree .sops.yaml baked into its stored metadata.
  # `sops -e` discovers .sops.yaml relative to CWD (not the file path), so run
  # it from the file's directory. Subshell scopes the cd — no popd needed even
  # on failure paths.
  local p="$1"
  git checkout ORIGINAL -- "$p" || return 1
  (
    cd -- "$(dirname "$p")" || exit 1
    sops -d -i -- "$(basename "$p")" || exit 1
    sops -e -i -- "$(basename "$p")" || exit 1
  ) || return 1
}

_apply_modified_sops() {
  # M-SOPS: seed the working tree with the rebased parent's NEW-rules ciphertext,
  # then run a single `sops edit` session that overwrites the decrypted tempfile
  # with the original commit's plaintext. The IV stash in sops's Cipher reuses
  # IVs for leaves whose plaintext is unchanged → minimal ciphertext diff.
  local p="$1"
  local t plain rc
  t=$(_sops_input_type "$p")
  plain=$(mktemp --suffix=".${p##*.}")
  _do_log "debug" "decrypting ORIGINAL:$p to $plain for sops edit input"
  if ! git show "ORIGINAL:$p" | sops -d --input-type "$t" --output-type "$t" /dev/stdin > "$plain"; then
    _do_log "error" "could not decrypt ORIGINAL:$p"
    rm -f "$plain"
    return 1
  fi
  if ! git show "HEAD~:$p" > "$p"; then
    _do_log "error" "could not read HEAD~:$p (parent must have the file for M)"
    rm -f "$plain"
    return 1
  fi
  _do_log "debug" "running sops edit"
  EDITOR="cp $plain" sops -- "$p"
  rc=$?
  _do_log "debug" "sops edit finished with exit code $rc"
  rm -f "$plain"
  return $rc
}

_apply_renamed_edited_sops() {
  # R<100-SOPS: same idea as M-SOPS but the parent's ciphertext lives at p1 and
  # the new path is p2.
  local p1="$1" p2="$2"
  local t plain rc
  t=$(_sops_input_type "$p2")
  plain=$(mktemp --suffix=".${p2##*.}")
  if ! git show "ORIGINAL:$p2" | sops -d --input-type "$t" --output-type "$t" /dev/stdin > "$plain"; then
    _do_log "error" "could not decrypt ORIGINAL:$p2"
    rm -f "$plain"
    return 1
  fi
  if ! git show "HEAD~:$p1" > "$p2"; then
    _do_log "error" "could not read HEAD~:$p1 (parent must have the old path for R<100)"
    rm -f "$plain"
    return 1
  fi
  EDITOR="cp $plain" sops -- "$p2"
  rc=$?
  rm -f "$plain"
  return $rc
}

_show_plain_diff() {
  # Sopsdiffer textconv in .git/config decrypts blobs on the fly → plaintext diff.
  # NOTE: `status` is a read-only special in zsh; use `gitstatus` everywhere instead.
  # Diff against the WORKING TREE (not HEAD:$p2): at this point in fixup-files the
  # amend hasn't happened yet, so HEAD:$p2 is still the cherry-pick's stale content
  # (ORIGINAL bytes via -X theirs). The freshly re-encrypted file is in the WT.
  # `git diff HEAD~ -- $p1 $p2` with rename detection finds the p1→p2 match.
  local gitstatus="$1" p1="$2" p2="$3"
  if [[ $gitstatus == R* || $gitstatus == C* ]]; then
    git -c core.pager=cat diff -M --color=always HEAD~ -- "$p1" "$p2" | less -R
  else
    git -c core.pager=cat diff --color=always HEAD~ -- "$p1" | less -R
  fi
}

_show_sops_diff() {
  # --no-textconv bypasses sopsdiffer → raw ciphertext diff.
  # Same WT-vs-HEAD~ pattern as _show_plain_diff (see comment above for why).
  local gitstatus="$1" p1="$2" p2="$3"
  if [[ $gitstatus == R* || $gitstatus == C* ]]; then
    git -c core.pager=cat diff -M --color=always --no-textconv HEAD~ -- "$p1" "$p2" | less -R
  else
    git -c core.pager=cat diff --color=always --no-textconv HEAD~ -- "$p1" | less -R
  fi
}

# --- init-sops-rebase -------------------------------------------------------

init-sops-rebase() {
  local current_branch
  current_branch=$(git branch --show-current)
  if [[ $current_branch != "dwt/dwt-1" ]]; then
    _do_log "error" "init-sops-rebase must run on branch dwt/dwt-1 (current: $current_branch)"
    return 1
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    _do_log "error" "working tree must be clean before starting the rebase"
    return 1
  fi

  if ! sops --version >/dev/null 2>&1; then
    _do_log "error" "sops not found on PATH"
    return 1
  fi

  local fp
  fp=$(awk '/pgp:/ {print $2; exit}' deps/.sops.yaml 2>/dev/null)
  if [[ -z $fp ]]; then
    _do_log "error" "could not read PGP fingerprint from deps/.sops.yaml"
    return 1
  fi
  if ! gpg --list-secret-keys "$fp" >/dev/null 2>&1; then
    _do_log "error" "GPG private key $fp not available (needed for sops)"
    return 1
  fi

  local backup="dwt/dwt-1-pre-sops-rebase-$(date +%s)"
  git branch "$backup" || return 1

  _do_log "ok"   "backup branch created: $backup"
  _do_log "info" "sops: $(sops --version 2>&1 | head -1)"
  _do_log "info" "gpg key $fp available"
  _do_log "info" "ready. paste this to start the rebase (it re-sources git.sh + this script in each exec subshell):"

  cat <<'EOF'

git rebase --update-refs -X theirs -i \
  --exec '. /workspaces/iac-wrk-workspace/toolkits/git/src/git.sh >/dev/null && . "$(git rev-parse --show-toplevel)/env/sops-replay.sh" && fixup-files' \
  --onto todo/sops-rebase-onto develop dwt/dwt-1

EOF
  return 0
}

# --- fixup-files ------------------------------------------------------------
fixup-files-exec() {
  _do-fixup-files || {
    _do_log "error" "fixup-files failed; you can fix the issue manually, then run 'git rebase --continue' to resume the rebase. If you need to restart the rebase from the backup branch, run 'git rebase --abort' followed by 'git checkout dwt/dwt-1-pre-sops-rebase-<timestamp>'."
    exit 1
  }
}

_do-fixup-files() {
  local rl=$(git rev-parse --git-dir)/rebase-merge/rewritten-list
  local dn=$(git rev-parse --git-dir)/rebase-merge/done

  local picked
  picked=$(git rev-parse HEAD)

  if [[ ! -f $rl ]]; then
    _do_log "error" "$rl does not exist — set the first rebased commit to 'reword' (or 'edit') so this file is created. returning 1."
    return 1
  fi

  local original
  original=$(awk -v p="$picked" '$2==p {print $1}' "$rl" | tail -1)
  if [[ -z $original ]]; then
    _do_log "error" "could not locate $picked in $rl"
    return 1
  fi

  # Cross-check: the last pick/reword/edit line in done should name $original.
  if [[ -f $dn ]]; then
    local done_orig
    done_orig=$(awk '/^(pick|reword|edit|squash|fixup) /{last=$2} END{print last}' "$dn")
    if [[ -n $done_orig && $done_orig != "$original" ]]; then
      # $done_orig is sometimes a short SHA; rev-parse to compare full SHAs.
      local done_orig_full
      done_orig_full=$(git rev-parse --verify --quiet "$done_orig" 2>/dev/null)
      if [[ -z $done_orig_full || $done_orig_full != "$original" ]]; then
        _do_log "warn" "rewritten-list and done disagree on the original commit:"
        _do_log "warn" "  rewritten-list             PICKED=$picked ->"
        _do_log "warn" "                               ORIGINAL=$original"
        _do_log "warn" "  done last pick-like entry    ORIGINAL=${done_orig_full:-$done_orig}"
        _do_log "warn" "this can happen if a previous exec returned 1 and was retried after a manual amend, or if the TODO contains squash/fixup that reshape the mapping. proceeding will use the rewritten-list value; if that is wrong, 'git show ORIGINAL:<path>' will read the wrong blob."
        yn "continue anyway, using rewritten-list value as \$original" || return 1
      fi
    fi
  fi

  git tag -f ORIGINAL "$original" >/dev/null
  git tag -f PICKED   "$picked"   >/dev/null

  # Idempotency: ensure HEAD sits at PICKED (no-op on the first run of this iteration).
  git checkout PICKED >/dev/null 2>&1 || true

  git diff-tree -r -M --no-commit-id --name-status PICKED

  # Collect (gitstatus, p1, p2) tuples from the just-picked commit.
  # NOTE: `status` is a read-only special in zsh; use `gitstatus` instead.
  local lines gitstatus p1 p2
  while IFS=$'\t' read -r gitstatus p1 p2; do
    [[ -z $gitstatus ]] && continue
    _do_log "info" "→ processing $gitstatus $p1${p2:+ → $p2}"

    # ---- idempotency reset for this file ----
    case "$gitstatus" in
      D)
        : # already removed by cherry-pick
        ;;
      R*|C*)
        [[ -e $p1 ]] && git rm -f -- "$p1" >/dev/null 2>&1 || true
        git checkout HEAD -- "$p2" 2>/dev/null || true
        ;;
      *)
        git checkout HEAD -- "$p1" 2>/dev/null || true
        ;;
    esac

    # ---- pick rule + apply ----
    local rule="" target="$p1"
    [[ -n $p2 ]] && target="$p2"

    case "$gitstatus" in
      A)
        if _is_sops_path "$p1"; then
          rule="A-SOPS"
          _apply_added_sops "$p1" || { _do_log "error" "_apply_added_sops failed for $p1"; return 1; }
        else
          rule="A-nonsops"
        fi
        ;;
      M)
        if _is_sops_path "$p1"; then
          rule="M-SOPS"
          _apply_modified_sops "$p1" || { _do_log "error" "_apply_modified_sops failed for $p1"; return 1; }
        else
          rule="M-nonsops"
        fi
        ;;
      D)
        rule="D"
        ;;
      R100|C100)
        rule="${gitstatus}-nonedit"
        ;;
      R*|C*)
        if _is_sops_path "$p2"; then
          rule="R-edit-SOPS"
          _apply_renamed_edited_sops "$p1" "$p2" \
            || { _do_log "error" "_apply_renamed_edited_sops failed for $p1 -> $p2"; return 1; }
        else
          rule="R-edit-nonsops"
        fi
        ;;
      *)
        rule="$gitstatus"
        _do_log "warn" "no rule for status $gitstatus on $p1 — treating as no-op"
        ;;
    esac

    # ---- verify ----
    if [[ $rule == *-SOPS ]]; then
      _verify_sops_file "$target" || return 1
    fi

    read_val "rule $rule applied to $target; press any key to continue" 1 >/dev/null
    echo

    # ---- diffs for M/R-edit only ----
    if [[ $rule == M-SOPS || $rule == R-edit-SOPS ]]; then
      yn "continue and show plain-text diff" || return 1
      _show_plain_diff "$gitstatus" "$p1" "$p2"
      yn "continue and show sops output diff" || return 1
      _show_sops_diff  "$gitstatus" "$p1" "$p2"
    fi

    yn "continue to next file in loop, or complete loop if no files remaining" || return 1
  done < <(git diff-tree -r -M --no-commit-id --name-status PICKED)

  echo
  git add -A
  echo
  git status -s
  echo
  git commit --amend --no-edit
  echo

  _do_log "info" "fixed up commit $original -> $(git rev-parse HEAD)"
  return 0
}
