#!/usr/bin/env bash

# branch_manager.sh - Git branch, commit, and PR management for ralph-gh

# Ensure we're on the latest main branch
ensure_latest_main() {
    local main_branch="${1:-main}"

    log_status "INFO" "Syncing to latest $main_branch..."
    git fetch origin 2>/dev/null
    git checkout "$main_branch" 2>/dev/null
    git pull origin "$main_branch" 2>/dev/null
}

# Create a new branch for a parent issue group
create_branch() {
    local branch_name=$1
    local main_branch="${2:-main}"

    # Check if branch already exists locally
    if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        log_status "INFO" "Branch $branch_name already exists, checking out"
        git checkout "$branch_name" 2>/dev/null
        return $?
    fi

    # Check if branch exists on remote
    if git show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; then
        log_status "INFO" "Branch $branch_name exists on remote, checking out"
        git checkout -b "$branch_name" "origin/$branch_name" 2>/dev/null
        return $?
    fi

    # Create fresh branch from main
    log_status "INFO" "Creating branch $branch_name from $main_branch"
    git checkout -b "$branch_name" "$main_branch" 2>/dev/null
    return $?
}

# Stage and commit changes
commit_changes() {
    local sub_issue_number=$1
    local sub_issue_title=$2

    # Check if there are changes to commit
    if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
        # Check for untracked files
        if [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
            log_status "INFO" "No changes to commit for #$sub_issue_number"
            return 0
        fi
    fi

    git add -A 2>/dev/null
    git commit -m "feat(ralph): #${sub_issue_number} - ${sub_issue_title}" 2>/dev/null
    return $?
}

# Push branch to remote
push_branch() {
    local branch_name=$1

    log_status "INFO" "Pushing branch $branch_name to origin..."
    git push origin "$branch_name" 2>/dev/null
    return $?
}

# Open a PR for a completed parent issue group
open_pr() {
    local repo=$1
    local branch_name=$2
    local main_branch=$3
    local parent_number=$4
    local parent_title=$5
    local completed_subs=$6

    local pr_title="feat: #${parent_number} - ${parent_title}"
    # Truncate title to 70 chars
    if [[ ${#pr_title} -gt 70 ]]; then
        pr_title="${pr_title:0:67}..."
    fi

    local pr_body
    pr_body=$(cat <<EOF
## Summary

Closes #${parent_number}

### Completed sub-issues:
${completed_subs}

---
Automated by [ralph-gh](https://github.com/Nour-ElMasry/ralph-gh)
EOF
)

    gh pr create \
        --repo "$repo" \
        --base "$main_branch" \
        --head "$branch_name" \
        --title "$pr_title" \
        --body "$pr_body" 2>/dev/null
}

# Open a draft PR for partial/failed work
open_draft_pr() {
    local repo=$1
    local branch_name=$2
    local main_branch=$3
    local parent_number=$4
    local parent_title=$5
    local completed_subs=$6
    local failure_reason=$7

    local pr_title="[DRAFT] #${parent_number} - ${parent_title}"
    if [[ ${#pr_title} -gt 70 ]]; then
        pr_title="${pr_title:0:67}..."
    fi

    local pr_body
    pr_body=$(cat <<EOF
## Summary (Partial Work)

Related to #${parent_number}

**Status:** Work was halted due to an error. Manual intervention required.

### Completed sub-issues:
${completed_subs}

### Failure reason:
${failure_reason}

---
Automated by [ralph-gh](https://github.com/Nour-ElMasry/ralph-gh)
EOF
)

    gh pr create \
        --repo "$repo" \
        --base "$main_branch" \
        --head "$branch_name" \
        --title "$pr_title" \
        --body "$pr_body" \
        --draft 2>/dev/null
}

export -f ensure_latest_main create_branch commit_changes push_branch
export -f open_pr open_draft_pr
