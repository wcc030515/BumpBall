import type { EffectKind } from './simulation';
const svg = (paths: string) => `<svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
export const INTERACTION_ICONS: Record<EffectKind, string> = {
    confusion: svg('<path d="M6 9h17l-4-4M26 23H9l4 4M23 9l-4 4M9 23l4-4M6 14v-5M26 18v5M12 5v7M20 20v7"/>'),
    grow: svg('<circle cx="16" cy="16" r="6"/><path d="M5 11V5h6M21 5h6v6M27 21v6h-6M11 27H5v-6M6 6l4 4M26 6l-4 4M26 26l-4-4M6 26l4-4"/>'),
    shrink: svg('<circle cx="16" cy="16" r="4"/><path d="M4 4l6 6M5 10h5V5M28 4l-6 6M22 5v5h5M28 28l-6-6M27 22h-5v5M4 28l6-6M10 27v-5H5"/>'),
    speedUp: svg('<path d="M3 9h10M2 15h7M3 22h9M20 8l7 8-7 8M13 10l5 6-5 6"/>'),
    speedDown: svg('<path d="M5 23a12 12 0 1 1 22 0M16 8v3M8 12l2 2M24 12l-2 2M16 21l-5-4"/><circle cx="16" cy="21" r="2"/><path d="M10 28h12"/>'),
    wind: svg('<path d="M3 10h18a4 4 0 1 0-4-4M3 16h22a3 3 0 1 0-3-3M5 22h13a4 4 0 1 1-4 4"/>'),
    airdrop: svg('<path d="M3 14a13 13 0 0 1 26 0M3 14q4-4 8 0 5-4 10 0 4-4 8 0M16 2c-5 3-6 7-5 12M16 2c5 3 6 7 5 12M3 14l10 10M29 14L19 24M11 14l3 9M21 14l-3 9"/><rect x="12" y="23" width="8" height="6" rx="2"/>'),
};
