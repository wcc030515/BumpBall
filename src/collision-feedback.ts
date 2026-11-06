/** Presentation classification only. These values never feed back into physics. */
export type ImpactTier = 0 | 1 | 2 | 3 | 4;
export interface CollisionFeedback {
    strongerId: string | null;
    tier: ImpactTier;
    gap: number;
}
const EPSILON = 1e-6;
export function classifyCollisionFeedback(a: string, b: string, distanceA: number, distanceB: number): CollisionFeedback {
    const da = Number.isFinite(distanceA) ? Math.max(0, distanceA) : 0;
    const db = Number.isFinite(distanceB) ? Math.max(0, distanceB) : 0;
    const gap = Math.abs(db - da);
    if (gap <= .25 + EPSILON)
        return { strongerId: null, tier: 0, gap };
    const tier: ImpactTier = gap <= 1.5 + EPSILON ? 1 : gap <= 3 + EPSILON ? 2 : gap <= 5 + EPSILON ? 3 : 4;
    // A is stronger when B is the one thrown farther, and vice versa.
    return { strongerId: db > da ? a : b, tier, gap };
}
/** Absolute impulse controls size; the advantage tier controls the existing styling.
 * A normal 5 kg ball moving at 5.8 m/s into an equal stationary ball gives J=29.
 */
export function impactSparkSize(impulse: number): number {
    const magnitude = Number.isFinite(impulse) ? Math.max(0, impulse) : 0;
    const baseSize = Math.max(.6, Math.min(1.7, Math.sqrt(magnitude / 29)));
    const heavy = Math.max(0, Math.min(1, (magnitude - 29) / 58));
    // Double every impact, then smoothly add up to 30% more for heavy contacts.
    return baseSize * 2 * (1 + .3 * heavy * heavy * (3 - 2 * heavy));
}
export const IMPACT_SPARK_STYLES: Readonly<Record<ImpactTier, {
    flecks: number;
    duration: number;
}>> = {
    0: { flecks: 5, duration: .30 },
    1: { flecks: 5, duration: .30 },
    2: { flecks: 6, duration: .30 },
    3: { flecks: 7, duration: .30 },
    4: { flecks: 7, duration: .30 },
};
