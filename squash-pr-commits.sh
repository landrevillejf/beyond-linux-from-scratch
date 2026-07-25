#!/usr/bin/env bash
# squash-pr-commits.sh - Squash tous les commits d'une PR en un seul
# Usage: ./squash-pr-commits.sh <PR_NUMBER> [commit message]
# Dépendances : gh (GitHub CLI), git, jq
set -euo pipefail

PR_NUMBER="${1:?Usage: $0 <PR_NUMBER> [commit message]}"
MESSAGE="${2:-Squashed PR #$PR_NUMBER}"

# Vérifier que gh est installé
if ! command -v gh &>/dev/null; then
    echo "ERROR: GitHub CLI (gh) is required. Install it from https://cli.github.com/"
    exit 1
fi

# Vérifier l'authentification
if ! gh auth status &>/dev/null; then
    echo "ERROR: Not logged in to GitHub CLI. Run 'gh auth login' first."
    exit 1
fi

# Récupérer les infos de la PR
echo "Fetching PR #$PR_NUMBER details..."
PR_DATA=$(gh pr view "$PR_NUMBER" --json headRefName,headRepositoryOwner,number,title)
BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
OWNER=$(echo "$PR_DATA" | jq -r '.headRepositoryOwner.login')
REPO=$(gh repo view --json name -q '.name')

echo "PR branch: $BRANCH"
echo "Repository: $OWNER/$REPO"

# Récupérer le SHA du premier commit de la PR et le SHA de la branche parent
PARENT_SHA=$(gh pr view "$PR_NUMBER" --json baseRefName -q '.baseRefName' | xargs git rev-parse origin/)
PR_HEAD=$(gh pr view "$PR_NUMBER" --json headRefOid -q '.headRefOid')

echo "Base ref (parent) SHA: $PARENT_SHA"
echo "PR head SHA: $PR_HEAD"

# Créer un commit squash en partant de la branche de base
echo "Creating squashed commit..."
TEMP_BRANCH="squash-pr-${PR_NUMBER}-$(date +%s)"
git checkout -b "$TEMP_BRANCH" "$PARENT_SHA"
git merge --squash "$PR_HEAD"
git commit -m "$MESSAGE"

# Remplacer la branche existante par le commit squash
echo "Force-pushing squashed history to $BRANCH..."
git push --force-with-lease origin "$TEMP_BRANCH:$BRANCH"

# Nettoyage
git checkout main  # ou la branche de destination par défaut
git branch -D "$TEMP_BRANCH"

echo "Successfully squashed PR #$PR_NUMBER into a single commit and pushed to $BRANCH."