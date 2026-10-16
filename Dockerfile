# syntax=docker/dockerfile:1
# Production image for the Vespra Canvas web app.
#
# Multi-stage Next.js standalone build. The runner listens on $PORT
# (Cloud Run sets this; local Compose defaults to 3000).
#
# Server secrets (CSB_API_KEY, SUPABASE_DATABASE_URL, service role key,
# OPENROUTER_API_KEY, and the rest) are runtime environment only. Do not
# pass them as build args — they would end up in image history.
#
# NEXT_PUBLIC_* values are inlined into the client bundle. Pass them as
# build args (Compose) or as a BuildKit secret file named public_env
# (shell assignments, used by the Cloud Run workflow).

FROM oven/bun:1.3.1 AS deps
WORKDIR /app

COPY package.json bun.lock bunfig.toml ./
COPY apps ./apps
COPY packages ./packages
COPY tooling ./tooling
COPY docs ./docs
COPY eslint.config.js ./

# bun.lock still records apps/admin, which is not in this tree, so
# --frozen-lockfile fails. bun install still resolves from bun.lock.
RUN bun install

FROM oven/bun:1.3.1 AS builder
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1 \
    SKIP_ENV_VALIDATION=1 \
    STANDALONE_BUILD=true \
    CI=true \
    NODE_OPTIONS=--max-old-space-size=4096

COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG REQUIRE_PUBLIC_ENV=0
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL=http://localhost:3000
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_GLEAP_API_KEY
ARG NEXT_PUBLIC_FEATURE_COLLABORATION
ARG NEXT_PUBLIC_HOSTING_DOMAIN
ARG NEXT_PUBLIC_RB2B_ID

ENV REQUIRE_PUBLIC_ENV=$REQUIRE_PUBLIC_ENV \
    NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_POSTHOG_KEY=$NEXT_PUBLIC_POSTHOG_KEY \
    NEXT_PUBLIC_POSTHOG_HOST=$NEXT_PUBLIC_POSTHOG_HOST \
    NEXT_PUBLIC_GLEAP_API_KEY=$NEXT_PUBLIC_GLEAP_API_KEY \
    NEXT_PUBLIC_FEATURE_COLLABORATION=$NEXT_PUBLIC_FEATURE_COLLABORATION \
    NEXT_PUBLIC_HOSTING_DOMAIN=$NEXT_PUBLIC_HOSTING_DOMAIN \
    NEXT_PUBLIC_RB2B_ID=$NEXT_PUBLIC_RB2B_ID

RUN --mount=type=secret,id=public_env,required=false \
    set -eu; \
    if [ -f /run/secrets/public_env ]; then \
      set -a; \
      . /run/secrets/public_env; \
      set +a; \
    fi; \
    if [ "\$REQUIRE_PUBLIC_ENV" = "1" ]; then \
      test -n "\${NEXT_PUBLIC_SUPABASE_URL:-}" || { echo "NEXT_PUBLIC_SUPABASE_URL is required at build time" >&2; exit 1; }; \
      test -n "\${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}" || { echo "NEXT_PUBLIC_SUPABASE_ANON_KEY is required at build time" >&2; exit 1; }; \
      test -n "\${NEXT_PUBLIC_SITE_URL:-}" || { echo "NEXT_PUBLIC_SITE_URL is required at build time" >&2; exit 1; }; \
    fi; \
    ( cd apps/web/client && NODE_ENV=production bun run build ); \
    standalone="apps/web/client/.next/standalone"; \
    if [ ! -f "$standalone/apps/web/client/server.js" ]; then \
      echo "Expected standalone server at $standalone/apps/web/client/server.js" >&2; \
      find "$standalone" -name 'server.js' -o -type d | head -100 >&2; \
      exit 1; \
    fi; \
    cp -a apps/web/client/public "$standalone/apps/web/client/public"; \
    mkdir -p "$standalone/apps/web/client/.next"; \
    cp -a apps/web/client/.next/static "$standalone/apps/web/client/.next/static"

FROM node:22-bookworm-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0 \
    PORT=3000 \
    HOME=/tmp

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1001 nodejs \
    && useradd --system --uid 1001 --gid nodejs --home-dir /tmp --shell /usr/sbin/nologin nextjs

COPY --from=builder --chown=nextjs:nodejs /app/apps/web/client/.next/standalone ./

USER nextjs
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)).then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "apps/web/client/server.js"]
