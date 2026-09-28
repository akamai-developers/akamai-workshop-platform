# Student access portal

This directory is mounted directly into a stock PocketBase container:

- `pb_migrations/` creates the private `registrations` collection.
- `pb_hooks/` exposes `POST /api/workshop/register`.
- `pb_public/` serves the student form and classroom QR presenter.

No application image is built by this repository. `generate-student-access.py` uses
`ghcr.io/muchobien/pocketbase:0.40.4` pinned to its multi-architecture OCI digest and
mounts these files through ConfigMaps. PocketBase does not publish an official image or
Kubernetes chart; its [production documentation](https://pocketbase.io/docs/going-to-production/)
provides only an example Dockerfile. The selected community image is maintained at
[muchobien/pocketbase-docker](https://github.com/muchobien/pocketbase-docker).

`generate-pods.sh --student-access cards` removes only the **local generated portal
manifest**. `kubectl apply -f generated/` does not prune a previously deployed portal,
its PVC, or its registrations. Use `deploy.sh` in cards mode for a live transition; that
path explicitly removes the old portal resources and registration PVC. Back up any
registrations you need before switching.

The available third-party Helm chart was not adopted because it targets PocketBase 0.29.3,
while the portal is tested against 0.40.4, and this project already owns the surrounding
namespace, TLS, ingress, and NetworkPolicy generation.

## Updating PocketBase

1. Review PocketBase's changelog and migration notes.
2. Resolve and verify the new multi-architecture image digest.
3. Update the default in `deploy.sh`, `generate-pods.sh`, and
   `generate-student-access.py`.
4. Run the Bats suite and `make verify-student-access POCKETBASE_BIN=/path/to/pocketbase`.
5. Test the generated manifest on a disposable cluster before using it for a workshop.

Do not replace the pinned reference with `latest`.
