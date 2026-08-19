# ADR-001: Authentication and Identity

**Status:** Accepted
**Date:** 2026-08-19
**Deciders:** Bhargav
**Applies to:** `backend-api`, `frontend`

---

## Context

The platform is an **internal-only** application deployed on GCP, reachable only through Identity-Aware Proxy (IAP). Constraints established during design review:

- An **org policy bars unauthenticated traffic** to any service in the project.
- IAP access is granted via a **group-scoped IAM binding** (`roles/iap.httpsResourceAccessor` on a Google Group). Users are added to the group; no per-user IAM edits are needed when onboarding.
- All users are internal. There is no external-collaborator requirement, no self-serve signup, and no email-verification requirement.
- Sharing is an **application-level** concern: a workcell has collaborators with roles. IAP cannot express this — it is a binary gate.
- The system is in **pilot phase**. Simplicity is favoured over completeness where the gap is recoverable.

The forces in tension: IAP gives us authentication for free and we should not duplicate it, but IAP tells us nothing about *authorization* within the app, and the app needs a durable, stable identity to hang collaborator rows off.

## Decision

**IAP is the sole authentication boundary. The application performs no authentication of its own.**

**A `users` table, keyed on the IAP subject identifier, is the application's source of truth for identity and the anchor for all sharing and authorization.**

Specifically:

1. `backend-api` derives the caller's identity from IAP-supplied request headers, verified via the IAP JWT assertion.
2. On any authenticated request from a subject with no `users` row, the row is created transparently (upsert) by the shared identity dependency.
3. All authorization (workcell membership, roles) is resolved from the database against `users.id`, never against IAP or IAM.
4. No in-app session, login page, cookie, or token-issuing endpoint exists for end users.

## Options Considered

### Option A: IAP + application `users` table — **CHOSEN**

| Dimension | Assessment |
|---|---|
| Complexity | Low — no auth code to write or maintain |
| Cost | None beyond IAP/LB already in place |
| Scalability | Adequate; identity resolution is one indexed lookup |
| Team familiarity | High |
| Blast radius of a bug | Contained — a bug affects authz, not authn |

**Pros**

- Zero authentication code in the application. Nothing to get wrong, nothing to patch.
- Onboarding is a group membership change; offboarding is the same in reverse and takes effect at the edge.
- Credentials never reach the application. No password, token, or session store to protect.

**Cons**

- Local development and automated tests have no IAP in front of them, so a header-injection dev mode is required — which is itself an auth-bypass risk if it can be reached in production (mitigated below).
- Authentication is invisible in the codebase; a new engineer can mistake the app for unauthenticated.
- Revocation is edge-only: an already-established WebSocket is not re-validated when a user leaves the group.

### Option B: IAP with external identities (Identity Platform)

| Dimension | Assessment |
|---|---|
| Complexity | Medium — user pool, sign-in UI, tenant config |
| Cost | Identity Platform MAU pricing |
| Scalability | High |
| Team familiarity | Low |

**Pros:** Supports external collaborators and self-serve signup; the app owns the user pool.
**Cons:** Solves a problem we do not have. Every user is internal and already in the group. Pure added surface area.

**Revisit if:** the product ever needs to share workcells with users outside the organisation. That is the trigger condition, and it is a real possibility for a research collaboration tool — see *Consequences*.

### Option C: An in-app OIDC/SSO layer behind IAP

| Dimension | Assessment |
|---|---|
| Complexity | High — two auth systems in series |
| Cost | Development and maintenance time |
| Scalability | High |
| Team familiarity | Medium |

**Pros:** Portable off GCP; app-level session control independent of IAP.
**Cons:** Two systems that can disagree. Users authenticate twice or we build silent handoff. No benefit while the app is internal-only and GCP-hosted.

## Trade-off Analysis

The decisive trade-off is **auth surface area vs. portability**.

