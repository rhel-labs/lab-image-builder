# lab-image-builder

RHEL VM images for GCP labs, composed by Red Hat's hosted Image Builder at
console.redhat.com from blueprints kept in this repo.

The work is split in two:

| | Part 1 — build at Red Hat | Part 2 — import to GCP |
|---|---|---|
| Playbooks | `pull-blueprints.yml`, `build-image.yml` | `import-image.yml` *(not yet written)* |
| Input | `blueprints/<name>.yml` | `.build/*.json` |
| Output | image in **Red Hat's** GCP project, shared to us | image in `tmm-instruqt-11-26-2021` |
| Credentials | Red Hat service account | gcloud ADC |

The split is not arbitrary. Image Builder's GCP target always writes into
**Red Hat's own GCP project** and grants access to accounts you nominate —
there is no setting that makes it write into yours. Copying the image across
is a separate job with separate credentials, so it is a separate playbook.

**Part 1 is implemented. Part 2 is not.**

## Prerequisites

1. **Ansible** — `brew install ansible`
2. **A Red Hat service account** from
   <https://console.redhat.com/iam/service-accounts>, added to a User Access
   group holding **`Repositories viewer`** and **`Content Template viewer`**
   (content-sources). Those two are the whole requirement — there is no Image
   Builder role to add, because Image Builder access comes from the org's
   Default access group.

   Privileges attach to the *group*, and the account goes on the group's
   **Service accounts** tab, which is not the Members tab. Full write-up,
   including why an account with no roles appears to work right up until the
   compose: **[docs/service-account.md](docs/service-account.md)**.

   Confirm before building:

   ```sh
   curl -H "Authorization: Bearer $TOKEN" \
     'https://console.redhat.com/api/rbac/v1/access/?application=content-sources'
   ```

   `"count": 2` is correct. `"count": 0` means no roles, or an account that
   was never added to the group. `build-image.yml` detects the resulting 403
   and prints the fix rather than an HTTP dump.
3. **Credentials on disk**, outside this repo so they cannot be committed:

   ```sh
   mkdir -p ~/.config/redhat
   touch ~/.config/redhat/lab-images.env
   chmod 600 ~/.config/redhat/lab-images.env
   $EDITOR ~/.config/redhat/lab-images.env
   ```

   ```sh
   RH_CLIENT_ID=...
   RH_CLIENT_SECRET=...
   ```

   Type them into the editor — not into a shell command, which lands in your
   history.

Part 1 needs no GCP credentials at all.

## Usage

```sh
# Refresh local blueprints from the console (overwrites local files)
ansible-playbook pull-blueprints.yml
ansible-playbook pull-blueprints.yml -e blueprint=rhel-10-2-eus

# Edit blueprints/<name>.yml in your editor, then build
ansible-playbook build-image.yml -e blueprint=lab-base-rhel-10.2

# Build the same definition on a different OS, under a derived name
ansible-playbook build-image.yml -e blueprint=lab-base-rhel-10.2 -e distribution=rhel-9.8

# Other overrides
ansible-playbook build-image.yml -e blueprint=... -e lab_architecture=aarch64
ansible-playbook build-image.yml -e blueprint=... -e force_push=true
```

`blueprints/*.yml` is the source of truth. `pull` takes the console's copy;
`build` pushes the local copy up before composing. The two directions are
deliberately asymmetric — see the drift guard below.

## Blueprint files

A blueprint file is the portable part of the definition and nothing else:

```yaml
customizations:
  packages:
  - bash-completion
  - git-core
  services:
    enabled:
    - sshd
description: Minimal RHEL 10.2 lab base
distribution: rhel-10.2
name: lab-base-rhel-10.2
```

`image_requests` — the GCP delivery target — is deliberately **not** in the
file. It lives once in `group_vars/all/main.yml` and is injected at push
time. What the image *is* belongs in the blueprint and is worth diffing;
where it gets *delivered* is environmental and identical across all of them.
It also means a blueprint pulled from the console never drags someone else's
upload destination into this repo.

Filenames are slugs of the blueprint name, which is free text and may contain
spaces and capitals (`centos-9 x86_64 aws 22 August 2024` →
`centos-9-x86_64-aws-22-august-2024.yml`). The `name:` field inside the file
stays authoritative for the API; `blueprints/.remote-state.json` maps slug →
name, id and version.

### Changing the OS

Either edit `distribution:` in the file, or pass `-e distribution=rhel-9.8`.
The override upserts under a derived name (`<name>-rhel-9.8`) so testing
another OS never clobbers the original. Both are validated against
`GET /distributions` before anything is created, so a typo fails by name
instead of as an opaque 400.

## The drift guard

Overwriting a blueprint someone edited in the web console is the one
genuinely destructive thing this repo can do, so it never happens silently.
`build-image.yml` refuses to push when either is true:

- **the console is ahead** — its `version` is greater than the one
  `.remote-state.json` last recorded, so someone edited it in the web UI
  since this repo last pulled
  (`roles/rh_blueprint_push/tasks/main.yml:59`), or
