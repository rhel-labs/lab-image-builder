# The GCP identity CI imports as

Part 2 run from a laptop authenticates as you. Run from GitHub Actions it
authenticates as a service account, reached by Workload Identity Federation —
GitHub mints an OIDC token, Google exchanges it for a short-lived credential,
and that impersonates the service account. **No key is ever created, stored or
rotated.** That is the whole point of the arrangement.

This is written down because almost none of it is discoverable from an error
message. Both of the characteristic failures — a federation mismatch and an
unshared source image — surface as something that sounds like a different
problem.

## Settings in use

| | |
|---|---|
| Project | `tmm-instruqt-11-26-2021` |
| Workload identity pool | `github` |
| Pool provider | `lab-image-builder` |
| Issuer | `https://token.actions.githubusercontent.com` |
| Attribute condition | repository + repository id + `refs/heads/build-image` |
| IAM binding keyed on | `attribute.repository` — **not** `google.subject` |
| Service account | `lab-image-importer@tmm-instruqt-11-26-2021.iam.gserviceaccount.com` |
| Role on the project | custom `labImageImporter`, 5 permissions |
| Access to the source image | from the Image Builder share, not from IAM |
| Keys | none, by design |

`GCP_PROJECT_ID` **does not choose where images land.** That is
`lab_targets.<target>.project` in `group_vars/all/main.yml`. The variable only
sets gcloud's ambient `core/project`. The two must agree — if they drift, the
custom role is granted on one project while images are created in another, and
the failure is a bare permission denial that points at neither.

Plus four repository variables (not secrets — none of this is sensitive, and
seeing the values in a log is what makes a federation failure debuggable):

| Variable | Value |
|---|---|
| `ENABLE_IMPORT` | `true` |
| `GCP_PROJECT_ID` | `tmm-instruqt-11-26-2021` — see the warning below |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/866520833223/locations/global/workloadIdentityPools/github/providers/lab-image-builder` |
| `GCP_SERVICE_ACCOUNT` | `lab-image-importer@tmm-instruqt-11-26-2021.iam.gserviceaccount.com` |

## Creating it

```sh
set -euo pipefail

PROJECT_ID=tmm-instruqt-11-26-2021
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
REPO=rhel-labs/lab-image-builder
REPO_ID=$(gh api "/repos/${REPO}" --jq .id)
BRANCH=refs/heads/build-image

POOL=github
PROVIDER=lab-image-builder
SA_ID=lab-image-importer
SA_EMAIL="${SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}"
```

Note **`PROJECT_NUMBER`, not `PROJECT_ID`**, in the pool resource name and in
every `principalSet://`. Using the id there is invalid and the error does not
say so.

```sh
gcloud services enable \
  iam.googleapis.com sts.googleapis.com iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com compute.googleapis.com \
  --project="$PROJECT_ID"
```

As of 2026-10-02, `iam`, `iamcredentials` and `compute` were already enabled
on this project; **`sts` and `cloudresourcemanager` were not.** `sts` is the
token exchange itself, so federation cannot work until it is on — and its
absence is the first thing to re-check if the auth step 403s.

`iamcredentials.googleapis.com` is the one people usually forget (it is the
impersonation half, and without it the exchange succeeds and
`generateAccessToken` 403s in a way that reads like a missing IAM binding).
Here it happens to be on already.

```sh
gcloud iam workload-identity-pools create "$POOL" \
  --project="$PROJECT_ID" --location=global \
  --display-name='GitHub Actions' \
  --description='Federated identities for GitHub-hosted runners. No keys.'

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL" \
  --display-name='rhel-labs/lab-image-builder' \
  --issuer-uri='https://token.actions.githubusercontent.com' \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository == '${REPO}' && assertion.repository_id == '${REPO_ID}' && assertion.ref == '${BRANCH}'"

gcloud iam service-accounts create "$SA_ID" \
  --project="$PROJECT_ID" \
  --display-name='lab-image-builder CI importer' \
  --description='Copies images composed by Red Hat Image Builder into this project. Assumed from GitHub Actions via Workload Identity Federation. No keys should ever exist for it.'
```

Do not pass `--allowed-audiences`. The default audience is the full provider
resource URL, which is exactly what the auth action requests.

### The trust binding

```sh
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${REPO}" \
  --condition=None
```

**Do not use the `.../subject/repo:ORG/REPO:ref:...` form every tutorial
shows.** See "Why attribute binding" below — it fails silently here.

## Granting privileges

An import-only run makes **three** gcloud calls that need permission in *our*
project, plus one against Red Hat's that we cannot grant. The last two happen
once per manifest, so N blueprints means N of each.

| # | Call | Project | Permission |
|---|---|---|---|
| 1 | `gcloud compute images list` — the `gcp_target` preflight | ours | `compute.images.list` |
| 2 | `gcloud compute images describe <rh image>` | **Red Hat's** | `compute.images.get` — **from the share, not from IAM** |
| 3 | `gcloud compute images describe <new name>` | ours | `compute.images.get` |
| 4 | `gcloud compute images create --source-image --labels=…` | ours (reads source) | `compute.images.create` + `compute.images.setLabels` + `compute.globalOperations.get`; `compute.images.useReadOnly` on the source, again from the share |