Option A couples authentication to GCP. That coupling is real but shallow: it lives entirely in one dependency function, and the `users` table — the part that everything else depends on — is provider-agnostic. Migrating to Option B later means rewriting the identity dependency and backfilling `iap_subject` values; it does not touch the schema's foreign keys, the authorization logic, or any endpoint.

Option C buys portability we would pay for continuously and cash in never. Option B buys external-user support we do not currently need.

Given the pilot stage and the internal-only constraint, **Option A is correct now and cheap to move off later**. The migration cost is deliberately kept low by the identity-abstraction provision below.

## Provisions (binding on implementation)

These are not suggestions. Each exists because omitting it produces a specific failure.

### P1 — Identity resolution is a single shared dependency, and it fails closed

All user-facing routes resolve identity through exactly one dependency. It must:

1. Verify the `x-goog-iap-jwt-assertion` JWT: signature against Google's IAP public keys, plus `iss`, `aud`, and expiry.
2. Take the subject from the verified JWT (`sub`), falling back to the `X-Goog-Authenticated-User-Id` header only if the deployment topology is confirmed not to supply the assertion.
3. **Return `401` when the assertion is absent or invalid. Never fall through to an anonymous or default user.**

*Why:* The org policy blocks `allUsers`, but it does not stop an authenticated principal — any service account in the project, or a developer holding `run.invoker` — from reaching the service directly and arriving with no IAP headers. Fail-closed is what makes the network guarantee safe to rely on. Additionally, disable the service's default `run.app` URL, or restrict ingress to `internal-and-cloud-load-balancing`.

> **Verify before implementing:** which identity headers actually arrive differs between IAP-on-load-balancer and IAP-directly-on-Cloud-Run. Confirm empirically in the target configuration and pin the finding in this ADR before writing the middleware. There is a known history of the JWT assertion header being absent in some Cloud Run configurations.

### P2 — Identity is keyed on the IAP subject, never on email

`users.iap_subject` is the stable key and the target of every foreign key. `users.email` is a mutable display and lookup column with a unique index.

*Why:* Email addresses are reassigned. A new hire inheriting `j.smith@company.com` would inherit the previous Smith's workcell memberships if email were the join key. Subject IDs are never reused.

### P3 — The `users` row is created in the identity dependency, not in a specific endpoint

The upsert happens during identity resolution, so it cannot be missed.

*Why:* `GET /workcells` is not reliably the first request a user makes. A shared deep link to a protocol, a bookmarked workcell page, or the WebSocket endpoint can each be a genuine first touch. Anchoring creation to one endpoint produces sporadic failures on precisely the "someone shared a link with me" flow — which is the product's core loop.

Implementation shape:

```
resolve_user(request) -> User:
    subject = verify_iap_assertion(request)      # P1; raises 401
    if user := identity_cache.get(subject):      # process-local, TTL ~5 min
        return user
    user = db.fetch_user_by_subject(subject)     # indexed SELECT, common path
    if user is None:
        user = db.upsert_user(subject, email, display_name)
    identity_cache.set(subject, user)
    return user
```

The upsert must be atomic — two concurrent first requests from the same new user must not both insert:

```sql
INSERT INTO users (iap_subject, email, display_name)
VALUES ($1, $2, $3)
ON CONFLICT (iap_subject)
  DO UPDATE SET email = EXCLUDED.email,
                display_name = EXCLUDED.display_name,
                last_seen_at = now()
RETURNING *;
```

`last_seen_at` updates are throttled to at most once per 5 minutes per user. Do **not** run the unconditional upsert on every request — it turns every read into a write, producing WAL churn and row-level contention on active users.

### P4 — Internal services do not share the user identity dependency

`sandbox-controller` and the sandbox runtime sit on internal paths with no IAP in front of them. They authenticate callers via **service-account ID token verification**, through a separate, explicitly-chosen dependency.

*Why:* If the user identity dependency were mounted on an internal service, any caller able to reach that service could forge a user simply by setting `X-Goog-Authenticated-User-Id`. The two dependencies must be distinct functions with distinct names, and no route may default to either implicitly.

### P5 — The development identity bypass is fail-safe and test-asserted

