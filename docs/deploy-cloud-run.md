# Deploy Vespra Canvas to Cloud Run

This deploys the Next.js web app (`apps/web/client`) to Cloud Run in `us-east1`. Supabase Cloud stays the database, auth, and storage backend. CodeSandbox stays the sandbox provider. Nothing in this repo deploys automatically: `.github/workflows/deploy-cloud-run.yml` is `workflow_dispatch` only.

The container listens on `$PORT`. Cloud Run sets that to `8080`. A local run defaults to `3000`.

Lean service settings (also hardcoded in the workflow):

| Setting | Value |
| --- | --- |
| Region | `us-east1` |
| Min instances | `0` (scale to zero) |
| Max instances | `4` |
| CPU | `1` |
| Memory | `1Gi` |
| Concurrency | `20` |
| Request timeout | `300s` |
| CPU boost | on (faster cold starts) |
| Execution environment | gen2 |
| Ingress auth | public (`--allow-unauthenticated`); app auth is Supabase |

Server secrets are injected at runtime from Secret Manager. They are not build args and are not baked into the image. `NEXT_PUBLIC_*` values are inlined into the browser bundle, so changing them requires a new image.

## 1. Prerequisites

- `gcloud` authenticated as a principal that can create the resources below
- GitHub repo admin on `Vespra-Company/vespra-canvas` (to set Actions variables)
- No JSON service-account keys. GitHub Actions uses Workload Identity Federation.

```bash
export PROJECT_ID="your-gcp-project"
export REGION="us-east1"
export GITHUB_REPO="Vespra-Company/vespra-canvas"
export RUNTIME="vespra-canvas-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
export DEPLOYER="vespra-canvas-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config set project "$PROJECT_ID"
```

## 2. Enable APIs

```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID"
```

## 3. Artifact Registry

```bash
gcloud artifacts repositories create vespra-canvas \
  --project="$PROJECT_ID" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Vespra Canvas web images"
```

Images land at:

```text
us-east1-docker.pkg.dev/PROJECT_ID/vespra-canvas/web:TAG
```

## 4. Service accounts

Two accounts. The deployer pushes images and updates Cloud Run. The runtime account is what the container runs as, and it is the only account that can read server secrets.

```bash
gcloud iam service-accounts create vespra-canvas-deployer \
  --project="$PROJECT_ID" \
  --display-name="Vespra Canvas GitHub deployer"

gcloud iam service-accounts create vespra-canvas-runtime \
  --project="$PROJECT_ID" \
  --display-name="Vespra Canvas Cloud Run runtime"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER}" \
  --role="roles/run.admin"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:${DEPLOYER}" \
  --role="roles/iam.serviceAccountUser"
```

`roles/run.admin` lets the deployer set the public invoker (`allUsers`). If the org policy blocks `allUsers`, the workflow's `--allow-unauthenticated` fails. Either allow it for this project or change the workflow to `--no-allow-unauthenticated` and put a load balancer or IAP in front.

## 5. Workload Identity Federation

No JSON keys. GitHub's OIDC token is exchanged for short-lived GCP credentials. The provider only accepts tokens from this repository.

```bash
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud iam workload-identity-pools create github \
  --project="$PROJECT_ID" \
  --location=global \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github \
  --project="$PROJECT_ID" \
  --location=global \
  --workload-identity-pool=github \
  --display-name="GitHub" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${GITHUB_REPO}"
```

Optional tighter binding: use `attribute.repository/${GITHUB_REPO}/ref/refs/heads/main` if deploys should only run from `main`. `workflow_dispatch` from another branch would then fail.

## 6. GitHub Actions variables

Repository **variables**, not secrets. They are resource names. Do not put API keys or a JSON key in GitHub.

```bash
gh variable set GCP_PROJECT_ID --repo "$GITHUB_REPO" --body "$PROJECT_ID"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --repo "$GITHUB_REPO" --body \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github"
gh variable set GCP_DEPLOYER_SERVICE_ACCOUNT --repo "$GITHUB_REPO" --body "$DEPLOYER"
gh variable set GCP_RUNTIME_SERVICE_ACCOUNT --repo "$GITHUB_REPO" --body "$RUNTIME"
```

