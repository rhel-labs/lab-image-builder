#!/usr/bin/env bash
#
# One-time setup so GitHub Actions can import images into GCP without a key.
#
# Creates a workload identity pool, an OIDC provider trusting this repo, a
# service account, a least-privilege custom role, the trust binding between
# them, and the four repository variables the workflow reads.
#
#   ./scripts/setup-ci-gcp.sh            # show what is missing, change nothing
#   ./scripts/setup-ci-gcp.sh --apply    # create whatever is missing
#
# Safe to re-run: every step checks before it creates, so a partial failure is
# fixed by running it again. It never deletes or overwrites.
#
# What it deliberately does NOT do, because both need your judgement:
#   - add the service account to lab_share_with_accounts (group_vars) and
#     rebuild. Sharing happens at compose time; see the note it prints.
#   - set ENABLE_IMPORT=true. That is the switch that makes CI start
#     importing, and it should be yours to throw.
#
# Why each piece exists, and how to debug it: docs/ci-gcp-identity.md
set -euo pipefail

# ─── Config. Override from the environment if any of it changes. ────────────
PROJECT_ID="${PROJECT_ID:-tmm-instruqt-11-26-2021}"
REPO="${REPO:-rhel-labs/lab-image-builder}"
BRANCH="${BRANCH:-refs/heads/build-image}"

POOL="${POOL:-github}"
PROVIDER="${PROVIDER:-lab-image-builder}"
SA_ID="${SA_ID:-lab-image-importer}"
ROLE_ID="${ROLE_ID:-labImageImporter}"

APIS=(
  iam.googleapis.com
  sts.googleapis.com
  iamcredentials.googleapis.com
  cloudresourcemanager.googleapis.com
  compute.googleapis.com
)

# Exactly what an import-only run needs in this project. The source image is
# read out of Red Hat's project instead, and that access comes from the
# compose-time share, not from anything grantable here.
PERMISSIONS=(
  compute.images.create
  compute.images.get
  compute.images.list
  compute.images.setLabels
  compute.globalOperations.get
)

# ─── Plumbing ───────────────────────────────────────────────────────────────
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true
if [ -n "${1:-}" ] && [ "${1:-}" != "--apply" ]; then
  echo "usage: $0 [--apply]" >&2
  exit 2
fi

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
have() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
need() { printf '  \033[33m+\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

TODO=0
# run <description> <command...> — create it, or just say it is missing.
run() {
  local what=$1; shift
  need "$what"
  TODO=$((TODO + 1))
  if [ "$APPLY" = true ]; then
    "$@"
    info "created"
  fi
}

bold "Checking prerequisites"
command -v gcloud >/dev/null || { echo "gcloud is not on PATH" >&2; exit 1; }
command -v gh >/dev/null     || { echo "gh is not on PATH" >&2; exit 1; }
gcloud auth print-access-token >/dev/null 2>&1 \
  || { echo "gcloud is not authenticated. Run: gcloud auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 \
  || { echo "gh is not authenticated. Run: gh auth login" >&2; exit 1; }
have "gcloud as $(gcloud config get-value account 2>/dev/null)"
have "gh as $(gh api /user --jq .login 2>/dev/null)"

# Derived. The pool path needs the project NUMBER, not the id — using the id
# is invalid and the resulting error does not say so.
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
REPO_ID=$(gh api "/repos/${REPO}" --jq .id)
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}"
PROVIDER_RESOURCE="${POOL_RESOURCE}/providers/${PROVIDER}"
MEMBER="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${REPO}"
have "project ${PROJECT_ID} (number ${PROJECT_NUMBER})"
have "repo ${REPO} (id ${REPO_ID})"

echo
if [ "$APPLY" = true ]; then
  bold "Applying"
else
  bold "Dry run — nothing will be changed. Re-run with --apply."
fi

# ─── APIs ───────────────────────────────────────────────────────────────────
echo
bold "APIs"
ENABLED=$(gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)')
for api in "${APIS[@]}"; do
  if grep -qx "$api" <<<"$ENABLED"; then
    have "$api"
  else
    run "$api" gcloud services enable "$api" --project="$PROJECT_ID"
  fi
done

# ─── Pool and provider ──────────────────────────────────────────────────────
echo
bold "Workload identity"
if gcloud iam workload-identity-pools describe "$POOL" \
     --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  have "pool ${POOL}"
else
  run "pool ${POOL}" \
    gcloud iam workload-identity-pools create "$POOL" \
      --project="$PROJECT_ID" --location=global \
      --display-name='GitHub Actions' \
      --description='Federated identities for GitHub-hosted runners. No keys.'
fi

if gcloud iam workload-identity-pools providers describe "$PROVIDER" \
     --project="$PROJECT_ID" --location=global \
     --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  have "provider ${PROVIDER}"
else
  # google.subject must be mapped (gcloud rejects the provider without it) but
  # is never matched against — the IAM binding keys on attribute.repository.
  # This repo post-dates GitHub's immutable-subject change, so its sub carries
  # owner and repo ids and a subject-based binding would match nothing.
  run "provider ${PROVIDER}, trusting ${REPO} on ${BRANCH}" \
    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
      --project="$PROJECT_ID" --location=global \
      --workload-identity-pool="$POOL" \
      --display-name="$REPO" \
      --issuer-uri='https://token.actions.githubusercontent.com' \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
      --attribute-condition="assertion.repository == '${REPO}' && assertion.repository_id == '${REPO_ID}' && assertion.ref == '${BRANCH}'"
fi

# ─── Service account ────────────────────────────────────────────────────────
echo
bold "Service account"
if gcloud iam service-accounts describe "$SA_EMAIL" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  have "$SA_EMAIL"
else
  run "$SA_EMAIL" \
    gcloud iam service-accounts create "$SA_ID" \
      --project="$PROJECT_ID" \
      --display-name='lab-image-builder CI importer' \
      --description='Copies images composed by Red Hat Image Builder into this project. Assumed from GitHub Actions via Workload Identity Federation. No keys should ever exist for it.'
fi

if gcloud iam roles describe "$ROLE_ID" --project="$PROJECT_ID" >/dev/null 2>&1; then
  have "custom role ${ROLE_ID}"
else
  run "custom role ${ROLE_ID} (${#PERMISSIONS[@]} permissions)" \
    gcloud iam roles create "$ROLE_ID" \
      --project="$PROJECT_ID" \
      --title='Lab image importer' \
      --description='Create GCE images from images shared in by Red Hat Image Builder. No delete, no disks, no snapshots, no instances.' \
      --stage=GA \
      --permissions="$(IFS=,; echo "${PERMISSIONS[*]}")"
fi

# ─── Bindings ───────────────────────────────────────────────────────────────
echo
bold "Bindings"
if gcloud projects get-iam-policy "$PROJECT_ID" --format=json \
   | grep -q "projects/${PROJECT_ID}/roles/${ROLE_ID}"; then
  have "${ROLE_ID} granted to the service account"
else
  run "${ROLE_ID} -> ${SA_ID}" \
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="projects/${PROJECT_ID}/roles/${ROLE_ID}" \
      --condition=None
fi

SA_POLICY=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
              --project="$PROJECT_ID" --format=json 2>/dev/null || echo '{}')