Local development and integration tests inject identity headers directly. The bypass must be:

- Gated on an explicit environment variable that is **absent by default**;
- Refused at process startup if the runtime environment is production (fail to boot, not fall back);
- Covered by a test that asserts the bypass cannot activate under production configuration.

*Why:* This is the single most likely path from "internal app" to "fully open app". It warrants a test, not a comment.

### P6 — Sharing targets existing users only (pilot scope)

`collaborators.user_id` is `NOT NULL`. Invitation by email resolves against `users.email`; if no row exists, the endpoint returns a typed `422 user_not_found` with the email echoed, so the UI can render "that person hasn't signed in yet."

*Why:* Deferring the invite-before-first-login flow is a legitimate pilot simplification, but it must fail legibly. A bare 500 on a normal user action is not acceptable.

**Revisit when:** the pilot ends. Adding a pending-invitation path later means a new `invitations` table and a resolution step in P3's upsert — additive, no migration of existing rows.

### P7 — Ownership transfer is an admin endpoint, not a UI feature

A workcell whose sole owner has been offboarded is unadministrable. Provide:

- `POST /admin/workcells/{id}/transfer-owner` on a separate router with its own admin dependency;
- Admin identity from configuration (an env-var list of subjects, or a `users.is_admin` column) — **never hardcoded**;
- An `audit_log` row written for every transfer.

No end-user UI is required in the pilot.

### P8 — WebSocket connections are bounded and resumable

IAP authenticates the WebSocket upgrade request, so no application auth layer is needed on the socket. However:

- A load balancer backend service's `timeoutSec` is the **maximum lifetime of a WebSocket connection**, defaulting to **30 seconds**. Cloud Run's request timeout caps it as well (60 minutes maximum, 5 minutes default). **Both must be set explicitly.**
- Even at the ceiling, no connection survives beyond ~60 minutes, so **reconnection is mandatory**.
- After a client sleeps and its IAP cookie expires, the upgrade returns a **302 to the sign-in page**, not a `401`. The client must detect a non-`101` response and trigger a full page reload rather than entering a retry loop.
- IAP does not re-validate an established connection. A user removed from the group keeps their live socket until it drops. **Accepted risk for the pilot**; revisit if the app handles data with stricter revocation requirements.

The architectural consequence is carried in ADR-002: an agent turn must not exist only inside the socket.

## Consequences

**Easier**

- No authentication code to write, test, or patch. No credential storage.
- Onboarding and offboarding are group-membership operations handled outside the app.
- The authorization model is entirely in the database, so it is testable with ordinary fixtures and no auth mocking.

**Harder**

- Local development and CI require the P5 bypass, which must be defended by tests forever.
- The app cannot be demoed or deployed outside GCP without implementing an identity provider.
- Revocation is not immediate for live connections (P8).

**To revisit**

- External collaborators → migrate to Option B. Cost is confined to the identity dependency plus an `iap_subject` backfill.
- End of pilot → implement pending invitations (P6).
- Any tightening of revocation requirements → reconsider P8's accepted risk.

## Action Items

1. [ ] Empirically confirm which IAP headers arrive in the target deployment topology; record the finding in this ADR (P1).
2. [ ] Disable the default `run.app` URL, or set ingress to `internal-and-cloud-load-balancing` (P1).
3. [ ] Set the load balancer backend `timeoutSec` and the Cloud Run request timeout explicitly, for WebSocket lifetime (P8).
4. [ ] Implement `resolve_user` with JWT verification, fail-closed behaviour, read-through cache, and atomic upsert (P1, P3).
5. [ ] Implement `resolve_service_caller` as a separate dependency for internal services (P4).
6. [ ] Implement the dev identity bypass with a startup guard and a test asserting it cannot activate in production (P5).
7. [ ] Implement `POST /admin/workcells/{id}/transfer-owner` with config-driven admin identity and audit logging (P7).
8. [ ] Add integration tests: first-login upsert under concurrency; missing-assertion → 401; internal service rejecting forged user headers.
