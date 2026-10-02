# lab-image-builder

RHEL VM images for GCP labs, composed by Red Hat's hosted Image Builder at
console.redhat.com from blueprints kept in this repo.

The work is split in two:

| | Part 1 — build at Red Hat | Part 2 — import to GCP |
| --- | --- | --- |
| Playbooks | `pull-blueprints.yml`, `build-image.yml` | `import-image.yml` |
| Input | `blueprints/<name>.yml` | `.build/*.json` |
| Output | image in **Red Hat's** GCP project, shared to us | image + family in your project, disk file in a bucket |
| Credentials | Red Hat service account | your own gcloud login |

The split is not arbitrary. Image Builder's GCP target always writes into
**Red Hat's own GCP project** and grants access to accounts you nominate —
there is no setting that makes it write into yours. Copying the image across
is a separate job with separate credentials, so it is a separate playbook.

Part 2 does not just copy. For each image it boots a throwaway VM, runs your
configuration playbooks against it, runs a list of checks, and deletes the VM
— or leaves it running if anything failed. Images that pass are then exported
to Cloud Storage as a portable disk file, for everything that cannot consume a
GCE image.

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
4. **gcloud, for Part 2 only** — `brew install --cask google-cloud-sdk`, then
   `gcloud auth login`. Part 2 drives the CLI directly: no Ansible
   collection, no service account key, no ADC JSON.

   It must be authenticated as a principal in `lab_share_with_accounts`
   (`group_vars/all/main.yml`), because that is who Image Builder shared the
   image with. `import-image.yml` warns up front if it is not.

Part 1 needs no GCP credentials at all. Part 2 needs no Red Hat ones.

## Credentials

There are **two** Red Hat credentials in play, and conflating them is what
makes this confusing.

```text
RH_CLIENT_ID + RH_CLIENT_SECRET      long-lived. A password for a robot
         │                           account. Does not expire until you
         │                           rotate it.
         │
         │   POST to sso.redhat.com
         ▼
     access token                    short-lived. Dies after 900 seconds.
         │
         │   Authorization: Bearer …
         ▼
  console.redhat.com/api/image-builder
```

The long-lived pair **never touches Image Builder.** It only ever goes to Red
Hat's SSO server, which trades it for a token; the token is what is attached
to every actual API call. Turning the first into the second is the entire job
of `roles/rh_auth`. And because a GCP compose takes about twenty minutes while
a token lives fifteen, `rh_auth` runs again every poll cycle for a fresh one —
see `lab_poll_*` in `group_vars/all/main.yml`. It is not a once-per-build step.

### Where the long-lived pair lives

**On your laptop**, one file and nothing else:

```text
~/.config/redhat/lab-images.env      mode 0600, outside this repo
```

Outside the repo is the point: a file that is not in the working tree cannot
be `git add`-ed by accident.

**In CI**, the throwaway runner has no such file, so the workflow builds one:

| Hop | What |
| --- | --- |
| GitHub's secret store | encrypted at rest; `RH_CLIENT_ID`, `RH_CLIENT_SECRET` |
| → environment variables | only within the one step that needs them |
| → the same path on disk | `printf` under `umask 077` |
| → destroyed | the runner is wiped minutes later |

Why recreate a file rather than teach the role to read the environment?
Because `rh_auth` stats and slurps a *path*. Giving CI its own code path would
mean two ways of loading credentials to keep correct; writing the file the
role already expects means CI and your laptop run identical code.

### What stops them leaking

Each of these is doing a specific job:

- **`no_log: true`** on every task in `rh_auth` that touches a value — the
  slurp, the parse, the SSO request, and storing the token. This is the one
  that matters most: without it, `ansible-playbook -vvv` prints your client
  secret to the terminal, and in CI into a log the whole internet can read.
- **Only length and lifetime are ever printed** — `token is 1143 chars, valid
  900s`. Enough to debug with, useless to steal.
- **A mode check.** `rh_auth` warns if the file is not `0600`.
- **The workflow never echoes.** `set -eu`, not `set -x`, and `printf`
  straight into the file. GitHub also masks known secret values if they show
  up in a log, but that is a backstop, not the plan.
