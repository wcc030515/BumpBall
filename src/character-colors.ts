import type { AnimalKind, PlayerConfig } from './simulation';
// Measured from the approved November 6 preview. Only the dominant fur layer is editable.
export const PRIMARY_COLORS: Record<AnimalKind, string> = {
    cat: '#f68501', dog: '#d3610a', rabbit: '#f5cb81', raccoon: '#a57e7a',
    panda: '#352e23', fox: '#f96501', bear: '#c9620e', hamster: '#f69c00'
};
export const PRIMARY_SOURCE_LUMINANCE: Record<AnimalKind, number> = {
    cat: .36370079365431596, dog: .22420186869484168, rabbit: .6370932840294976,
    raccoon: .24326182423363538, panda: .02832223377205416, fox: .29449289248663907,
    bear: .21184578365737378, hamster: .4336976414393403
};
export function characterPrimaryColor(config: Pick<PlayerConfig, 'animal' | 'character'>): string {
    const requested = config.character.colors[0];
    return /^#[a-f\d]{6}$/i.test(requested || '') ? requested : PRIMARY_COLORS[config.animal];
}
// Soft body colors, independent of ball colors and gameplay attributes.
const NPC_PRIMARY_PALETTE = ['#df908b', '#e6b578', '#dfcf86', '#b7ca83', '#88bd9e', '#7ebfba',
    '#85b5d7', '#939ed0', '#b19bce', '#cd98bc', '#b89986', '#91aa9e'];
export function distinctNPCPrimaryColor(used: readonly string[], offset: number): string {
    const rgb = (hex: string) => [1, 3, 5].map(at => parseInt(hex.slice(at, at + 2), 16) / 255);
    const existing = used.map(rgb);
    let best = NPC_PRIMARY_PALETTE[0], bestScore = -1;
    for (let i = 0; i < NPC_PRIMARY_PALETTE.length; i++) {
        const color = NPC_PRIMARY_PALETTE[(i + offset) % NPC_PRIMARY_PALETTE.length], candidate = rgb(color);
        // Maximize the nearest color distance, rather than randomly picking a near match.
        const score = Math.min(...existing.map(other => candidate.reduce((sum, value, channel) => sum + [0.30, 0.59, 0.11][channel] * (value - other[channel]) ** 2, 0)));
        if (score > bestScore) {
            best = color;
            bestScore = score;
        }
    }
    if (bestScore > 0)
        return best;
    // Fallen contestants remain visible in their swim rings. Very long rounds
    // can exhaust the palette, so reserve another soft tint instead of repeating one.
    const occupied = new Set(used.map(color => color.toLowerCase()));
    let seed = (offset + 1) >>> 0;
    do {
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        best = '#' + [0, 8, 16].map(shift => Math.round(128 + ((seed >>> shift) & 255) * .4).toString(16).padStart(2, '0')).join('');
    } while (occupied.has(best));
    return best;
}
