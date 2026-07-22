# Reference Pipeline: Build, Test, and Publish a Docker Image on CircleCI

A reference pipeline for a team that wants to test a containerized service
against a real database and publish it to a cloud registry — without leaving a
static cloud credential sitting around waiting to leak.

- **Repository:** https://github.com/RuneSpokeAdmin/cci-challenge
- **Passing build:** https://app.circleci.com/pipelines/circleci/WdMV6fYgJiD46iDHM48FP4/34d8b38f-8f84-4ac5-9f7d-5f9d0f0f6089/6/details?useNewPipelines=true&workflowId=b6af7020-7693-41d7-8b07-eab729f459ca

- **Most Recent Passing Build 07/22/26**: https://app.circleci.com/pipelines/circleci/WdMV6fYgJiD46iDHM48FP4/34d8b38f-8f84-4ac5-9f7d-5f9d0f0f6089/11/details?useNewPipelines=true&workflowId=38b77a19-a7b7-4d1f-b9f4-977d5ff3db28&job=f8c961ee-414e-4059-8bce-30ed9868c98e&buildNumber=22&jobType=build


> **Reviewer access:** I've invited Matt Newlin to the CircleCI organization so
> the build links above open directly. He can invite anyone else who needs to
> review. The GitHub repo is public.
---

## What problem this solves

Most teams standing up their first container pipeline hit the same three walls:

1. **Testing against a real database is a pain**, so people mock it — but a mock
   just returns whatever you told it to. It never catches a broken migration or
   a query that fails on the real engine. You end up testing your assumptions
   instead of your code.
2. **Publishing to the cloud usually means storing a cloud key** in the CI
   provider a long-lived credential is exactly the kind of thing that
   can get leaked.
3. **Pipelines doing too much work** — every branch rebuilds and republishes
   everything, burning time and money on work that doesn't ship.

This pipeline handles all three. It tests against a live Postgres container,
authenticates to AWS with short-lived OIDC tokens instead of a stored key, and
only does the expensive build-and-publish work when something's actually going
to ship to production.

---

## The architecture

The app itself is a small Flask + SQLAlchemy REST API — a "widgets" service —
backed by Postgres. It's deliberately simple, because the point here is the
pipeline, not the app. That said, the tests hit a real database and the built
image gets run and health-checked before anything is published, so none of it
is for show.

It's two jobs in one workflow:

```
 commit -> [ test ] --(tests pass AND branch == main)--> [ build-and-publish ]
```

### Job 1 — `test` (runs on every commit and every PR)

This job runs two containers side by side:

- a **primary** container (`cimg/python:3.12`) that runs the app and the tests
- a **sidecar** container (`cimg/postgres:16.4`) — an off-the-shelf Postgres
  image CircleCI starts alongside the primary and puts on the same network, so
  the app reaches it at `localhost`

A short shell script (`scripts/wait_for_db.sh`) polls Postgres with `pg_isready`
until it's actually accepting connections — the containers boot in parallel, so
the job can't just assume the database is up to prevent race conditions.
Once it's ready, pytest runs the suite against the live database and writes JUnit XML, which CircleCI picks up
through `store_test_results`. Coverage goes up as a build artifact.

### Job 2 — `build-and-publish` (only on `main`, only after tests pass)

This one builds the image, proves it works, and ships it:

1. **Build** the image from a multi-stage `Dockerfile`, with Docker Layer
   Caching on.
2. **Smoke-test it** with a second shell script (`scripts/smoke_test.sh`): it
   runs the freshly built image as a container against a throwaway Postgres on a
   shared Docker network and checks that the live `/health` endpoint returns
   200. That proves the *image* works, not just the source.
3. **Authenticate to AWS over OIDC.** The job trades its CircleCI OIDC token for
   temporary AWS credentials by assuming an IAM role. There's no AWS key stored
   in CircleCI at all.
4. **Publish** the image to Amazon ECR, tagged with both the commit SHA (so a
   deploy traces back to an exact commit and rollback is deterministic) and
   `latest`.

---

## How the pieces connect

| Piece | What it does | How it's wired in |
|---|---|---|
| Flask app (`app/`) | the thing under test | imported by the tests, packaged by the Dockerfile |
| Postgres sidecar | real database for the tests | started by CircleCI on the same network, reached at `localhost:5432` via `DATABASE_URL` |
| `wait_for_db.sh` | readiness gate | runs before pytest so the DB is up first |
| pytest + `pytest.ini` | the tests + JUnit/coverage output | results collected by `store_test_results` |
| `Dockerfile` | the custom multi-stage image | built in `build-and-publish` |
| `smoke_test.sh` | proves the built image runs | runs the image against Postgres, checks `/health` |
| OIDC -> IAM role | keyless AWS auth | `aws-cli/setup` assumes the role using the ARN from a restricted context |
| Amazon ECR | where the artifact lands | `docker push` after an OIDC-authenticated login |
| `aws-oidc` context | holds the role ARN, region, repo name | only the main-only publish job can read it |

The piece that ties it together is the `DATABASE_URL` environment variable. It's
defined once (as a YAML anchor) and shared by both jobs, so the app talks to the
CI sidecar, the local docker-compose database, and the smoke-test container all
through the same interface. One connection string, three environments, and the
app never has to know which one it's running in.

---

## What's actually valuable here — the CircleCI features doing the work

**Keyless publishing with OIDC.** This is the important one. There's no AWS key
stored in CircleCI. The job assumes an IAM role using a signed OIDC token scoped
to this org, and gets back temporary credentials that expire. Pair that with the
branch filter and the credentials are reachable *only* by an approved build on
`main` — so "credentials not accessible outside of approved builds" is enforced
by how it's built, not by a policy someone has to remember to follow.