- **Forks cannot reach them.** The only triggers are `push` to `main`, which
  needs write access, and `workflow_dispatch`. There is deliberately no
  `pull_request_target` — that is the setting that would let a stranger's pull
  request run code with access to the secrets on a public repo.

### Two things to be clear-eyed about

**Anyone with write access to this repo can use these secrets.** Not read them
from the UI — GitHub will not show them back to anyone, including you — but
they could add a workflow step that sends them elsewhere. That is inherent to
CI secrets everywhere, not specific to this setup. What it means in practice:
*push access to this repo is equivalent to holding the Red Hat service
account.* If that set of people is wider than the set you would hand the
account to, narrow one or the other.

**Rotation is a two-place job** now. Regenerate the service account and you
must update both `~/.config/redhat/lab-images.env` and the two GitHub secrets,
or CI starts failing with a 401 while your laptop keeps working.

The blast radius is bounded, at least: this is an Image Builder service
account scoped by a User Access group, not a Red Hat login.

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

```sh
# Import everything built, into the default target, and verify each image
ansible-playbook import-image.yml

# One image, or a different target
ansible-playbook import-image.yml -e blueprint=lab-base-rhel-10.2
ansible-playbook import-image.yml -e target=staging

# Copy only; or copy and verify without the convention-named config playbooks
ansible-playbook import-image.yml -e verify=false
ansible-playbook import-image.yml -e provision=provision/rhsm.yml

# Skip the bucket export, send it somewhere else, or overwrite what is there
ansible-playbook import-image.yml -e export=false
ansible-playbook import-image.yml -e export_bucket=my-bucket -e export_format=vmdk
ansible-playbook import-image.yml -e force_export=true
```

`import-image.yml` reads `.build/*.json` and nothing else, so it can be
re-run after a failure, or days later, without paying for another compose.
It is safe to re-run: the image name embeds the compose timestamp, so the
same compose always resolves to the same name and an existing one is left
alone. Re-running is how you re-verify.

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

## Building from CI

**In one sentence:** when you commit a blueprint, GitHub rents you a temporary
Linux machine for a few minutes, installs Ansible on it, and has it run
`ansible-playbook build-image.yml` — the same command you would type yourself.

That is genuinely all `.github/workflows/build-image.yml` does. Everything
else in it is bookkeeping around that one command. It runs Part 1 only; the
import stays manual until you turn it on.

### What actually happens

You edit `blueprints/lab-base-rhel-10.2.yml` and push it to `main`.

1. **GitHub notices.** The workflow says "wake up when a push to `main`
   changes a file matching `blueprints/*.yml`." Yours does, so a run starts.
2. **A throwaway machine boots.** Blank — no Ansible, no credentials. It
   downloads a copy of the repo.
3. **It installs what it needs.** Just `ansible-core`, which is quick, because
   every role here is pure `ansible.builtin` — no collections, no SDKs.
