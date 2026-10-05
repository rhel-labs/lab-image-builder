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

> **This document is reference, not a checklist.** The steps to configure CI
> import are [Setup step 5](../README.md#5-let-ci-import-into-gcp-too) in the
> README — five commands. Read this when you want to know why they are what
> they are, or when one of them fails.

## Setting it up

One command, from [Setup step 5](../README.md#5-let-ci-import-into-gcp-too):

**Run:**

```sh
./scripts/setup-ci-gcp.sh --apply    # or no arguments to see what it would do
```

It creates the pool, the provider, the service account, the custom role, both
IAM bindings and three repository variables, and is safe to re-run — every
step checks before it creates, so a partial failure is fixed by running it
again.

It needs `gcloud` and `gh` authenticated, and `roles/owner` or equivalent on
the project. Override any of `PROJECT_ID`, `REPO`, `BRANCH`, `POOL`,
`PROVIDER`, `SA_ID`, `ROLE_ID` from the environment.

It deliberately stops short of two things, because both are judgement calls
rather than plumbing, and both are steps 5b–5d in the README:

1. **Adding the service account to `lab_share_with_accounts` and rebuilding.**
   Sharing happens at *compose* time, so images already built stay unreachable
   from CI however the list reads now.
2. **Setting `ENABLE_IMPORT`.** That is the switch that makes CI start
   importing, and it should be yours to throw.

### What it creates

| Thing | Value |
|---|---|
| Pool | `github` |
| Provider | `lab-image-builder`, issuer `token.actions.githubusercontent.com` |
| Attribute condition | repository + repository id + `refs/heads/build-image` |
| Service account | `lab-image-importer@tmm-instruqt-11-26-2021.iam.gserviceaccount.com` |
| Custom role | `labImageImporter` — 5 permissions, listed below |
| Trust binding | `roles/iam.workloadIdentityUser` on `attribute.repository`, **not** `google.subject` |
| Debug binding | `roles/iam.serviceAccountTokenCreator` for you, so you can reproduce CI locally |
| Repo variables | `GCP_PROJECT_ID`, `GCP_SERVICE_ACCOUNT`, `GCP_WORKLOAD_IDENTITY_PROVIDER` |
| Keys | none, by design |

Variables rather than secrets: none of it is sensitive, and being able to read
the values in a failed run's log is what makes a federation problem
debuggable. `ENABLE_IMPORT` is the fourth variable and the script leaves it to
you.

**`GCP_PROJECT_ID` does not choose where images land.** That is
`lab_targets.<target>.project` in `group_vars/all/main.yml`; the variable only
sets gcloud's ambient `core/project`. They must agree — let them drift and the
custom role is granted on one project while images are created in another,
and the failure is a bare permission denial pointing at neither.

Two details worth knowing even though the script handles them, because they
are what you will check first when something 403s:

- The pool path uses the project **number**, not the id. Using the id is
  invalid and the error does not say so.
- `sts.googleapis.com` is the token exchange itself. It was **disabled** on
  this project as of 2026-10-02, along with `cloudresourcemanager`; the script
  enables both. `iamcredentials` — usually the forgotten one, since without it
  the exchange succeeds and `generateAccessToken` 403s like a missing binding
  — happened to be on already.

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

Those five are the `PERMISSIONS` array in `scripts/setup-ci-gcp.sh`.

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
for immutable OIDC subject claims.

**Run — confirm it on this repo:**

```sh
gh api /repos/rhel-labs/lab-image-builder/actions/oidc/customization/sub
```

**Output — what you should see:**

```json
{ "use_default": true, "use_immutable_subject": true,
  "sub_claim_prefix": "repo:rhel-labs@48067826/lab-image-builder@1400425076" }
```

So the `sub` claim is:

**Reference — the subject this repo emits:**

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
`./scripts/setup-ci-gcp.sh` with no arguments re-checks every resource and
changes nothing, so run that first — it answers most of these at once.

The variables below are the ones the script defines; set them in your shell,
or just read the values out of its dry-run output.

**Run — in order, stopping at the first that misbehaves:**

```sh
PROJECT_ID=tmm-instruqt-11-26-2021
SA_EMAIL=lab-image-importer@${PROJECT_ID}.iam.gserviceaccount.com
POOL=github
PROVIDER=lab-image-builder

# 0. IAM alone, no federation involved. The script already granted you
#    serviceAccountTokenCreator on the SA, which is what makes this work —
#    it is how you debug everything below without pushing a commit.
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

**Run — confirm the result, and that nothing else happened:**

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
is server-side.

**Run — read the real reason out of Cloud Logging:**

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

**Checked on 2026-10-02, and this is mostly a theoretical worry here.**

**Run — only if you need to re-check it:**

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

**Run — to revoke CI's access, delete the trust binding:**

```sh
gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_RESOURCE}/attribute.repository/${REPO}" \
  --condition=None
```

Or, to stop at the GitHub side instead, unset `ENABLE_IMPORT`. That leaves the
federation intact but skips the job.
