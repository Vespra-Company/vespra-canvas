import { Icons } from '@onlook/ui/icons';
import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';

/**
 * Shared layout configurations
 *
 * you can customise layouts individually from:
 * Home Layout: app/(home)/layout.tsx
 * Docs Layout: app/docs/layout.tsx
 */
function DocsMark({ className }: { className?: string }) {
    return (
        <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 16 16"
            fill="none"
            aria-hidden="true"
            className={className}
        >
            <rect
                x="0.75"
                y="0.75"
                width="14.5"
                height="14.5"
                rx="3"
                stroke="currentColor"
                strokeWidth="1.5"
            />
            <path
                d="M4.5 5.25 8 11.25 11.5 5.25"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
            />
        </svg>
    );
}

export const baseOptions: BaseLayoutProps = {
    nav: {
        title: (
            <div className="flex items-center gap-2">
                <DocsMark className="w-4 h-4" />
                <span>Vespra Canvas Docs</span>
            </div>
        ),
    },
    links: [
        {
            type: 'main',
            text: 'GitHub',
            url: 'https://github.com/Vespra-Company/vespra-canvas',
            external: true,
            icon: <Icons.GitHubLogo className="w-4 h-4" />
        },
        {
            type: 'main',
            text: 'Discord',
            url: 'https://discord.gg/hERDfFZCsH',
            external: true,
            icon: <Icons.DiscordLogo className="w-4 h-4" />
        }
    ]
};