**Only doing work that ships.** The publish job `requires: test` and is filtered
to `branches: only: main`. A pull request runs the tests and stops — it never
builds the production image, never touches the registry, and never gets near the
OIDC context. On a busy repo that's the difference between paying to build and
publish on every single push versus only when something actually ships. It's
also the security boundary: an untrusted PR literally can't reach the job that
holds the cloud credentials.

**Docker Layer Caching plus deliberate layer ordering.** DLC is on in
`setup_remote_docker`, so unchanged image layers come back from previous builds
instead of rebuilding. And the Dockerfile copies the dependency manifest and
installs *before* copying the app source — so a normal code change reuses the
cached dependency layer instead of reinstalling everything. Ordering plus DLC is
the single biggest thing keeping build time down.

**Dependency caching.** Python deps are cached with a key built from a checksum
of `requirements-dev.txt`. If the deps don't change, the key matches and the
install is basically instant. Change a dependency and the checksum changes, the
key misses, and it does a clean install and saves a fresh cache — so it
refreshes itself exactly when it should.

**Multi-stage image.** The build stage carries the compilers needed to install
the native packages; the runtime stage starts clean and copies over only the
finished virtualenv and the app, running as a non-root user. Smaller image,
faster pulls, and a lot less inside it for an attacker to work with.

**Test results as real data.** JUnit XML through `store_test_results` gives
CircleCI structured pass/fail — the test report, per-test timing, failure
history — instead of a wall of console text. That's also what makes timing-based
test splitting and flaky-test detection possible down the road.

---

## What I'd add next, and the trade-offs

**Test splitting / parallelism.** The suite runs in under a second right now, so
splitting would just add overhead. Once it's a couple minutes long, CircleCI can
split it across parallel containers by timing. You don't pay that complexity
until the suite's slow enough to earn it.

**Container structure testing** (`dgoss` / `container-structure-test`). The
smoke test proves the image runs; these would also assert the image is built
right — correct user, expected ports, no unexpected packages. Worth it for a
security-sensitive image, a bit much for this demo.

**Vulnerability scanning** (Trivy or ECR scan) before publish, to catch known
CVEs in the base image and dependencies. The trade-off is added build time plus
a policy call — deciding what severity actually fails the build versus just
warns.

**Progressive delivery.** Right now it publishes an artifact; it doesn't deploy.
The natural next step is a deploy stage behind a manual approval job —
continuous delivery with a human on the release button, which for a lot of
regulated teams is the right place to stop rather than full auto-deploy.

**Multi-arch images** with `docker buildx` — `arm64` and `amd64` so it runs on
Graviton and Apple Silicon. Trade-off is roughly double the build time, worth it
once there's real demand for both.

**A private orb.** If this pattern got repeated across a bunch of repos, I'd
package the build-test-publish steps into a private CircleCI orb — write the
golden path once, version it, and have every team pull the same secure,
optimized pipeline instead of copy-pasting config that drifts over time.

**One thing I'd tighten for production:** the ECR permission I attached
(`AmazonEC2ContainerRegistryPowerUser`) is a little broader than strictly
needed. For a real deployment I'd scope it down to just the ECR push actions on
just this repository — least privilege.

---

## Bottom line

This is a secure, efficient container pipeline: it tests against a real database
with a sidecar, builds a cache-optimized multi-stage image, collects results
natively in CircleCI, only does the expensive work when something's shipping, and
publishes to ECR with zero stored credentials via OIDC. Same shape scales from
one service to an org-wide standard — you just harden it and package it as an orb.

---

## Gotchas worth mentioning

None of this worked first try. These are the four things that broke, in case
you're building something similar and hit the same walls.

**Python couldn't find the app module.** pytest died instantly with
`ModuleNotFoundError: No module named 'app'`. It ran fine locally but not in CI,
because the project root wasn't on Python's import path in the CI environment.
Fix was one line in `pytest.ini`:

```ini
pythonpath = .
```

The code was fine, Python just didn't know where to look.

**`localhost` doesn't mean the same thing in every job.** In the `test` job,
CircleCI puts the app container and the Postgres sidecar on the same network, so
the app reaches the database at `localhost:5432` and it just works. The smoke
test in `build-and-publish` is different — it uses `setup_remote_docker`, which
runs containers on a *separate* machine. So the script's "localhost" was looking
at its own machine, where nothing was listening.

The fix was to stop relying on localhost entirely: put both containers on a
shared Docker network and give them names, so they find each other by name.
The app talks to `smoke-db:5432`, the health check hits `smoke-app:8000`, and
Docker handles the name lookup. Two parts and you need both — same network, and
address by name.

**A race condition between the app and the database.** The smoke test started
Postgres and then immediately started the app. But Postgres takes a few seconds
before it accepts connections, and the app tries to connect the moment it boots.
Sometimes Postgres won the race, sometimes it didn't — same code passed one run
and failed the next, which is the tell. Fixed by polling with `pg_isready`
before starting the app.

The general lesson: don't assume a dependency is ready just because you started
it. Wait for it to actually say it's ready. It's the same reason the `test` job
has `wait_for_db.sh`, and the same idea behind Kubernetes readiness probes and
`depends_on: condition: service_healthy` in compose.

**`set -e` killed a script that had already passed.** The smoke test does the
health check, then runs a second `curl` purely to print the response into the
log. That cosmetic curl occasionally failed — and because `set -euo pipefail` is
on, any failed command aborts the whole script. So a build that had genuinely
passed its check was failing on a throwaway line. Fix:

```bash
docker run ... curl ... || true
```

`|| true` exempts that one command from `set -e`. Strictness is good, but you
have to carve out the commands you don't actually care about.