You can add a GitHub Environment named `production` with required reviewers and point the job at it later. The workflow does not use an environment today, so a manual run deploys immediately.

## 7. Secret Manager

Create every secret in `us-east1`. Do not commit values. Do not pass server secrets as Docker build args.

```bash
create_secret() {
  local name="$1"
  local file="$2"
  gcloud secrets create "$name" \
    --project="$PROJECT_ID" \
    --replication-policy=user-managed \
    --locations="$REGION" \
    --data-file="$file"
}

grant_runtime() {
  gcloud secrets add-iam-policy-binding "$1" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME}" \
    --role="roles/secretmanager.secretAccessor"
}

grant_deployer_read() {
  gcloud secrets add-iam-policy-binding "$1" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER}" \
    --role="roles/secretmanager.secretAccessor"
}
```

Single-line values (strip a trailing newline so URLs and keys stay exact):

```bash
printf '%s' 'value-here' > /tmp/secret-value
create_secret SECRET_NAME /tmp/secret-value
rm -f /tmp/secret-value
```

Multi-line PEM (GitHub App private key). Keep the file's newlines:

```bash
create_secret GITHUB_APP_PRIVATE_KEY ./github-app.pem
```

After creating a secret, call `grant_runtime SECRET_NAME`. For every `NEXT_PUBLIC_*` secret, also call `grant_deployer_read SECRET_NAME` so the workflow can inline it at build time. The deployer does not need access to server secrets; Cloud Run mounts those as the runtime account.

Add a new version later with:

```bash
gcloud secrets versions add SECRET_NAME \
  --project="$PROJECT_ID" \
  --data-file=/tmp/secret-value
```

The workflow pins `:latest`.

### Required

The process exits on boot if these are missing or empty (`apps/web/client/src/env.ts`). `NEXT_PUBLIC_SITE_URL` has a localhost default in code; set it anyway or invitation links and some redirects stay on localhost.

| Secret | When it is read | What to store |
| --- | --- | --- |
| `NEXT_PUBLIC_SUPABASE_URL` | Build and runtime | Supabase project URL, `https://<ref>.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Build and runtime | Supabase anon (public) key. It ships in the browser bundle. Still store it here so it is not committed. |
| `NEXT_PUBLIC_SITE_URL` | Build and runtime | Public origin, `https://<service>.us-east1.run.app` or your custom domain. No trailing path. |
| `SUPABASE_SERVICE_ROLE_KEY` | Runtime only | Supabase service role key. Bypasses RLS. Never expose it to the browser. |
| `SUPABASE_DATABASE_URL` | Runtime only | Postgres URL. Use the Supabase **pooler** in transaction mode (port `6543`), not the direct `5432` host. Cloud Run is IPv4 and scales to zero; the direct host is often IPv6-only and exhausts sessions. The app already connects with `prepare: false`, which transaction mode requires. User is usually `postgres.<project-ref>`. |
| `CSB_API_KEY` | Runtime only | CodeSandbox API key. The SDK reads this env var. Sandboxes stay on CodeSandbox. |
| `OPENROUTER_API_KEY` | Runtime only | OpenRouter key. Chat is wired to OpenRouter. |

`NODE_ENV=production` is set by the image and again by the workflow. It is not a secret.

### Optional

Create a secret only if you use the feature. The workflow mounts whatever exists from this list and skips the rest. Empty strings are treated as unset.