- **the console copy was never pulled** — a blueprint of that name exists up
  there but state has no entry for it, so there is no way to tell whether the
  local file is a newer version of it or an unrelated blueprint that happens
  to share a name (`:37`).

Both failures name the versions and timestamps involved and give you the two
ways out: `pull-blueprints.yml -e blueprint=<slug>` to take theirs, or
`-e force_push=true` to take yours.

### `force_push`

Defaults to `false` in `group_vars/all/main.yml`. Set it per run:

```sh
ansible-playbook build-image.yml -e blueprint=lab-base-rhel-10.2 -e force_push=true
```

**It switches off the two guards above and does nothing else.** Each guard is
a `fail` task carrying `not (force_push | bool)` as its last condition, so the
flag decides whether the playbook stops — not what gets sent. The PUT body is
byte-identical either way.

What it means in practice is **"discard the console copy, mine wins."** The
PUT overwrites whatever is up there and the console edit is gone: Image
Builder keeps a version *counter*, not version history, so there is no undo.
That is why it is a per-run flag and not a setting.

It is narrower than the name suggests. It does **not** bypass:

- blueprint validation in `validate.yml` (missing file, bad distribution,
  unknown image type),
- the lint report, or
- anything in the compose.

A failing build does not become a passing one because you forced the push.

**You do not need it for ordinary work.** Pushing repeatedly from this repo
bumps the console version *and* records it in the same `block`/`always` unit,
so the two stay in step and neither guard fires. Reach for it when you have
deliberately decided the local file is authoritative — adopting a blueprint
that predates this repo, or stamping over console-side experimentation.

## Notes from building this

- **`GET /blueprints/{id}/export` is the wrong endpoint**, despite looking
  like the obvious one. It resolves content-sources data, so it returns
  `403 user is not authorized - please check your 'Repositories viewer' or
  'Content Template viewer' permissions` unless the service account holds
  those extra roles — and it omits `lint`. `GET /blueprints/{id}` returns
  everything the write body accepts *plus* lint, in one call, with no extra
  permissions. That is what `pull-blueprints.yml` uses.
- **`POST /blueprints/{id}/compose` returns an array**, one entry per
  requested image type — the compose id is `.json[0].id`, not `.json.id`.
- **`PUT /blueprints/{id}` returns `201`, not the `200` the spec documents.**
  Both are accepted.
- **The state file must be reconciled even when a push fails.** A write that
  lands but is never recorded locally makes the next run's drift guard read
  our own write as somebody else's console edit, wedging the repo until
  someone forces past it — which defeats the guard. The upsert and the
  reconcile are one `block`/`always` unit for that reason.
- **The access token expires after 900s and a GCP compose routinely runs
  longer.** A single poll loop would outlive its own token and start 401ing
  mid-build. Polling is split into cycles that re-authenticate first; see
  `lab_poll_*` in `group_vars/all/main.yml`.
- **The blueprint write body accepts only** `name`, `description`,
  `distribution`, `customizations`, `image_requests`, `metadata`, `bootc`.
  `content_sources` and `snapshot_date` can be read but not written, so they
  are not stored locally — a field you can edit and not push is a trap.
- **401 means the token; 403 means the User Access group.** Which group
  privilege is missing depends on where the 403 lands —
  [docs/service-account.md](docs/service-account.md) has the table.
- **Don't put `curl` in `packages`.** RHEL 9+ ships `curl-minimal`, which
  already provides the binary; asking for `curl` forces a swap that can fail
  dependency resolution at compose time. `vim-enhanced` over `vim` is the
  same reasoning. `git` over `git-core` is a deliberate exception — the lab
  base wants the full tool and accepts the perl it drags in.
- **Several RHEL 9 package names are gone in RHEL 10, and they fail
  differently.** `mlocate` → `plocate` and `cockpit-pcp` → (folded into
  `cockpit-system`, with `pcp` supplying the data) have no provider at all,
  so the compose fails outright. `cockpit-composer` is worse: it is
  `Provides:` of `cockpit-image-builder`, so it resolves silently and you
  never learn the name changed. Check a rename with
  `dnf repoquery --whatprovides <name>` against the RHEL 10 repos before
  trusting a package list carried over from a RHEL 9 blueprint.
- **The composed image is a build artifact, not storage.** Assume a limited
  life in Red Hat's project; Part 2 is what makes it durable.
- **`infra.osbuild` is not relevant here.** It drives an on-prem composer
  socket over SSH, not the hosted API.

## Layout

```
ansible.cfg
inventory.yml                     localhost, connection: local
group_vars/all/main.yml           endpoints, delivery target, defaults
docs/service-account.md           console-side RBAC setup
blueprints/
  lab-base-rhel-10.2.yml          edit these
  .remote-state.json              slug -> id + version (committed)
roles/
  rh_auth/                        service account -> access token
  rh_blueprint_pull/              list + fetch -> local YAML
  rh_blueprint_push/              validate, drift check, upsert
  rh_compose/                     compose, poll, write manifest
pull-blueprints.yml
build-image.yml
.build/                           handoff manifests (gitignored)
```
