/**
 * Run `build` or `dev` with `SKIP_ENV_VALIDATION` to skip env validation. This is especially useful
 * for Docker builds.
 */
import { NextConfig } from 'next';
import createNextIntlPlugin from 'next-intl/plugin';
import path from 'node:path';
import './src/env';

const nextConfig: NextConfig = {
    devIndicators: false,
};

// Monorepo root. Standalone tracing has to start here so workspace packages
// land in the Docker output at apps/web/client/.next/standalone/apps/web/client.
const repoRoot = path.join(__dirname, '../../..');

if (process.env.STANDALONE_BUILD === 'true') {
    nextConfig.output = 'standalone';
    nextConfig.outputFileTracingRoot = repoRoot;
    nextConfig.outputFileTracingIncludes = {
        '/*': ['./messages/**/*.json'],
    };
} else if (process.env.NODE_ENV === 'development') {
    nextConfig.outputFileTracingRoot = repoRoot;
}

const withNextIntl = createNextIntlPlugin({
    experimental: {
        createMessagesDeclaration: './messages/en.json'
    }
});
export default withNextIntl(nextConfig);