| Secret | Purpose |
| --- | --- |
| `NEXT_PUBLIC_POSTHOG_KEY` | PostHog project key (browser). Build-time. |
| `NEXT_PUBLIC_POSTHOG_HOST` | PostHog host, for example `https://us.i.posthog.com`. Build-time. |
| `NEXT_PUBLIC_GLEAP_API_KEY` | Gleap in-app feedback. Build-time. |
| `NEXT_PUBLIC_FEATURE_COLLABORATION` | `true` or `false`. Build-time. Defaults to false. |
| `NEXT_PUBLIC_HOSTING_DOMAIN` | Freestyle hosting domain. Build-time. |
| `NEXT_PUBLIC_RB2B_ID` | RB2B tracking id. Build-time. |
| `RESEND_API_KEY` | Invitation email. |
| `FREESTYLE_API_KEY` | Freestyle hosting API. |
| `STRIPE_SECRET_KEY` | Stripe API. |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret. Point the webhook at `https://<site>/api/...` once a route is in use. |
| `MORPH_API_KEY` | Morph fast-apply. |
| `RELACE_API_KEY` | Relace fast-apply. |
| `ANTHROPIC_API_KEY` | Optional direct Anthropic key. Chat itself uses OpenRouter. |
| `OPENAI_API_KEY` | Optional direct OpenAI key. |
| `GOOGLE_AI_STUDIO_API_KEY` | Google AI Studio. |
| `AWS_ACCESS_KEY_ID` | Bedrock. |
| `AWS_SECRET_ACCESS_KEY` | Bedrock. |
| `AWS_REGION` | Bedrock region. |
| `GOOGLE_CLIENT_EMAIL` | Vertex service account email. |
| `GOOGLE_PRIVATE_KEY` | Vertex private key. |
| `GOOGLE_PRIVATE_KEY_ID` | Vertex private key id. |
| `FIRECRAWL_API_KEY` | Site scrape / screenshot tool. |
| `EXA_API_KEY` | Web search tool. |
| `N8N_WEBHOOK_URL` | n8n webhook. |
| `N8N_API_KEY` | n8n API key. |
| `N8N_LANDING_FORM_URL` | Landing-form webhook URL. |
| `N8N_LANDING_FORM_HEADER_NAME` | Optional shared-secret header name. |
| `N8N_LANDING_FORM_HEADER_VALUE` | Optional shared-secret header value. |
| `LANGFUSE_SECRET_KEY` | LLM telemetry. |
| `LANGFUSE_PUBLIC_KEY` | LLM telemetry. |
| `LANGFUSE_BASEURL` | Langfuse base URL. |
| `GITHUB_APP_ID` | GitHub App id. |
| `GITHUB_APP_SLUG` | GitHub App slug. |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App PEM, including line breaks. |

`GOOGLE_PROJECT_ID` and `GOOGLE_LOCATION` appear in `apps/web/client/.env.example` and are not read by `src/env.ts`. Do not create them unless a later change starts using them.

Grant the runtime account on each optional secret you create. Grant the deployer read on optional `NEXT_PUBLIC_*` secrets so they are inlined.

## 8. Supabase and CodeSandbox

In the Supabase dashboard for this project:

- Auth site URL and redirect allow list include `NEXT_PUBLIC_SITE_URL` (and `http://localhost:3000` if you still develop locally).
- Database connection string is the pooler URI from section 7.
- Storage buckets stay on Supabase. The anon key and service role key are the existing project keys. No Cloud Storage bucket is required for this deploy.
- Schema changes stay a manual `bun db:push` / migration against that database. The container does not migrate on boot.

CodeSandbox: create an API key and store it as `CSB_API_KEY`. Preview URLs stay on `csb.app`. This deploy does not run `apps/web/server` or `apps/web/preload`.

## 9. Deploy

Push this branch, then run the workflow by hand:

```text
Actions → Deploy Cloud Run → Run workflow
```

Or from the CLI, after the variables and secrets exist:

```bash
gh workflow run deploy-cloud-run.yml --repo "$GITHUB_REPO" --ref main
```

That builds `Dockerfile`, pushes to Artifact Registry, and deploys. It does not run on push or pull request.

Equivalent manual commands, after `gcloud auth login` as a person who can deploy (not a JSON key):