Call 4 is a single command that needs three permissions: the create itself, the
labels passed with it, and polling the global operation it returns. Omitting
`compute.globalOperations.get` is the nasty one — the image is created
server-side and the CLI then fails while waiting, which Ansible reports as a
failed import that actually succeeded.

```sh
gcloud iam roles create labImageImporter \
  --project="$PROJECT_ID" \
  --title='Lab image importer' \
  --description='Create GCE images from images shared in by Red Hat Image Builder. No delete, no disks, no snapshots, no instances.' \
  --stage=GA \
  --permissions=compute.images.create,compute.images.get,compute.images.list,compute.images.setLabels,compute.globalOperations.get

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/labImageImporter" \
  --condition=None
```

`roles/compute.storageAdmin` also works and is the smallest *predefined* role
containing `compute.images.create` — there is no predefined "image creator".
But it is full control of Compute Engine storage: it carries
`compute.images.delete` and all of `compute.disks.*` and `compute.snapshots.*`.
An unattended CI job on a public repo that can delete every image, disk and
snapshot in the project is a worse trade than five permissions.

Two deliberate omissions:

- **`compute.images.delete`.** CI accumulates images forever and cleanup stays
  a human act. Garbage collection in CI would be a separate decision.
- **`compute.images.useReadOnly`.** It is a *source-side* permission and
  granting it here does nothing — see below.

### The source half is not ours to grant

Reading the composed image out of `red-hat-image-builder` needs
`compute.images.get` and `compute.images.useReadOnly` **on that image**, in
Red Hat's project. That arrives from `share_with_accounts` at compose time, as
an IAM binding Image Builder writes onto the image itself. You cannot grant it,
and you do not need to.

The consequence is the thing most likely to trip up a first run: **adding a
principal to `lab_share_with_accounts` does not affect images already built.**
They were shared to whoever was named when they were composed. A new principal
needs a rebuild.

## Why impersonation and not direct federation

Direct Workload Identity — where the federated principal holds the IAM roles
itself and no service account exists — is simpler and would be preferable. It
is not available to us.

`share_with_accounts` accepts exactly four principal forms, per the live
`openapi.json`: `user:`, `serviceAccount:`, `group:`, `domain:`. A federated
`principalSet://…` identifier is not one of them. The import therefore has to
run as something with a stable service account email, because that string has
to go in a list in `group_vars/all/main.yml`.

## Why attribute binding and not subject

This repository was created on 2026-10-01, after GitHub's 2026-07-15 cutoff
for immutable OIDC subject claims. Confirm with:

```sh
gh api /repos/rhel-labs/lab-image-builder/actions/oidc/customization/sub
```

```json
{ "use_default": true, "use_immutable_subject": true,
  "sub_claim_prefix": "repo:rhel-labs@48067826/lab-image-builder@1400425076" }
```

So the `sub` claim is

```text
repo:rhel-labs@48067826/lab-image-builder@1400425076:ref:refs/heads/build-image
```

and **not** the `repo:rhel-labs/lab-image-builder:ref:refs/heads/build-image`
that every guide and blog post shows. A binding written in the old name-only
form matches nothing. It fails *silently*: the STS exchange succeeds, then
`generateAccessToken` returns 403, which reads as a wrong role rather than a
format mismatch.

`google.subject=assertion.sub` still has to be in the attribute mapping —
gcloud rejects the provider without it — but nothing is ever matched against
it. The `repository`, `repository_id`, `repository_owner` and `ref` claims are
untouched by the subject change, which is why binding on `attribute.repository`
is the stable choice.

### On pinning the branch

A `principalSet` member path holds exactly one attribute, so the repository and
the ref cannot both live in the binding. The repository goes in the binding and
the ref in the provider's attribute condition.

The ref pin means a `workflow_dispatch` from any other branch fails at the auth
step. That costs nothing here — the README already requires
`--ref build-image` on every dispatch, because recording a version anywhere
else wedges the repo. Drop the `assertion.ref` clause if you ever want GCP
access from another branch.

## Verifying it

In order. Each step isolates one thing, and the expensive one is last.

```sh
# 0. IAM alone, no federation involved. Needs
#    roles/iam.serviceAccountTokenCreator on the SA for yourself — worth
#    keeping, it is how you debug everything below without pushing a commit.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" --role=roles/iam.serviceAccountTokenCreator \
  --member='user:myee@redhat.com' --condition=None

gcloud compute images list --project="$PROJECT_ID" --no-standard-images \
  --limit 1 --impersonate-service-account="$SA_EMAIL"
# Good: a name, or empty with rc 0. A 403 means the role binding.

# 1. The provider condition is what you think it is.
gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project="$PROJECT_ID" --location=global --workload-identity-pool="$POOL" \
  --format='yaml(attributeCondition,attributeMapping,oidc.issuerUri)'

# 2. The principalSet, character for character.
gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
  --project="$PROJECT_ID" --format=yaml

# 3. Can the service account actually read the source image? This is the
#    question nothing else answers, and it needs an image composed AFTER the
#    share list change.
gcloud compute images describe <rh_image_name> --project red-hat-image-builder
gcloud compute images describe <rh_image_name> --project red-hat-image-builder \
  --impersonate-service-account="$SA_EMAIL"
# Readable as you but not as the SA => the share did not take. See below.

# 4. The real run.
gh workflow run build-image.yml --ref build-image -f blueprint=lab-base-rhel-10.2
gh run watch
```