4. **It writes your credentials to a file.** The playbook reads the Red Hat
   client id and secret from `~/.config/redhat/lab-images.env`. That file
   lives on your laptop and is deliberately not in the repo, so the workflow
   recreates it on the throwaway machine from two values stored in GitHub's
   secret box. [Credentials](#credentials) covers the whole chain.
5. **It runs the build.** `ansible-playbook build-image.yml -e blueprint=…`.
   Red Hat composes the image. About twenty minutes, same as on your laptop.
6. **The machine is destroyed**, credentials file and all. That is the point.

So before it dies, two things have to be rescued.

### The two things it rescues

**The manifest.** The build writes `.build/<slug>.json` — the handoff file
Part 2 reads to know which image to import. `.build/` is gitignored, so it
cannot be committed; instead each successful build attaches it to the run as
an artifact named `build-manifest-<slug>`, kept 90 days:

```sh
gh run download <run-id> -n build-manifest-lab-base-rhel-10.2 -D .build
ansible-playbook import-image.yml
```

**The version number**, which is the genuinely non-obvious one. This repo
remembers the console's version in `blueprints/.remote-state.json`, and
[the drift guard](#the-drift-guard) compares the two: console ahead of the
file means somebody edited the blueprint in the web console, so stop.

But a CI push bumps the console too. If the throwaway machine is destroyed
without writing that down, the *next* build sees console 8 against a recorded
7, concludes someone edited it in the console — when that someone was CI — and
refuses to run. The repo jams until a human forces past it.

So the machine commits that one file back to `main` itself before it goes.
Those are the `Record <slug> version from CI build` commits in the history.
One per build, and they are what stops the repo jamming. Two details follow
from that:

- The step is `if: always()`, not "on success". `rh_blueprint_push` reconciles
  the state file inside an `always:` block, so even a *failed* compose has
  already bumped the version and still needs recording.
- You get one of these commits per build whether or not the blueprint changed.
  `rh_blueprint_push` does not diff the local file against the console copy
  before writing — it PUTs either way — so every run bumps the version. True
  of a laptop run too; CI just does it more often.

> **Doesn't that commit trigger another build, forever?** No, for two
> independent reasons: the trigger watches `blueprints/*.yml` while the bot
> touches only `.remote-state.json`, and GitHub does not start runs from
> pushes made with `GITHUB_TOKEN`. No `[skip ci]` convention needed.

### The three jobs

| Job | What it does |
| --- | --- |
| `select` | Works out which blueprints the commit changed. Usually one; change three and it builds all three, one after another. Deleting one does not try to build it. |
| `build` | Everything in the walkthrough above. |
| `import` | Part 2. **Currently does nothing** — see below. |

### Running it by hand

You do not have to commit anything:

```sh
# build now
gh workflow run build-image.yml -f blueprint=lab-base-rhel-10.2

# just check the credentials still work — ~30s, composes nothing
gh workflow run build-image.yml -f blueprint=lab-base-rhel-10.2 -f dry_run=true

gh run watch
```

`dry_run` runs `pull-blueprints.yml` instead of composing and then throws the
working tree away. It is the one to reach for when something looks broken and
you want to know whether it is the credentials or the build. What it does
*not* prove: pull needs no content-sources permissions, so it can pass while
`POST /compose` is still unauthorised.

### Setup

Two repository secrets, under *Settings → Secrets and variables → Actions*:

| Name | Value |
| --- | --- |
| `RH_CLIENT_ID` | the service account's client id |
| `RH_CLIENT_SECRET` | its secret |

That is the whole setup. What happens to those two values on the runner, what
keeps them out of the logs, and who can effectively use them once they are
there: **[Credentials](#credentials)**.

### Turning the import on

The `import` job at the bottom of the workflow is Part 2, written but inert.
It runs only when the `ENABLE_IMPORT` repository *variable* is set to `true`,
and it needs three things first:

1. **Workload Identity Federation** in the target project, bound to this repo,
   plus a CI service account with compute admin and `storage.objectAdmin` on
   the export bucket. Set `GCP_WORKLOAD_IDENTITY_PROVIDER` and
   `GCP_SERVICE_ACCOUNT` as repository variables. No key file: the job
   requests an OIDC token, which is why it carries `id-token: write`.
2. **`lab_share_with_accounts` must name that service account**, and sharing
   happens at *compose* time. Flipping the switch does not make images that
   were already built importable by CI — they need rebuilding. This is the one
   field coupling the two parts, and it is the easy thing to miss.
3. **`verify=false` to begin with**, which is what the job passes. The verify
   phase SSHes to the throwaway VM; from a GitHub runner that needs port 22
   reachable or IAP configured, and that is a separate piece of work.

## Targets

A target is "everywhere an image can land", named. Adding an environment is
adding a key to `lab_targets` in `group_vars/all/main.yml`, not editing a
playbook:

```yaml
target: lab            # the default; override with -e target=staging

lab_targets:
  lab:
    project: tmm-instruqt-11-26-2021
    zone: us-central1-a
    network: default
    machine_type: e2-medium
    export_bucket: rhdp_images
    provision: []      # optional, extra config playbooks for this target only
    export_format: ""  # optional, overrides lab_export_format
```

`machine_type` and `network` are only ever used by the throwaway verify VM.
This repo publishes images; it does not create lab VMs.

## What the import produces

`lab-base-rhel-10.2` composed at `2026-10-01T19:54:01Z` becomes:

```
image  lab-base-rhel-10-2-20261001-1954
family lab-base-rhel-10-2
```

GCP resource names cannot contain dots and every RHEL point release has one,
so the slug is sanitised. **The family is the handle labs should use** — it
always resolves to the newest image in it, so a rebuild rolls every lab
forward without anyone editing a lab definition:

```sh
gcloud compute instances create my-lab-vm \
  --image-family lab-base-rhel-10-2 --image-project tmm-instruqt-11-26-2021
```

The dated name is the rollback: it never collides with what it replaces, and
pointing at one pins a lab to that exact build. Each image carries
`managed-by`, `blueprint`, `distribution` and `compose-id` labels, so
`gcloud compute images describe` tells you which compose it came from.

## Verifying: configure, then test

With `verify` on (the default), each imported image goes through four phases
on a throwaway VM named `verify-<image>-<random>`:

| Phase | What happens |
| --- | --- |
| `create` | boot an instance from the image just imported |
| `boot` | wait for metadata SSH — which also proves key injection works on an image that bakes in no users |
| `configure` | run the playbooks in `provision/` |
| `test` | run the checks in `tests/` over SSH |

The VM gets `--no-service-account --no-scopes`. It needs to boot and answer
SSH, nothing more, and one left behind after a failure cannot reach the rest
of the project.

### Configuration playbooks

Dropped in `provision/` and picked up by name:

```sh
provision/default.yml                # every image
provision/lab-base-rhel-10.2.yml     # that blueprint only
lab_targets.<target>.provision       # that target only
```

All three are optional and they run in that order. To run something else for
one run: `-e provision=provision/rhsm.yml,provision/lab-users.yml` — an
explicit list replaces the convention entirely, and a path in it that does
not exist is an error rather than a silent skip.

`provision/default.yml` ships with one job: stopping GCP taking the hostname
back. Three separate things reset it — cloud-init's `cc_update_hostname` on
every boot, NetworkManager accepting the name DHCP offers, and a Google
NetworkManager dispatcher hook that truncates an FQDN to its short form on
every interface-up. They fire at different moments, so fixing one and
missing another reads as an intermittent bug. Pass `-e lab_hostname=x.y.z`
to pin a name; with no argument it freezes whatever the VM already has.

**These are ordinary standalone playbooks.** Nothing in them knows about this
repo, and `import-image.yml` shells out to `ansible-playbook` rather than
importing them, so the same file runs by hand against a real lab VM with any
inventory that reaches it. Write `hosts: all` and declare `become: true`
yourself. `provision/example.yml` is a working template; it is deliberately
*not* one of the names picked up automatically.

The generated inventory sets `ansible_host`, `ansible_user` and
`ansible_ssh_private_key_file` from `gcloud compute ssh --dry-run`, which
prints the exact ssh command gcloud would run without running it. That is
the only answer that is right in every case — the login name is derived from
your account under plain metadata SSH but from the directory under OS Login,
and guessing wrong fails as `Permission denied` with no hint which is in
play. It also passes through the image context, so one playbook can branch:
`lab_image_name`, `lab_image_family`, `lab_image_slug`,
`lab_image_distribution`, `lab_gcp_project`, `lab_gcp_zone`,
`lab_gcp_instance`, `lab_target_name`.

**This configures the VM under test, not the published image.** The tests
then run against a configured system, which is what proves the image is a
valid base for your config management. Nothing is re-captured — if you want
the configuration baked in, it belongs in the blueprint, or in a second
image captured from the running VM, which this repo does not do.

### Tests

`tests/default.yml` runs against every image. `tests/<blueprint-slug>.yml`
is **appended** to it, not substituted, so blueprint-specific checks are
additions rather than a fork. Four keys:

```yaml
- name: cloud-init finished and found the GCE datasource
  command: cloud-init status --wait --long
  expect_rc: any                     # default 0; `any` ignores the exit code
  expect_stdout: 'status: done'      # regex, searched anywhere in stdout

- name: no account has a usable password
  command: "sudo awk -F: '$2 !~ /^[!*]/ {print $1}' /etc/shadow | wc -l"
  expect_stdout: '^0$'

- name: no subscription is baked in
  command: sudo subscription-manager status
  expect_rc: 1
```

`command` reaches the remote shell byte for byte — quotes, pipes and
`$` are all safe, because it is passed as an argv element and never goes
through a local shell. Two things to know: anything needing root must say
`sudo`, since the login is unprivileged; and `command` *is* templated by
Ansible, so a literal `{{` or `{%` needs `{% raw %}`.

### When something fails

The VM is **kept** so you can log into the thing that actually broke, and
the playbook prints the two commands you want:

```
4 failure(s) on lab-base-rhel-10-2-20261001-1954.
verify-lab-base-rhel-10-2-20261001-1954-bs70 has been left running [...]

  gcloud compute ssh verify-... --project ... --zone ...
  gcloud compute instances delete verify-... --project ... --zone ... --quiet
```

Set `lab_keep_on_failure: false` to always delete — right for CI, where
nobody is going to log in and look. Either way the report lists every check
with the command, what was expected and what came back, and the run exits
non-zero at the very end so the table is always printed first.

A failure does not un-import anything. The image is in the project; the
result tells you not to point a lab at the family yet.

## Exporting to a bucket

Every image that passes is written to Cloud Storage as a portable disk file —
the handoff to anything that cannot consume a GCE image: RHDP, a libvirt host,
another cloud.

```
gs://rhdp_images/lab-base-rhel-10-2-20261001-1954.qcow2
```

The object name is `<prefix><image name>.<format>`, so it carries the same
compose timestamp the image does and an export can always be traced back to
the build it came from.

```yaml
export: true                  # -e export=false to skip
lab_export_bucket: rhdp_images
lab_export_format: qcow2      # qcow2, vmdk, vhdx, vpc, vdi, or "" for native
lab_export_prefix: ""         # e.g. "rhel-10/" if the bucket needs organising
lab_export_timeout: 2h
force_export: false
```

Bucket and format resolve in that order of specificity: `-e export_bucket=`
beats the target's `export_bucket`, which beats `lab_export_bucket`. An empty
`export_format` means gcloud's native export — a tarred, gzipped `disk.raw` —
and the object is named `.tar.gz` to match. `gs://rhdp_images` already
standardises on qcow2, which is why that is the default here.

**Only images that passed are exported.** An export is an artifact other
people pick up and use, and publishing one this repo has just failed its own
checks on is worse than publishing nothing. `-e verify=false` skips the checks
and exports anyway; that is the deliberate way to say you know.

Three things worth knowing before the first run:

- **It blocks with no output.** `gcloud compute images export` runs a Cloud
  Build job that boots a temporary VM, reads the disk and converts it —
  measured at 4 minutes for the 20 GB RHEL 10.2 image, giving a 2.2 GiB
  qcow2. Allow longer for a bigger disk or a busy zone. The playbook prints a
  console link and a `gcloud builds list` before it blocks.
- **Re-running is free.** An existing object at the same URI is left alone and
  reported, because a collision means the same compose, never a newer one.
  `-e force_export=true` overwrites.
- **It fails for things that are not your permissions.** The export needs
  `cloudbuild.googleapis.com` enabled, the **Cloud Build** service account to
  hold `roles/storage.objectAdmin` on the bucket, and the Compute Engine
  default service account to exist and be enabled — and it can simply lose a
  race for capacity (`ZONE_RESOURCE_POOL_EXHAUSTED`, seen in this project).
  All four surface as the same generic build failure, so the playbook names
  them in the error.

The image is already imported and unaffected by any of that — re-run with
`-e verify=false` to retry just the export.

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
- **CI must not merge the state file, it must re-apply its own key.** The
  obvious write-back is commit-then-rebase, and it is a trap: the file is
  sorted JSON, six lines per blueprint, so two builds recording *neighbouring*
  keys put their changes within a hunk's context of each other and git may
  conflict on an edit that is not actually a conflict. A conflict there wedges
  the repo, which is the thing the write-back exists to prevent. The workflow
  reads back the one key it is entitled to have changed, resets to current
  `main`, and re-applies it with `jq -S --indent 4` — which reproduces
  Ansible's `to_nice_json(sort_keys=True)` byte for byte.
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
- **Part 2 uses the `gcloud` CLI, not `google.cloud`.** The collection route
  needs `ansible-galaxy collection install google.cloud` plus `google-auth`
  plus ADC. The CLI route needs gcloud, which you already have logged in.
  Part 1 reached the Image Builder API with nothing but `ansible.builtin.uri`
  and this keeps the same bargain: no collections, no key files.
- **A boolean that has been through a template is not a boolean.**
  `{{ (a) and (b) }}` where `a` and `b` are themselves templated vars
  compares the *strings* `"True"` and `"False"`, both of which are truthy —
  so every test passes and the suite is worthless while looking perfect.
  Each part needs `| bool`, and results are stored as `"pass"`/`"fail"`
  rather than booleans for the same reason.
- **`cloud-init status` exits 2 on a healthy GCP boot.** `cloud-init-local`
  runs before `metadata.google.internal` resolves, logs a recoverable error,
  retries, and finds `DataSourceGCE` on a later attempt — leaving
  `extended_status: degraded done` and rc 2 forever. The assertion worth
  making is `status: done`; the exit code is noise.
- **Most accounts on a running lab VM are not in the image.** The guest
  agent creates a local account for every project-wide SSH key at boot, so
  counting uids over 1000 measures your GCP project, not your blueprint.
  `/var/lib/google/google_users` is the guest agent's own list of the ones
  it made. `cloud-user` is cloud-init's doing and is on every RHEL cloud
  image. Checking `/etc/shadow` for a usable password is the test that
  actually says something about the image.
- **`subscription-manager status` needs root**, and exits 8 without it —
  not the 1 that means "not registered". A test that forgets `sudo` fails
  for a reason that has nothing to do with the image.
- **`gcloud compute ssh --tunnel-through-iap=false` is not a thing.** It is
  a flag, not a boolean with a value form, and passing one is a hard error.
- **The export's Cloud Build job is regional, and nothing tells you.**
  Passing `--zone us-central1-a` runs the build in `us-central1`, so a plain
  `gcloud builds list` — and the console's default view — show global builds
  only and the job appears to have never existed. You need
  `--region us-central1` on both `builds list` and `builds log`. The
  playbook prints both commands already pinned to the right region.

## Layout

```sh
ansible.cfg
inventory.yml                     localhost, connection: local
group_vars/all/main.yml           endpoints, delivery target, targets, defaults
docs/service-account.md           console-side RBAC setup
.github/workflows/
  build-image.yml                 compose on commit; import job present, off
blueprints/
  lab-base-rhel-10.2.yml          edit these
  .remote-state.json              slug -> id + version (committed)
provision/
  example.yml                     template; not picked up automatically
  default.yml                     runs against every image — hostname pinning
  <blueprint-slug>.yml            if present, that blueprint only
tests/
  default.yml                     checks every image must pass
  lab-base-rhel-10.2.yml          appended for that blueprint
roles/
  rh_auth/                        service account -> access token
  rh_blueprint_pull/              list + fetch -> local YAML
  rh_blueprint_push/              validate, drift check, upsert
  rh_compose/                     compose, poll, write manifest
  gcp_target/                     resolve target, preflight gcloud
  gcp_import/                     copy RH image -> our project + family
  gcp_verify/                     boot, configure, test, tear down
  gcp_export/                     image -> disk file in a bucket
pull-blueprints.yml
build-image.yml
import-image.yml
.build/                           handoff manifests (gitignored)
```
