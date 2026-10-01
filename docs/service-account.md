# The Red Hat service account

Everything in this repo authenticates as one Red Hat Hybrid Cloud Console
service account. This is the configuration that is known to work, written down
because it is not discoverable from the console UI and the failure mode is
misleading: an under-privileged account authenticates fine and does most of the
job before failing.

## Settings in use

| | |
|---|---|
| Service account | `Claude` |
| Created at | <https://console.redhat.com/iam/service-accounts> |
| User Access group | `image-builder` |
| Group managed at | <https://console.redhat.com/iam/user-access/groups> |
| Granted permissions | `content-sources:repositories:read`, `content-sources:templates:read` |
| Image Builder permissions | none granted directly — see below |
| Credentials on disk | `~/.config/redhat/lab-images.env`, mode `600` |
| Token lifetime | 900s |

## Creating it

1. <https://console.redhat.com/iam/service-accounts> → **Create service
   account**.
2. Copy the **Client ID** and **Client secret** straight into
   `~/.config/redhat/lab-images.env`. The secret is shown **once** and cannot
   be retrieved later; a lost secret means generating a new one.

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

   Type them into the editor, not into a shell command — a shell command lands
   in your history.

A freshly created service account has no privileges beyond the organisation's
Default access group. The next step is what makes it able to build.

## Granting privileges

**Privileges do not attach to a service account.** They attach to a *User
Access group*, which holds roles; the service account is then added to that
group. There is no per-account permission screen, and nothing in the service
accounts page hints at this.

1. ⚙ (Settings) → **User Access** → **Groups**.
2. Open the group — here, `image-builder` — or create one.
3. **Roles** tab → **Add role** → add the roles carrying the two
   `content-sources` read permissions. The console names them
   **`Repositories viewer`** and **`Content Template viewer`**; those two names
   are also what the compose failure message tells you to check.
4. **Service accounts** tab → **Add service account** → `Claude`.

   This is a *separate tab from* **Members**. Members holds users; service
   accounts are not users and will never appear there. Adding the account to
   Members is not possible, and a group with the right roles but nothing on the
   Service accounts tab grants the account nothing.

Steps 1–4 require **Org Admin** or **User Access Admin**. A service account
cannot grant itself anything, and cannot even read its own group membership —
`GET /api/rbac/v1/groups/` returns `403` for it.

## There is no Image Builder role

Searching the role list for "Image Builder" finds nothing to add, and nothing
needs to be added. Image Builder access arrives through the organisation's
**Default access group**, which every principal in the org is in implicitly.
That is why the account can list, create, update and delete blueprints while
holding, by its own account:

```
GET /api/rbac/v1/access/?application=image-builder   →  "count": 0
```

Only the content-sources permissions have to be granted explicitly.

## Why content-sources, for a service that isn't content-sources

Composing an image resolves the Red Hat repositories the packages come from,
and that resolution runs through the content-sources service under the calling
account's identity. So does `GET /blueprints/{id}/export`. Neither reads as a
"repositories" operation from the outside, which is what makes this
mis-diagnose as a broken request.

Blueprint CRUD does **not** check content-sources. An account with zero granted
roles therefore looks completely healthy: `pull-blueprints.yml` succeeds, and
`build-image.yml` succeeds all the way through validation, the drift guard and
the blueprint push, before:

```
403 unable to retrieve Red Hat repositories: user is not authorized -
please check your 'Repositories viewer' or 'Content Template viewer'
permissions
```

`build-image.yml` recognises this specific 403 and prints the fix rather than
an HTTP dump.

## What needs what

Verified against this account.

| Call | Needs | Used by |
|---|---|---|
| `POST sso.redhat.com/.../token` | valid client id + secret | every playbook |
| `GET /image-builder/v1/distributions` | Default access group | push validation |
| `GET /image-builder/v1/blueprints` | Default access group | pull, push |
| `GET /image-builder/v1/blueprints/{id}` | Default access group | pull |
| `POST` / `PUT /image-builder/v1/blueprints` | Default access group | push |
| `GET /image-builder/v1/blueprints/{id}/export` | **content-sources reads** | nothing — see README notes |
| `POST /image-builder/v1/blueprints/{id}/compose` | **content-sources reads** | compose |
| `GET /image-builder/v1/composes/{id}` | Default access group | compose polling |
| `GET /rbac/v1/access/` | Default access group | verification below |
| `GET /rbac/v1/groups/` | Org Admin — **403 for a service account** | — |

## Verifying it

Run this after any change to the group. It is far cheaper than discovering the
answer 20 minutes into a compose.

```sh
set -a; . ~/.config/redhat/lab-images.env; set +a

TOKEN=$(curl -s \
  -d grant_type=client_credentials \
  -d client_id="$RH_CLIENT_ID" \
  -d client_secret="$RH_CLIENT_SECRET" \
  https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -s -H "Authorization: Bearer $TOKEN" \
  'https://console.redhat.com/api/rbac/v1/access/?application=content-sources' \
  | python3 -m json.tool
```

Correct output is `"count": 2`, listing:

```
content-sources:repositories:read
content-sources:templates:read
```

`"count": 0` means the group has no roles, or — more often — that the account
was never added to the group's **Service accounts** tab.

Reading the whole picture, dropping the filter, gives the same two entries and
nothing else; `?application=image-builder` correctly gives `count: 0`.

## Interpreting failures

| Response | Meaning |
|---|---|
| `401` | Token problem — expired (900s), or wrong client id/secret. |
| `403` on compose or export | Missing content-sources reads. Fix the group. |
| `403` on blueprint CRUD | Account is outside the org's Default access group entirely. |
| `400` on compose | Blueprint content, not permissions — check `lint`. |

## Rotating the secret

Generate a new secret on the service account page, replace the value in
`~/.config/redhat/lab-images.env`, and change nothing else. Group membership
survives rotation. Deleting and recreating the account does **not** — a new
account is a new principal and must be added to the group's Service accounts
tab again.
