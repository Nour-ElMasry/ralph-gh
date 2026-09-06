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

    git add -A -- ':!.ralph-gh' 2>/dev/null || true
    if ! git commit -m "feat(ralph): #${sub_issue_number} - ${sub_issue_title}" 2>/dev/null; then
        log_status "WARN" "git commit failed for #$sub_issue_number (changes may already be committed)"
        return 1
    fi
    return 0
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

    # A resumed parent usually already has the draft PR from the run that
    # stopped. Re-creating it fails ("a pull request for branch ... already
    # exists"), so update that PR in place and mark it ready instead.
    local existing_number
    existing_number=$(find_open_pr_number "$repo" "$branch_name")
    if [[ -n "$existing_number" ]]; then
        local err
        if err=$(update_pr_text "$repo" "$existing_number" "$pr_title" "$pr_body") \
            && err=$(gh pr ready "$existing_number" --repo "$repo" 2>&1 >/dev/null); then
            log_status "SUCCESS" "PR #$existing_number updated and marked ready"
            return 0
        fi
        log_status "ERROR" "PR #$existing_number update/ready failed: $err"
        return 1
    fi

    local pr_url
    if pr_url=$(gh pr create \
        --repo "$repo" \
        --base "$main_branch" \
        --head "$branch_name" \
        --title "$pr_title" \
        --body "$pr_body" 2>&1); then
        log_status "SUCCESS" "PR created: $pr_url"
    else
        log_status "ERROR" "gh pr create failed: $pr_url"
        return 1
    fi
}

# Echo the number of the open PR whose head is this branch, or nothing.
#   $1 = repo, $2 = branch name
find_open_pr_number() {
    local repo=$1
    local branch_name=$2
    gh pr list --repo "$repo" --head "$branch_name" --state open \
        --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# Set a PR's title and body over REST. `gh pr edit` also queries Projects
# (classic), which GitHub has sunset, so on gh < 2.63 it fails outright:
# "GraphQL: Projects (classic) is being deprecated ... (projectCards)".
#   $1 = repo, $2 = PR number, $3 = title, $4 = body
# Echoes gh's error text on failure.
update_pr_text() {
    local repo=$1
    local number=$2
    local title=$3
    local body=$4
    gh api -X PATCH "repos/$repo/pulls/$number" -f title="$title" -f body="$body" 2>&1 >/dev/null
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

    local existing_number
    existing_number=$(find_open_pr_number "$repo" "$branch_name")
    if [[ -n "$existing_number" ]]; then
        local err
        if err=$(update_pr_text "$repo" "$existing_number" "$pr_title" "$pr_body"); then
            log_status "SUCCESS" "Draft PR #$existing_number updated"
            return 0
        fi
        log_status "ERROR" "Draft PR #$existing_number update failed: $err"
        return 1
    fi

    local pr_url
    if pr_url=$(gh pr create \
        --repo "$repo" \
        --base "$main_branch" \
        --head "$branch_name" \
        --title "$pr_title" \
        --body "$pr_body" \
        --draft 2>&1); then
        log_status "SUCCESS" "Draft PR created: $pr_url"
    else
        log_status "ERROR" "gh pr create (draft) failed: $pr_url"
        return 1
    fi
}

export -f ensure_latest_main create_branch commit_changes push_branch
export -f open_pr open_draft_pr find_open_pr_number update_pr_text
