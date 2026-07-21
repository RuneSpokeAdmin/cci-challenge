# Reference Pipeline: Building, Testing, and Publishing a Docker Image on CircleCI

_A reference architecture for teams standing up a container pipeline that tests
against a real database and publishes to a cloud registry without storing static
credentials._

- **Repository:** _<public GitHub URL>_
- **Passing build:** _<CircleCI build URL>_

---

## The problem this solves

Most teams building their first container pipeline hit the same three walls:

1. **Testing against a real database is awkward.** Mocking the data layer is
   easy but proves little; standing up a real database next to the test run is
   what actually catches integration bugs.
2. **Publishing to the cloud means storing cloud keys** — long-lived AWS
   credentials sitting in the CI provider, which is exactly the kind of secret
   that leaks.
3. **Pipelines do too much work.** Every branch rebuilds and re-publishes
   everything, burning minutes and money on work that never ships.

This pipeline addresses all three. It tests against a live Postgres container,
authenticates to AWS with short-lived OIDC tokens instead of stored keys, and
does expensive work only when it will actually be used.

---

## Overall architecture

The application is a small Flask + SQLAlchemy REST API — a "widgets" service —
backed by Postgres. It is intentionally simple, because the point of the
exercise is the pipeline, not the app. That said, the tests exercise a real
database and the built image is run and health-checked before publish, so
nothing here is theater.

The pipeline has two jobs in one workflow:

```
 commit ─► [ test ] ──(pass AND branch == main)──► [ build-and-publish ]
```

### Job 1 — `test` (runs on every commit and every PR)

The `test` job uses an executor with two containers:

- a **primary** container (`cimg/python:3.12`) that runs the application and the
  test suite, and
- a **secondary "sidecar"** container (`cimg/postgres:16.4`) — an off-the-shelf
  Postgres image that CircleCI starts alongside the primary and exposes on
  `localhost`.

A short **shell script** (`scripts/wait_for_db.sh`) polls the database with
`pg_isready` until it accepts connections — necessary because service
containers boot in parallel with the job, so the job cannot assume the database
is up. Once it is, **pytest** runs the suite against the live database and
writes JUnit XML, which CircleCI ingests through `store_test_results`. Coverage
is uploaded as a build artifact.

### Job 2 — `build-and-publish` (runs only on `main`, only after tests pass)

This job builds the image, proves it works, and ships it:

1. **Build** the custom image from a multi-stage `Dockerfile`, with Docker Layer
   Caching enabled.
2. **Smoke-test** it via a second **shell script** (`scripts/smoke_test.sh`):
   the freshly built image is run as a container against a throwaway Postgres,
   and the script asserts the live `/health` endpoint returns 200. This verifies
   the *image* — not just the source — before anything is published.
3. **Authenticate to AWS via OIDC.** The job exchanges its CircleCI-issued OIDC
   token for short-lived AWS credentials by assuming an IAM role. No AWS access
   keys exist in CircleCI.
4. **Publish** the image to Amazon ECR, tagged with both the commit SHA (for
   traceability and deterministic rollback) and `latest`.

---

## How the components map together

| Component | Role | Connected by |
|---|---|---|
| Flask app (`app/`) | the application under test | imported by tests, packaged by the Dockerfile |
| Postgres sidecar | real database for tests | started by CircleCI in the executor, reached on `localhost:5432` via `DATABASE_URL` |
| `wait_for_db.sh` | readiness gate | run as a step before pytest |
| pytest + `pytest.ini` | tests + JUnit/coverage output | results collected by `store_test_results` |
| `Dockerfile` | custom multi-stage image | built in `build-and-publish` |
| `smoke_test.sh` | validates the built image | runs the image, checks `/health` |
| OIDC → IAM role | keyless AWS auth | `aws-cli/setup` with `role_arn` from a restricted context |
| Amazon ECR | artifact destination | `docker push` after login |
| `aws-oidc` context | holds the role ARN + region | consumed only by the main-only publish job |

The connective tissue worth calling out is the **`DATABASE_URL` environment
variable**. It is defined once as a YAML anchor and merged into both jobs, so
the app talks to the CI sidecar, the compose file, and the smoke-test container
through the same interface. One contract, three environments.

---

## Unique value and CircleCI-specific optimizations

**Keyless publishing with OIDC.** The single most important design choice. AWS
credentials are never stored in CircleCI; the job assumes an IAM role using a
signed OIDC token scoped to this organization. Combined with the branch filter,
this means credentials are reachable *only* by an approved build on the default
branch — satisfying "credentials may not be accessible outside of approved
builds" structurally, not by policy.

**Conditional work via workflow gating.** The publish job `requires: test` and
is filtered to `branches: only: main`. A pull request runs the test job and
stops — it never builds the production image, never touches the registry, and
never gains access to the OIDC context. On a busy repo this is the difference
between paying to build-and-publish on every push and paying only when something
actually ships.

**Docker Layer Caching (DLC).** Enabled on `setup_remote_docker`. Between
builds, unchanged image layers are restored rather than rebuilt. Paired with the
Dockerfile's deliberate layer ordering — dependency manifests copied *before*
application source — a routine code change reuses the cached dependency layer
instead of reinstalling everything. This is the biggest single lever on
build time.

**Dependency caching.** Python dependencies are cached with a key derived from
`requirements-dev.txt`, so installs are near-instant unless dependencies change.

**Multi-stage build for a lean, safer image.** The build stage carries the
compiler toolchain needed for native extensions; the runtime stage copies only
the finished virtualenv and the app, and runs as a non-root user. Smaller
attack surface, smaller image, faster pulls.

**Test results as a first-class signal.** JUnit XML through `store_test_results`
gives CircleCI structured pass/fail data — per-test timing, failure history, and
flaky-test detection — rather than a wall of console output.

---

## Future optimizations and trade-offs to consider

**Parallelism and test splitting.** At current size the suite runs in under a
second, so splitting would add orchestration overhead for no gain. As the suite
grows past a minute or two, CircleCI's `parallelism` with timing-based test
splitting is the next lever.

**Container structure testing.** The smoke test proves the image runs. Tools
like `dgoss` or `container-structure-test` would additionally assert *structure*
— that the right user is set, ports are exposed, and no unexpected packages
shipped. Worth adding for a security-sensitive image; overkill for this demo.

**Vulnerability scanning.** A `trivy` or `ecr` image scan step before publish
would catch known CVEs in base images and dependencies. The trade-off is
build-time latency and the need to decide what severity fails the build — a
policy conversation as much as a technical one.

**Progressive delivery.** Today the pipeline publishes an artifact; it does not
deploy. A natural extension is a deploy stage to ECS/EKS or a PaaS, gated behind
an approval job — continuous delivery with a human release gate, which for many
regulated teams is the right stopping point rather than full continuous
deployment.

**Multi-architecture images.** `docker buildx` could produce `arm64` + `amd64`
manifests so the image runs on Graviton and Apple Silicon alike. The trade-off
is roughly doubled build time, justified once there is real demand for both.

**A private orb.** If this pattern is repeated across many repositories, the
build-test-publish steps could be packaged as a private CircleCI orb — the
golden path written once and versioned, so every team consumes the same secure,
optimized pipeline instead of copy-pasting config that drifts over time.

---

## Summary

This pipeline demonstrates a secure, efficient container workflow: real-database
testing with a sidecar, a cache-optimized multi-stage image, results collected
natively by CircleCI, expensive work gated to only when it ships, and keyless
publishing to Amazon ECR via OIDC. It is a pattern that scales from a single
service to an organization-wide standard without changing its shape.
