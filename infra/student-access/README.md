# Student access portal

The deployment mounts this directory into a PocketBase container:

- `pb_migrations/` creates the private `registrations` collection.
- `pb_hooks/` exposes `POST /api/workshop/register`.
- `pb_public/` serves the sign-up form and classroom QR page.

We don't build an application image here. `generate-student-access.py` uses
`ghcr.io/muchobien/pocketbase:0.40.4`, pinned to a multi-architecture OCI digest,
and mounts the portal files through ConfigMaps. PocketBase's
[production guide](https://pocketbase.io/docs/going-to-production/) gives an example
Dockerfile but no official image or Kubernetes chart. We use the community image
from [muchobien/pocketbase-docker](https://github.com/muchobien/pocketbase-docker).

`generate-pods.sh --student-access cards` removes only the **locally generated
portal manifest**. Running `kubectl apply -f generated/` afterward will not remove
a portal that's already deployed, its PVC, or its registrations. To switch a live
classroom to cards mode, use `deploy.sh`. It removes the portal resources and
registration PVC. Back up any registrations you need first.

We didn't use the third-party Helm chart we found: it targets PocketBase 0.29.3,
while this portal is tested against 0.40.4. This project also generates its own
namespace, TLS, ingress, and NetworkPolicy resources.

## Updating PocketBase

1. Review PocketBase's changelog and migration notes.
2. Resolve and verify the new multi-architecture image digest.
3. Update the default in `deploy.sh`, `generate-pods.sh`, and
   `generate-student-access.py`.
4. Run the Bats suite and `make verify-student-access POCKETBASE_BIN=/path/to/pocketbase`.
5. Test the generated manifest on a disposable cluster before using it for a workshop.

Do not replace the pinned reference with `latest`.