```bash
export TAG="$(git rev-parse HEAD)"
export IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/vespra-canvas/web"

# BuildKit secret file of shell assignments. Do not commit this file.
# Example line: NEXT_PUBLIC_SUPABASE_URL='https://xxxx.supabase.co'
umask 077
# write /tmp/public.env yourself from Secret Manager, then:
DOCKER_BUILDKIT=1 docker build \
  --secret id=public_env,src=/tmp/public.env \
  --build-arg REQUIRE_PUBLIC_ENV=1 \
  --tag "${IMAGE}:${TAG}" \
  .

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker push "${IMAGE}:${TAG}"
rm -f /tmp/public.env

gcloud run deploy vespra-canvas \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --image="${IMAGE}:${TAG}" \
  --service-account="$RUNTIME" \
  --execution-environment=gen2 \
  --min-instances=0 \
  --max-instances=4 \
  --cpu=1 \
  --memory=1Gi \
  --port=8080 \
  --timeout=300 \
  --concurrency=20 \
  --cpu-boost \
  --allow-unauthenticated \
  --set-env-vars=NODE_ENV=production \
  --set-secrets="CSB_API_KEY=CSB_API_KEY:latest,SUPABASE_DATABASE_URL=SUPABASE_DATABASE_URL:latest,SUPABASE_SERVICE_ROLE_KEY=SUPABASE_SERVICE_ROLE_KEY:latest,OPENROUTER_API_KEY=OPENROUTER_API_KEY:latest,NEXT_PUBLIC_SUPABASE_URL=NEXT_PUBLIC_SUPABASE_URL:latest,NEXT_PUBLIC_SUPABASE_ANON_KEY=NEXT_PUBLIC_SUPABASE_ANON_KEY:latest,NEXT_PUBLIC_SITE_URL=NEXT_PUBLIC_SITE_URL:latest"
```

Add `,NAME=NAME:latest` for each optional secret you created. `--set-secrets` replaces the full set.

### First URL

`NEXT_PUBLIC_SITE_URL` is baked in at build time. On the first deploy, either set it to a custom domain you already control, or:

1. Deploy once with a temporary `https://localhost` style placeholder only if you must.
2. Read the service URL: `gcloud run services describe vespra-canvas --region="$REGION" --format='value(status.url)'`.
3. Store that URL (or the custom domain) in `NEXT_PUBLIC_SITE_URL` and run the workflow again.

Add the final URL to the Supabase auth allow list before asking users to sign in.

Map a custom domain when you have one:

```bash
gcloud run domain-mappings create \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --service=vespra-canvas \
  --domain=app.example.com
```

Use the records `gcloud` prints. Then set `NEXT_PUBLIC_SITE_URL=https://app.example.com` and redeploy so the bundle matches.

## 10. What forces a rebuild

| Change | Rebuild image? |
| --- | --- |
| `NEXT_PUBLIC_*` | Yes. They are compiled into client JavaScript. |
| Server secrets (`CSB_API_KEY`, database URL, OpenRouter, and the other runtime keys) | No. Add a secret version. New instances pick up `:latest`. Existing instances keep the old value until they restart. With min instances 0 that is the next cold start; force it with a new revision: `gcloud run services update vespra-canvas --region="$REGION" --update-secrets=CSB_API_KEY=CSB_API_KEY:latest` |
| App code | Yes. Run the workflow. |

## 11. Local image check

From the repo root, with Docker BuildKit:

```bash
DOCKER_BUILDKIT=1 docker build \
  --build-arg REQUIRE_PUBLIC_ENV=1 \
  --build-arg NEXT_PUBLIC_SUPABASE_URL="https://example.supabase.co" \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY="placeholder" \
  --build-arg NEXT_PUBLIC_SITE_URL="http://localhost:8080" \
  --tag vespra-canvas:local \
  .

docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e NODE_ENV=production \
  -e CSB_API_KEY=placeholder \
  -e OPENROUTER_API_KEY=placeholder \
  -e SUPABASE_SERVICE_ROLE_KEY=placeholder \
  -e SUPABASE_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" \
  -e NEXT_PUBLIC_SUPABASE_URL="https://example.supabase.co" \
  -e NEXT_PUBLIC_SUPABASE_ANON_KEY=placeholder \
  -e NEXT_PUBLIC_SITE_URL="http://localhost:8080" \
  vespra-canvas:local
```

Those placeholders only prove the process binds to `$PORT`. Point the runtime variables at the real Supabase project and CodeSandbox before any real use.

`docker compose --env-file apps/web/client/.env up -d --build` still builds this same Dockerfile for local self-hosting. Compose passes only the public build args. Do not commit `.env`.

## 12. Not in this deploy

- Local Supabase from `apps/backend` (`bun backend:start`)
- `apps/web/server` and `apps/web/preload`
- A second sandbox provider. CodeSandbox remains the provider behind `CSB_API_KEY`.
- Database migration on container start