In the import job's log, in order:

1. **Show which identity the import will run as** prints the service account
   email. Empty means `setup-gcloud` did not activate the credential. A
   `principal://…` URL means the `service_account` input did not take and you
   are on direct federation, where the share will never match.
2. `gcp_target` does **not** print `WARNING: gcloud is authenticated as`.
3. `gcp_import` prints `Imported <name> (family <family>) into <project>`.
   Note it does **not** print `READY` — the source-status check is an `assert`
   with `quiet: true`, which is silent on success. Do not grep for it.

Then confirm the result and that nothing else happened:

```sh
gcloud compute images describe-from-family lab-base-rhel-10-2 \
  --project="$PROJECT_ID" --format='yaml(name,family,status,labels,sourceImage)'

gcloud compute instances list --project="$PROJECT_ID" --filter='name~^verify-'
gcloud builds list --project="$PROJECT_ID" --region=us-central1 --limit=5
```

`sourceImage` must point into `red-hat-image-builder`. Both of the last two
must be empty, and they fail for *different* reasons — a surviving `verify-*`
VM means `-e verify=false` did not land; a Cloud Build job means
`-e export=false` did not. The export phase never creates an instance.

## Interpreting failures

| What you see | What it means |
|---|---|
| 403 at the `auth` step, before gcloud runs | Attribute condition or principalSet. Check it keys on `attribute.repository`, not subject, and that the pool path uses the project **number** |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` | `iamcredentials.googleapis.com` disabled, or the `workloadIdentityUser` binding is missing |
| Identity step prints `Active account: <none>` and exits 1 | `auth` succeeded but `setup-gcloud` is missing or ran too late. The step's `test -n` fails the job here, so Ansible never starts and you will **not** see `gcp_target`'s "No active gcloud account" |
| Identity step prints a `principal://…` URL | `service_account` input not set — you are on direct federation |
| `WARNING: gcloud is authenticated as …` | The active principal is not in `lab_share_with_accounts` |
| `Cannot read composer-api-… aged out or never shared` | The image was composed *before* the share list named this account. Rebuild |
| Same, but on a freshly composed image | The share binding was refused inside Red Hat's project — see below |
| `compute.images.create` denied | The custom role is too tight; fall back to `roles/compute.storageAdmin` and narrow later |

The STS and impersonation errors are deliberately vague client-side. The reason
is server-side:

```sh
gcloud logging read \
  'protoPayload.serviceName="sts.googleapis.com" OR protoPayload.serviceName="iamcredentials.googleapis.com"' \
  --project="$PROJECT_ID" --limit=10 --freshness=1h --format=json
```

That is what tells you whether the attribute condition rejected the assertion,
the principalSet did not match, or the role is missing.

### If the share is refused in Red Hat's project

`share_with_accounts` becomes a `setIamPolicy` call inside
`red-hat-image-builder`. If that project's organisation enforced
`constraints/iam.allowedPolicyMemberDomains`, a service account from another
organisation would not be an allowed member and the binding would be dropped —
inside infrastructure we do not control, with no error surfaced to us.

**Checked on 2026-10-02, and this is mostly a theoretical worry here:**

```sh
gcloud projects get-ancestors red-hat-image-builder
gcloud projects get-ancestors tmm-instruqt-11-26-2021
# both terminate at organization 54643501348, sharing folder 497713236862

gcloud resource-manager org-policies describe \
  constraints/iam.allowedPolicyMemberDomains \
  --project=red-hat-image-builder --effective
# listPolicy: {allValues: ALLOW}
```

Same organisation, permissive on both sides — so the service account is an
in-org member and the share should be accepted. Re-check if either project
ever moves organisation.

The symptom, if it ever does happen, is step 3 of the verification above:
readable as `myee@redhat.com`, not readable as the service account, on an
image composed *after* the share-list change. Nothing short of one real
compose distinguishes it from an ordinary not-yet-shared image.

The fallback would be a Google group containing both principals — `group:` is
an accepted prefix, and `gcp_target`'s warning already allows for it.

## Rotating

There is nothing to rotate, which is the entire reason for this arrangement.
No key exists. Credentials are minted per run and expire in under an hour.

To revoke CI's access, delete the trust binding:

```sh
gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${REPO}" \
  --condition=None
```

Or, to stop at the GitHub side instead, unset `ENABLE_IMPORT`. That leaves the
federation intact but skips the job.
