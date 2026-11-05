/** Approved v1.0.27 presets. The host draws a shuffled deck for every round. */
export interface NPCProfile {
    npcProfileId: string;
    name: string;
    baseSize: number;
    baseSpeed: number;
}
export const NPC_PROFILES: ReadonlyArray<Readonly<NPCProfile>> = Object.freeze([
    { npcProfileId: 'preset-01', name: '豆豆', baseSize: .80, baseSpeed: .80 },
    { npcProfileId: 'preset-02', name: '困困', baseSize: .90, baseSpeed: .75 },
    { npcProfileId: 'preset-03', name: '软糖', baseSize: .75, baseSpeed: .95 },
    { npcProfileId: 'preset-04', name: '慢团', baseSize: 1, baseSpeed: .80 },
    { npcProfileId: 'preset-05', name: '小冲', baseSize: .85, baseSpeed: 1.05 },
    { npcProfileId: 'preset-06', name: '团团', baseSize: 1, baseSpeed: 1 },
    { npcProfileId: 'preset-07', name: '胖墩', baseSize: 1.10, baseSpeed: .95 },
    { npcProfileId: 'preset-08', name: '轻风', baseSize: .95, baseSpeed: 1.10 },
    { npcProfileId: 'preset-09', name: '皮皮', baseSize: 1.05, baseSpeed: 1.05 },
    { npcProfileId: 'preset-10', name: '稳稳', baseSize: 1.15, baseSpeed: .90 },
    { npcProfileId: 'preset-11', name: '闪闪', baseSize: .85, baseSpeed: 1.20 },
    { npcProfileId: 'preset-12', name: '顶顶', baseSize: 1.10, baseSpeed: 1.05 },
    { npcProfileId: 'preset-13', name: '铁墩', baseSize: 1.20, baseSpeed: 1 },
    { npcProfileId: 'preset-14', name: '飞毛腿', baseSize: 1, baseSpeed: 1.20 },
    { npcProfileId: 'preset-15', name: '撞撞', baseSize: 1.15, baseSpeed: 1.10 },
    { npcProfileId: 'preset-16', name: '旋风', baseSize: 1.05, baseSpeed: 1.20 },
    { npcProfileId: 'preset-17', name: '巨石', baseSize: 1.25, baseSpeed: .95 },
    { npcProfileId: 'preset-18', name: '猛冲', baseSize: 1.20, baseSpeed: 1.10 },
    { npcProfileId: 'preset-19', name: '重炮', baseSize: 1.25, baseSpeed: 1.15 },
    { npcProfileId: 'preset-20', name: '雷霆', baseSize: 1.15, baseSpeed: 1.25 },
].map(p => Object.freeze(p)));