if grep -qF "$MEMBER" <<<"$SA_POLICY"; then
  have "${REPO} may impersonate the service account"
else
  run "workloadIdentityUser for ${REPO}" \
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
      --project="$PROJECT_ID" \
      --role=roles/iam.workloadIdentityUser \
      --member="$MEMBER" \
      --condition=None
fi

# Lets you reproduce CI's exact permissions locally with
# --impersonate-service-account, which is how you debug all of the above
# without pushing a commit.
ME="user:$(gcloud config get-value account 2>/dev/null)"
if grep -q 'roles/iam.serviceAccountTokenCreator' <<<"$SA_POLICY" \
   && grep -qF "$ME" <<<"$SA_POLICY"; then
  have "you may impersonate it too (for debugging)"
else
  run "serviceAccountTokenCreator for ${ME} (debugging)" \
    gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
      --project="$PROJECT_ID" \
      --role=roles/iam.serviceAccountTokenCreator \
      --member="$ME" \
      --condition=None
fi

# ─── Repository variables ───────────────────────────────────────────────────
# Variables, not secrets: none of this is sensitive, and being able to read
# the values in a log is what makes a federation failure debuggable.
echo
bold "Repository variables"
set_var() {
  local name=$1 want=$2 got
  got=$(gh variable get "$name" --repo "$REPO" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then
    have "${name}"
  elif [ -n "$got" ]; then
    run "${name} (currently '${got}')" gh variable set "$name" --repo "$REPO" --body "$want"
  else
    run "${name}" gh variable set "$name" --repo "$REPO" --body "$want"
  fi
}
set_var GCP_PROJECT_ID "$PROJECT_ID"
set_var GCP_SERVICE_ACCOUNT "$SA_EMAIL"
set_var GCP_WORKLOAD_IDENTITY_PROVIDER "$PROVIDER_RESOURCE"

# ─── What is left for a human ───────────────────────────────────────────────
echo
if [ "$APPLY" = false ]; then
  bold "${TODO} thing(s) to create. Re-run with --apply."
  exit 0
fi

bold "GCP side done. Two steps left, both yours:"
cat <<EOF

  1. Share images with the importer, then rebuild.

     group_vars/all/main.yml must list

       - "serviceAccount:${SA_EMAIL}"

     in lab_share_with_accounts, and that has to reach a compose. Sharing
     happens at compose time, so images already built stay unreachable from
     CI no matter what the list says now.

  2. Turn the import on.

       gh variable set ENABLE_IMPORT --repo ${REPO} --body true

     Then merge to ${BRANCH##refs/heads/} and dispatch a build:

       gh workflow run build-image.yml --ref ${BRANCH##refs/heads/} \\
         -f blueprint=lab-base-rhel-10.2

Verify as you go: docs/ci-gcp-identity.md, "Verifying it".
EOF
