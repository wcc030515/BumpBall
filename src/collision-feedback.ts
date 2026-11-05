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
export const IMPACT_SPARK_STYLES: Readonly<Record<ImpactTier, {
    strength: number;
    flecks: number;
    duration: number;
}>> = {
    0: { strength: .75, flecks: 5, duration: .30 },
    1: { strength: .86, flecks: 5, duration: .30 },
    2: { strength: .98, flecks: 6, duration: .30 },
    3: { strength: 1.08, flecks: 7, duration: .30 },
    4: { strength: 1.18, flecks: 7, duration: .30 },
};
