import type { EffectKind, EntitySnapshot, Snapshot } from './simulation';
export const STAT_LIMITS = { sizeMin: .5, sizeMax: 2, sizeStep: .1, speedMin: .2, speedMax: 2, speedStep: .2, maxPlayers: 12 } as const;
export function limitReason(kind: EffectKind, entity: EntitySnapshot | undefined, snapshot: Snapshot): string {
    if (kind === 'airdrop')
        return snapshot.entities.filter(e => e.alive && !e.withdrawn).length >= STAT_LIMITS.maxPlayers ? '场上人数已满' : '';
    if (!entity)
        return '';
    if (kind === 'grow' && entity.scale >= STAT_LIMITS.sizeMax - 1e-6)
        return '无法继续变大';
    if (kind === 'shrink' && entity.scale <= STAT_LIMITS.sizeMin + 1e-6)
        return '无法继续变小';
    if (kind === 'speedUp' && entity.actualSpeedFactor >= STAT_LIMITS.speedMax - 1e-6)
        return '无法继续加速';
    if (kind === 'speedDown' && entity.actualSpeedFactor <= STAT_LIMITS.speedMin + 1e-6)
        return '无法继续减速';
    return '';
}
