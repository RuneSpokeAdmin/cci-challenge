# Demo Setup Guide

How to take this repo from clone to a green CircleCI build that publishes to
Amazon ECR over OIDC. About 20 minutes. This walks the AWS Console path (the
click-through), since that's the most legible way to see what's connected to
what. The values shown are the ones this pipeline was built with — swap in your
own account ID, region, and org ID.

## What you need first

- A public GitHub repo with this code in it
- A CircleCI account connected to that repo
- An AWS account you control

The four things we're going to build: an ECR repo (where the image lands), an
OIDC identity provider (so AWS recognizes CircleCI), an IAM role (the permissions
CircleCI gets to borrow), and a CircleCI context (where the role's ID lives,
locked to approved builds).

---

## 1. Create the ECR repository

This is where the pipeline pushes the image.

- AWS Console -> **ECR** -> **Create repository**
- Visibility: **Private** (keep it private — the passing build log is the proof
  it published; there's no reason to expose the registry)
- Name: `cci/widgets-api`
- Leave the rest at defaults (Mutable tags, AES-256 encryption, etc) -> **Create**

You'll get a URI like `091303277324.dkr.ecr.us-east-1.amazonaws.com/cci/widgets-api`.
The account ID at the front (here `091303277324`) and the region (`us-east-1`)
both matter later =, so save them.

---

## 2. Register CircleCI as an OIDC provider in AWS

This allows AWS to trust the signed token CircleCI hands each build. You need
your **CircleCI Organization ID** first: CircleCI -> Organization Settings ->
Overview -> Organization ID. It's a UUID like
`efec6bbc-8eca-45bc-a2d7-2fda82b794bf`.

- AWS Console -> **IAM** -> **Identity providers** -> **Add provider**
- Provider type: **OpenID Connect**
- Provider URL: `https://oidc.circleci.com/org/<YOUR_ORG_ID>`
- Click **Get thumbprint** (this grabs CircleCI's cert fingerprint so AWS can
  verify the token really came from CircleCI)
- Audience: `<YOUR_ORG_ID>` (yes, the org ID again)
- **Add provider**

At this point AWS *recognizes* CircleCI, but hasn't given it permission to do
anything. That's the next step.

---

## 3. Create the IAM role CircleCI assumes

A role is a set of permissions plus a rule about who's allowed to use them.

- IAM -> **Roles** -> **Create role**
- Trusted entity type: **Web identity**
- Identity provider: the `oidc.circleci.com/org/<YOUR_ORG_ID>` one you just made
- Audience: your org ID
- **Next** -> attach a permissions policy. Search **ECR** and select
  `AmazonEC2ContainerRegistryPowerUser` (grants push/pull to ECR). This is a bit
  broad — for production you'd scope it down to just the ECR push actions on this
  one repo. Fine for a reference pipeline.
- **Next** -> name it `circleci-ecr-publisher` -> **Create role**

Open the finished role and copy its **ARN** from the top — it looks like:

```
arn:aws:iam::091303277324:role/circleci-ecr-publisher
```

That ARN is the thing the pipeline was failing on when it was empty during initial setup
(`RoleArn, value: 0`). It's the last missing piece.

---

## 4. Create the restricted CircleCI context

The context is where the role ARN lives, and it's what makes "credentials only
reachable by approved builds" true — only the main-only publish job reads it.

- CircleCI -> **Organization Settings** -> **Contexts** -> **Create Context**
- Name it exactly `aws-oidc`
- Add three environment variables:

| Name | Value |
|---|---|
| `AWS_OIDC_ROLE_ARN` | `arn:aws:iam::091303277324:role/circleci-ecr-publisher` |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPO_NAME` | `cci/widgets-api` |

Because the `build-and-publish` job only runs on `main` and only that job uses
this context, a PR or feature branch can never read these values.

---

## 5. Push and watch it go green

```bash
git commit --allow-empty -m "Trigger build with OIDC wired up"
git push
```

- On a **PR or feature branch**: only `test` runs. No build, no publish, no
  credentials touched.
- On **`main`**: `test` runs, then `build-and-publish` builds the image,
  smoke-tests it, trades its OIDC token for temporary AWS credentials, and pushes
  to ECR.

Confirm the image landed — AWS Console -> ECR -> `cci/widgets-api`, you'll see it
tagged with the commit SHA and `latest`.
