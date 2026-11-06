import RAPIER from '@dimforge/rapier3d-compat';
import { solveCollision, SLIDE_DECELERATION, type MotionChannel, type Vector3 } from './collision-model';
import { NPC_PROFILES } from './npc-profiles';
import { StageGeometry, type StageGeometryData } from './stage-geometry';
import { STAT_LIMITS } from './interaction-rules';
import { classifyCollisionFeedback, type CollisionFeedback } from './collision-feedback';
import { characterPrimaryColor, distinctNPCPrimaryColor } from './character-colors';
export type EffectKind = 'grow' | 'shrink' | 'speedUp' | 'speedDown' | 'wind' | 'airdrop' | 'confusion';
export type AnimalKind = 'rabbit' | 'bear' | 'hamster' | 'cat' | 'dog' | 'fox' | 'panda' | 'raccoon';
export const ANIMAL_KINDS: AnimalKind[] = ['rabbit', 'bear', 'hamster', 'cat', 'dog', 'fox', 'panda', 'raccoon'];
export interface Appearance {
    colors: string[];
    image?: string;
}
export interface PlayerConfig {
    id: string;
    name: string;
    animal: AnimalKind;
    character: Appearance;
    ball: Appearance;
    human: boolean;
    npcProfileId?: string;
    baseSize?: number;
    baseSpeed?: number;
}
export type EffectValues = Record<EffectKind, number>;
export interface ImpactEvent {
    a: string;
    b: string;
    x: number;
    y: number;
    z: number;
    at: number;
    closingSpeed: number;
    impulse: number;
    distanceA: number;
    distanceB: number;
    appliedDistanceA: number;
    appliedDistanceB: number;
    normalBeforeA: number;
    normalBeforeB: number;
    normalAfterA: number;
    normalAfterB: number;
    normalX: number;
    normalZ: number;
    outwardA: boolean;
    outwardB: boolean;
    responseMode: string;
    sharedScale: number;
    duration: number;
    enhanced: boolean;
    empoweredIds: string[];
    feedback: CollisionFeedback;
}
export interface EntitySnapshot extends PlayerConfig {
    x: number;
    y: number;
    z: number;
    vx: number;
    vy: number;
    vz: number;
    yaw: number;
    scale: number;
    mass: number;
    radius: number;
    baseSize: number;
    baseSpeed: number;
    actualSpeedFactor: number;
    alive: boolean;
    falling: boolean;
    rank?: number;
    withdrawn?: boolean;
    effects: EffectValues;
    effectRemaining: EffectValues;
    windVx: number;
    windVz: number;
    waterEntry: Vector3 | null;
    collisionCount: number;
    lastImpact: ImpactEvent | null;
    airdrop: {
        progress: number;
        duration: number;
    } | null;
}
export interface Snapshot {
    status: 'ready' | 'intro' | 'countdown' | 'playing' | 'finished';
    elapsedSeconds: number;
    countdownRemaining: number;
    introRemaining: number;
    introDuration: number;
    winnerId: string | null;
    entities: EntitySnapshot[];
    wind: {
        active: boolean;
        remaining: number;
        duration: number;
        direction: Vector3;
        queued: number;
    };
    impacts: ImpactEvent[];
}
export const ISLAND_RADIUS = 8.8; // Legacy UI reference only; support uses the approved irregular outline.
export const BALL_RADIUS = .7;
export const BASE_SPEED = 5.8;
export const COLLISION_BRAKE_DECELERATION = 8;
export const EFFECT_SECONDS = 3;
// Godot project.godot runs the accepted collision controller at 120 Hz.
const FIXED_STEP = 1 / 120;
const WIND_FORCE = 120;
const WIND_DRAG = 6;
const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
const zero = (): Vector3 => ({ x: 0, y: 0, z: 0 });
const vec = (x: number, z: number): Vector3 => ({ x, y: 0, z });
const add = (a: Vector3, b: Vector3): Vector3 => vec(a.x + b.x, a.z + b.z);
const sub = (a: Vector3, b: Vector3): Vector3 => vec(a.x - b.x, a.z - b.z);
const mul = (a: Vector3, k: number): Vector3 => vec(a.x * k, a.z * k);
const dot = (a: Vector3, b: Vector3): number => a.x * b.x + a.z * b.z;
const length = (a: Vector3): number => Math.hypot(a.x, a.z);
const normalized = (a: Vector3): Vector3 => length(a) > 1e-8 ? mul(a, 1 / length(a)) : zero();
const limit = (a: Vector3, max = 1): Vector3 => length(a) > max ? mul(a, max / length(a)) : a;
const moveToward = (a: Vector3, b: Vector3, amount: number): Vector3 => add(a, limit(sub(b, a), amount));
const emptyEffects = (): EffectValues => ({ grow: 0, shrink: 0, speedUp: 0, speedDown: 0, wind: 0, airdrop: 0, confusion: 0 });
const copyConfig = (p: PlayerConfig): PlayerConfig => ({
    ...p, character: { ...p.character, colors: [...(p.character?.colors || [])] },
    ball: { ...p.ball, colors: [...(p.ball?.colors || [])] },
});
type Effect = {
    kind: EffectKind;
    expires: number;
};
type PendingHit = {
    drive: Vector3;
    response: Vector3;
    carry: Vector3;
    preserveDrive: boolean;
};
type Entity = {
    config: PlayerConfig;
    body: RAPIER.RigidBody;
    collider: RAPIER.Collider;
    effects: Effect[];
    sizeDelta: number;
    speedDelta: number;
    airdrop: {
        elapsed: number;
        duration: number;
        startY: number;
        startX: number;
        startZ: number;
        x: number;
        z: number;
    } | null;
    baseSize: number;
    baseSpeed: number;
    scale: number;
    alive: boolean;
    falling: boolean;
    withdrawn: boolean;
    rank?: number;
    yaw: number;
    waterEntry: Vector3 | null;
    frozen: boolean;
    input: Vector3;
    control: Vector3;
    knockback: Vector3;
    wind: Vector3;
    incoming: Vector3;
    sampledResponse: Vector3;
    sampledWind: Vector3;
    pending: PendingHit | null;
    impactAxis: Vector3;
    impactSpeed: number;
    impactRemaining: number;
    impactDriveFloor: number;
    preserveDrive: boolean;
    recovery: number;
    collisionCount: number;
    lastImpact: ImpactEvent | null;
    aiPhase: number;
    aiTarget: string | null;
    nextThink: number;
    chargeUntil: number;
    chargeReady: number;
    charge: Vector3;
    windMode: 'quick' | 'delayed' | 'none';
    windReactAt: number;
    windStrength: number;
    windUntil: number;
    windReacted: boolean;
};
export interface SimulationOptions {
    geometry?: StageGeometryData;
    randomSeed?: number;
    aiEnabled?: boolean;
}
/** Authoritative native-style simulation. Visual animals are not physical colliders. */
export class GameSimulation {
    private world!: RAPIER.World;
    private entities: Entity[] = [];
    private status: Snapshot['status'] = 'ready';
    private clock = 0;
    private accumulator = 0;
    private winnerId: string | null = null;
    private paused = false;
    private countdownRemaining = 0;
    private introRemaining = 0;
    private introDuration = 0;
    private aiSeed = 12345678;
    private rosterSeed: number;
    private windSeed: number;
    private appearanceSeed: number;
    private npcDeck: number[] = [];
    private nextNPCId = 0;
    private windExpires = 0;
    private windQueue = 0;
    private windDirection: Vector3 = vec(1, 0);
    private activeContacts = new Map<string, [
        Entity,
        Entity
    ]>();
    private impacts: ImpactEvent[] = [];
    private disposed = false;
    aiEnabled = true;
    private constructor(readonly stage: StageGeometry, options: SimulationOptions) {
        const randomSeed = options.randomSeed ?? GameSimulation.freshSeed();
        this.rosterSeed = randomSeed || 0x9e3779b9;
        this.windSeed = (randomSeed ^ 0x85ebca6b) || 0x27d4eb2f;
        this.appearanceSeed = (randomSeed ^ 0xc2b2ae35) || 0x165667b1;
        this.aiEnabled = options.aiEnabled ?? true;
    }
    static async create(options: SimulationOptions = {}): Promise<GameSimulation> {
        await RAPIER.init();
        let data = options.geometry;
        if (!data) {
            const meta = import.meta as ImportMeta & {
                env?: {
                    BASE_URL?: string;
                };
            };
            const base = "./";
            // Use the app base, including in the self-contained file:// build whose
            // offline asset map resolves /ball-island/assets/... to embedded data.
            const url = new URL(`${base}assets/native/island/stage_geometry.json`, globalThis.location.href);
            const response = await fetch(url);
            if (!response.ok)
                throw new Error(`海岛场地加载失败 (${response.status})`);
            data = await response.json() as StageGeometryData;
        }
        const sim = new GameSimulation(new StageGeometry(data), options);
        sim.resetWorld();
        return sim;
    }
    private static freshSeed(): number {
        if (globalThis.crypto?.getRandomValues)
            return globalThis.crypto.getRandomValues(new Uint32Array(1))[0];
        return (Date.now() ^ Math.floor(Math.random() * 0xffffffff)) >>> 0;
    }
    private random(stream: 'ai' | 'roster' | 'wind' | 'appearance' = 'ai'): number {
        let state = stream === 'ai' ? this.aiSeed : stream === 'roster' ? this.rosterSeed : stream === 'wind' ? this.windSeed : this.appearanceSeed;
        state ^= state << 13;
        state ^= state >>> 17;
        state ^= state << 5;
        if (stream === 'ai')
            this.aiSeed = state;
        else if (stream === 'roster')
            this.rosterSeed = state;
        else if (stream === 'wind')
            this.windSeed = state;
        else
            this.appearanceSeed = state;
        return (state >>> 0) / 4294967296;
    }
    private resetWorld(): void {
        this.world?.free();
        this.world = new RAPIER.World({ x: 0, y: -20, z: 0 });
        this.world.timestep = FIXED_STEP;
        this.world.numSolverIterations = 8;
        const island = this.world.createRigidBody(RAPIER.RigidBodyDesc.fixed());
        this.world.createCollider(RAPIER.ColliderDesc.trimesh(this.stage.vertices, this.stage.indices)
            .setFriction(0).setRestitution(0), island);
    }
    clear(): void {
        this.resetWorld();
        this.entities = [];
        this.activeContacts.clear();
        this.impacts = [];
        this.npcDeck = [];
        this.status = 'ready';
        this.clock = 0;
        this.accumulator = 0;
        this.winnerId = null;
        this.paused = false;
        this.windExpires = 0;
        this.windQueue = 0;
        this.countdownRemaining = 0;
        this.introRemaining = 0;
        this.introDuration = 0;
        this.nextNPCId = 0;
    }
    start(players: PlayerConfig[], npcCount = 5, countdownSeconds = 3, introSeconds = 1.6): void {
        if (this.disposed)
            throw new Error('Simulation has been disposed');
        this.clear();
        this.aiSeed = 12345678;
        this.shuffleNPCDeck();
        const configs = players.map(copyConfig);
        for (const config of configs) {
            if (!config.human && config.npcProfileId) {
                const index = NPC_PROFILES.findIndex(p => p.npcProfileId === config.npcProfileId);
                this.npcDeck = this.npcDeck.filter(i => i !== index);
            }
        }
        const count = clamp(Math.floor(npcCount), 0, 10);
        for (let i = 0; i < count; i++) {
            const config = this.npcConfig(i);
            config.animal = this.startingAnimal(configs);
            configs.push(config);
        }
        // Reserve human selections first, even if an explicit NPC precedes them.
        const appearances = configs.filter(config => config.human);
        for (const config of configs.filter(config => !config.human)) {
            this.distinguishNPC(config, appearances);
            appearances.push(config);
        }
        if (!configs.length)
            return;
        this.nextNPCId = count;
        const radius = configs.length <= 1 ? 0 : Math.max(2.6, 1.8 / (2 * Math.sin(Math.PI / configs.length)));
        configs.forEach((config, i) => {
            const angle = i / configs.length * Math.PI * 2 - Math.PI / 2;
            this.spawn(config, Math.cos(angle) * radius, Math.sin(angle) * radius);
        });
        this.countdownRemaining = Math.max(0, countdownSeconds);
        this.introDuration = Math.max(0, introSeconds);
        this.introRemaining = this.introDuration;
        this.status = this.introRemaining > 0 ? 'intro' : this.countdownRemaining > 0 ? 'countdown' : 'playing';
        if (this.status === 'playing')
            this.checkFinish();
    }
    private shuffleNPCDeck(): void {
        this.npcDeck = NPC_PROFILES.map((_, i) => i);
        for (let i = this.npcDeck.length - 1; i > 0; i--) {
            const j = Math.floor(this.random('roster') * (i + 1));
            [this.npcDeck[i], this.npcDeck[j]] = [this.npcDeck[j], this.npcDeck[i]];
        }
    }
    private drawNPCProfile(): number {
        const active = new Set(this.aliveEntities().filter(e => !e.config.human).map(e => e.config.npcProfileId));
        for (;;) {
            if (!this.npcDeck.length)
                this.shuffleNPCDeck();
            const index = this.npcDeck.pop()!;
            if (!active.has(NPC_PROFILES[index].npcProfileId))
                return index;
        }
    }
    private npcConfig(index: number): PlayerConfig {
        const profileIndex = this.drawNPCProfile();
        const profile = NPC_PROFILES[profileIndex];
        const ballColors = ['#F1B7B0', '#B9DDE0', '#BEDDBA', '#F5DE98', '#D5C3E5', '#EFC9B1', '#BDCFEB'];
        const color = ballColors[profileIndex % ballColors.length];
        return { id: `npc-${index}`, name: profile.name, npcProfileId: profile.npcProfileId,
            baseSize: profile.baseSize, baseSpeed: profile.baseSpeed, animal: ANIMAL_KINDS[profileIndex % ANIMAL_KINDS.length],
            human: false, character: { colors: [] }, ball: { colors: [color, color, color] } };
    }
    private startingAnimal(configs: readonly PlayerConfig[]): AnimalKind {
        const counts = ANIMAL_KINDS.map(animal => configs.filter(config => config.animal === animal).length);
        const minimum = Math.min(...counts);
        const choices = ANIMAL_KINDS.filter((_, index) => counts[index] === minimum);
        // Appearance randomness must not change the attribute deck, AI or wind.
        return choices[Math.floor(this.random('appearance') * choices.length)];
    }
    private distinguishNPC(config: PlayerConfig, peers: readonly PlayerConfig[]): void {
        const sameAnimal = peers.filter(peer => peer.animal === config.animal);
        if (sameAnimal.length)
            config.character.colors = [distinctNPCPrimaryColor(sameAnimal.map(characterPrimaryColor), peers.length)];
    }
    private spawn(rawConfig: PlayerConfig, x: number, z: number): Entity {
        const config = copyConfig(rawConfig);
        const baseSize = config.human ? 1 : clamp(config.baseSize ?? 1, .75, 1.25);
        const baseSpeed = config.human ? 1 : clamp(config.baseSpeed ?? 1, .75, 1.25);
        config.baseSize = baseSize;
        config.baseSpeed = baseSpeed;
        if (config.human)
            delete config.npcProfileId;
        const body = this.world.createRigidBody(RAPIER.RigidBodyDesc.dynamic()
            .setTranslation(x, BALL_RADIUS * baseSize + .025, z).setLinearDamping(0).setAngularDamping(0)
            .lockRotations().setCcdEnabled(true).setCanSleep(false));
        const collider = this.world.createCollider(this.ballDescriptor(baseSize), body);
        const entity: Entity = {
            config, body, collider, baseSize, baseSpeed, scale: baseSize, alive: true, falling: false, withdrawn: false,
            yaw: Math.atan2(-x, -z), waterEntry: null, frozen: false, effects: [],
            sizeDelta: 0, speedDelta: 0, airdrop: null,
            input: zero(), control: zero(), knockback: zero(), wind: zero(), incoming: zero(), sampledResponse: zero(), sampledWind: zero(),
            pending: null, impactAxis: zero(), impactSpeed: 0, impactRemaining: 0, impactDriveFloor: 0,
            preserveDrive: false, recovery: 0, collisionCount: 0, lastImpact: null,
            aiPhase: this.random() * Math.PI * 2, aiTarget: null, nextThink: 0, chargeUntil: 0, chargeReady: 0, charge: zero(),
            windMode: 'none', windReactAt: 0, windStrength: 0, windUntil: 0, windReacted: false,
        };
        if (this.windExpires > this.clock)
            entity.effects.push({ kind: 'wind', expires: this.windExpires });
        this.entities.push(entity);
        return entity;
    }
    private ballDescriptor(scale: number): RAPIER.ColliderDesc {
        return RAPIER.ColliderDesc.ball(BALL_RADIUS * scale).setMass(5 * scale).setFriction(0).setRestitution(0);
    }
    setInput(id: string, x: number, z: number): void {
        if (this.status !== 'playing' || !Number.isFinite(x) || !Number.isFinite(z))
            return;
        const e = this.entities.find(e => e.config.id === id);
        if (e?.config.human && e.alive)
            e.input = limit(vec(x, z));
    }
    setPaused(paused: boolean): void { this.paused = paused; }
    applyEffect(id: string, kind: EffectKind): {
        ok: boolean;
        message: string;
    } {
        if (this.status !== 'playing')
            return { ok: false, message: '比赛开始后才可互动' };
        const e = this.entities.find(e => e.config.id === id);
        if (!e)
            return { ok: false, message: '目标不存在' };
        if (!e.alive || e.falling)
            return { ok: false, message: '目标已落海，本次互动未触发' };
        if (kind === 'airdrop')
            return this.addNPC(true);
        if (e.airdrop)
            return { ok: false, message: '选手落地后才可互动' };
        if (kind === 'confusion') {
            const previous = e.effects.find(effect => effect.kind === 'confusion');
            const expires = Math.max(this.clock, previous?.expires || 0) + 3;
            e.effects = e.effects.filter(effect => effect.kind !== 'confusion');
            e.effects.push({ kind, expires });
            return { ok: true, message: '方向混乱已延长3秒' };
        }
        if (kind === 'wind') {
            if (this.windExpires > this.clock) {
                this.windQueue++;
                return { ok: true, message: '侧风已排队' };
            }
            this.startWind();
            return { ok: true, message: '全场侧风来袭' };
        }
        const size = kind === 'grow' || kind === 'shrink', speed = kind === 'speedUp' || kind === 'speedDown';
        if (!size && !speed)
            return { ok: false, message: '未知互动' };
        const positive = kind === 'grow' || kind === 'speedUp', current = size ? e.scale : this.speedFactor(e), min = size ? STAT_LIMITS.sizeMin : STAT_LIMITS.speedMin, max = size ? STAT_LIMITS.sizeMax : STAT_LIMITS.speedMax;
        if (positive ? current >= max - 1e-6 : current <= min + 1e-6)
            return { ok: false, message: ({ grow: '无法继续变大', shrink: '无法继续变小', speedUp: '无法继续加速', speedDown: '无法继续减速' } as const)[kind as 'grow' | 'shrink' | 'speedUp' | 'speedDown'] };
        const next = Math.round(clamp(current + (positive ? 1 : -1) * (size ? STAT_LIMITS.sizeStep : STAT_LIMITS.speedStep), min, max) * 1e6) / 1e6;
        if (size) {
            e.sizeDelta = next - e.baseSize;
            this.updateSize(e);
        }
        else
            e.speedDelta = next - e.baseSpeed;
        return { ok: true, message: size ? '体积已更新，本局持续生效' : '速度已更新，本局持续生效' };
    }
    private startWind(): void {
        const angle = this.random('wind') * Math.PI * 2;
        this.windDirection = vec(Math.cos(angle), Math.sin(angle));
        this.windExpires = this.clock + EFFECT_SECONDS;
        for (const target of this.aliveEntities().filter(e => !e.airdrop)) {
            target.effects = target.effects.filter(effect => effect.kind !== 'wind');
            target.effects.push({ kind: 'wind', expires: this.windExpires });
        }
        this.assignWindResponses();
    }
    private assignWindResponses(): void {
        const npcs = this.aliveEntities().filter(e => !e.config.human && !e.airdrop);
        const kinds = ['quick', 'delayed', 'none'] as const;
        const modes = npcs.map((_, i) => npcs.length >= 3 && i < 3 ? kinds[i] : kinds[Math.floor(this.random('wind') * 3)]);
        for (let i = modes.length - 1; i > 0; i--) {
            const j = Math.floor(this.random('wind') * (i + 1));
            [modes[i], modes[j]] = [modes[j], modes[i]];
        }
        npcs.forEach((e, i) => {
            e.windMode = modes[i];
            e.windReactAt = this.clock + (e.windMode === 'delayed' ? .35 + this.random('wind') * .65 : 0);
            e.windStrength = e.windMode === 'quick' ? 1 : e.windMode === 'delayed' ? .45 + this.random('wind') * .4 : 0;
            e.windUntil = this.windExpires;
            e.windReacted = false;
            if (e.windMode === 'quick' && this.aiEnabled)
                this.activateWindResponse(e);
        });
    }
    private activateWindResponse(e: Entity): void {
        e.chargeUntil = this.clock;
        e.charge = zero();
        e.windReacted = true;
        e.input = mul(this.windDirection, -e.windStrength);
    }
    addNPC(fromSky = false): {
        ok: boolean;
        message: string;
    } {
        if (this.status !== 'playing')
            return { ok: false, message: '比赛开始后才可加入NPC' };
        if (this.aliveEntities().length >= STAT_LIMITS.maxPlayers)
            return { ok: false, message: '场上人数已满' };
        const config = this.npcConfig(this.nextNPCId++), point = this.landingPoint(BALL_RADIUS * (config.baseSize || 1));
        this.distinguishNPC(config, this.entities.filter(e => !e.withdrawn).map(e => e.config));
        const e = this.spawn(config, point.x, point.z);
        if (fromSky) {
            const floor = BALL_RADIUS * e.scale + .025;
            e.airdrop = { elapsed: 0, duration: 1.8, startY: floor + 4.5, startX: point.x, startZ: point.z, x: point.x, z: point.z };
            e.body.setBodyType(RAPIER.RigidBodyType.KinematicPositionBased, true);
            e.body.setTranslation({ x: point.x, y: e.airdrop.startY, z: point.z }, true);
            e.collider.setSensor(true);
            e.effects = [];
        }
        return { ok: true, message: e.config.name + (fromSky ? '空降入场' : '加入了比赛') };
    }
    private landingPoint(radius: number, exclude?: Entity): {
        x: number;
        z: number;
    } {
        let best = { x: 0, z: 0 }, score = -Infinity;
        for (let i = 0; i < 70; i++) {
            const angle = this.random('roster') * Math.PI * 2, r = Math.sqrt(this.random('roster')) * 5.5, x = Math.cos(angle) * r, z = Math.sin(angle) * r;
            if (this.stage.signedEdgeDistance(x, z) < radius + .8)
                continue;
            let clearance = 100;
            for (const other of this.aliveEntities()) {
                if (other === exclude)
                    continue;
                const p = other.airdrop || other.body.translation();
                clearance = Math.min(clearance, Math.hypot(x - p.x, z - p.z) - BALL_RADIUS * other.scale - radius);
            }
            const value = clearance - r * .035;
            if (value > score) {
                score = value;
                best = { x, z };
            }
        }
        return best;
    }
    private advanceAirdrop(e: Entity, dt: number): void {
        const drop = e.airdrop!;
        drop.elapsed = Math.min(drop.duration, drop.elapsed + dt);
        const progress = drop.elapsed / drop.duration, floor = BALL_RADIUS * e.scale + .025;
        const crowded = progress > .7 && this.aliveEntities().some(other => { if (other === e)
            return false; const p = other.airdrop || other.body.translation(); return Math.hypot(drop.x - p.x, drop.z - p.z) < BALL_RADIUS * (other.scale + e.scale) + .12; });
        if (crowded) {
            const next = this.landingPoint(BALL_RADIUS * e.scale, e), at = e.body.translation();
            drop.startX = at.x;
            drop.startZ = at.z;
            drop.x = next.x;
            drop.z = next.z;
            drop.startY = at.y;
            drop.elapsed = 0;
            drop.duration = .65;
            return;
        }
        if (progress < 1) {
            const t = progress * progress * (3 - 2 * progress);
            e.body.setNextKinematicTranslation({ x: drop.startX + (drop.x - drop.startX) * t, y: drop.startY + (floor - drop.startY) * progress, z: drop.startZ + (drop.z - drop.startZ) * t });
            return;
        }
        e.body.setBodyType(RAPIER.RigidBodyType.Dynamic, true);
        e.body.setTranslation({ x: drop.x, y: floor, z: drop.z }, true);
        e.body.setLinvel(zero(), true);
        e.collider.setSensor(false);
        e.airdrop = null;
        if (this.windExpires > this.clock) {
            e.effects.push({ kind: 'wind', expires: this.windExpires });
            const modes = ['quick', 'delayed', 'none'] as const;
            e.windMode = modes[Math.floor(this.random('wind') * 3)];
            e.windReactAt = this.clock + (e.windMode === 'delayed' ? .35 + this.random('wind') * .65 : 0);
            e.windStrength = e.windMode === 'quick' ? 1 : e.windMode === 'delayed' ? .45 + this.random('wind') * .4 : 0;
            e.windUntil = this.windExpires;
            e.windReacted = false;
        }
    }
    removeNPC(): {
        ok: boolean;
        message: string;
    } {
        if (this.status !== 'playing')
            return { ok: false, message: '比赛开始后才可减少NPC' };
        const e = [...this.entities].reverse().find(e => !e.config.human && e.alive && !e.falling);
        if (!e)
            return { ok: false, message: '场上没有可移除的NPC' };
        e.alive = false;
        e.withdrawn = true;
        e.effects = [];
        e.body.setEnabled(false);
        e.frozen = true;
        this.checkFinish();
        return { ok: true, message: `${e.config.name}已离场` };
    }
    private counts(e: Entity): EffectValues {
        const result = emptyEffects();
        for (const effect of e.effects)
            result[effect.kind]++;
        result.grow = Math.max(0, Math.ceil(e.sizeDelta / STAT_LIMITS.sizeStep - 1e-6));
        result.shrink = Math.max(0, Math.ceil(-e.sizeDelta / STAT_LIMITS.sizeStep - 1e-6));
        result.speedUp = Math.max(0, Math.ceil(e.speedDelta / STAT_LIMITS.speedStep - 1e-6));
        result.speedDown = Math.max(0, Math.ceil(-e.speedDelta / STAT_LIMITS.speedStep - 1e-6));
        return result;
    }
    private updateSize(e: Entity): void {
        const scale = clamp(e.baseSize + e.sizeDelta, STAT_LIMITS.sizeMin, STAT_LIMITS.sizeMax);
        if (Math.abs(scale - e.scale) < .00001)
            return;
        const oldRadius = BALL_RADIUS * e.scale, p = e.body.translation();
        const grounded = !e.falling && p.y > oldRadius - .15 && this.stage.containsPoint(p.x, p.z);
        e.scale = scale;
        e.collider.setRadius(BALL_RADIUS * scale);
        e.collider.setMass(5 * scale);
        e.body.recomputeMassPropertiesFromColliders();
        if (grounded)
            e.body.setTranslation({ x: p.x, y: Math.max(p.y + BALL_RADIUS * scale - oldRadius, BALL_RADIUS * scale + .01), z: p.z }, true);
    }
    private speedFactor(e: Entity): number {
        return clamp(e.baseSpeed + e.speedDelta, STAT_LIMITS.speedMin, STAT_LIMITS.speedMax);
    }
    private npcInput(e: Entity): Vector3 {
        const p = e.body.translation(), v = e.body.linvel();
        if (this.windExpires > this.clock && e.windUntil > this.clock && e.windMode !== 'none' && this.clock >= e.windReactAt) {
            if (!e.windReacted)
                this.activateWindResponse(e);
            return mul(this.windDirection, -e.windStrength);
        }
        if (e.chargeUntil > this.clock)
            return e.charge;
        if (this.stage.signedEdgeDistance(p.x + v.x * .45, p.z + v.z * .45) < 1.2) {
            return limit(sub(mul(normalized(p), -1), mul(v, .12)));
        }
        if (this.clock > e.nextThink) {
            const targets = this.aliveEntities().filter(other => other !== e && !other.airdrop);
            targets.sort((a, b) => {
                const pa = a.body.translation(), pb = b.body.translation();
                return (pa.x - p.x) ** 2 + (pa.z - p.z) ** 2 - (pb.x - p.x) ** 2 - (pb.z - p.z) ** 2;
            });
            e.aiTarget = targets[Math.min(targets.length - 1, this.random() < .78 ? 0 : 1)]?.config.id ?? null;
            e.nextThink = this.clock + .6 + this.random() * .8;
        }
        const target = this.entities.find(other => other.config.id === e.aiTarget && other.alive && !other.airdrop);
        if (!target)
            return limit(mul(p, -.2));
        const t = target.body.translation(), tv = target.body.linvel(), difference = sub(t, p);
        const distance = Math.max(.01, length(difference));
        const outward = Math.hypot(t.x, t.z) > 1.2 ? normalized(t) : normalized(difference);
        const aligned = dot(difference, outward) / distance > .3;
        if (distance < 3.2 && aligned && this.clock > e.chargeReady) {
            e.charge = normalized(add(add(difference, mul(tv, .15)), outward));
            e.chargeUntil = this.clock + .75 + this.random() * .5;
            e.chargeReady = e.chargeUntil + 1.2 + this.random();
            return e.charge;
        }
        const aim = normalized(!aligned && distance < 4 ? sub(sub(t, mul(outward, 2.5)), p) : difference);
        const orbit = Math.sin(this.clock * .8 + e.aiPhase) * .22;
        const courage = .92 + Math.sin(e.aiPhase) * .08;
        const centering = Math.hypot(p.x, p.z) > 6 ? .015 : 0;
        return limit(vec((aim.x - aim.z * orbit - p.x * centering) * courage, (aim.z + aim.x * orbit - p.z * centering) * courage));
    }
    step(dt: number): void {
        if (this.disposed || this.paused || this.status === 'ready' || !Number.isFinite(dt))
            return;
        this.accumulator += clamp(dt, 0, .1);
        while (this.accumulator + 1e-10 >= FIXED_STEP) {
            this.fixedStep(FIXED_STEP);
            this.accumulator = Math.max(0, this.accumulator - FIXED_STEP);
        }
    }
    private fixedStep(dt: number): void {
        if (this.status === 'intro') {
            this.introRemaining = Math.max(0, this.introRemaining - dt);
            if (this.introRemaining < 1e-8) {
                this.introRemaining = 0;
                this.status = this.countdownRemaining > 0 ? 'countdown' : 'playing';
                if (this.status === 'playing')
                    this.checkFinish();
            }
            return;
        }
        if (this.status === 'countdown') {
            this.countdownRemaining = Math.max(0, this.countdownRemaining - dt);
            if (this.countdownRemaining < 1e-8) {
                this.countdownRemaining = 0;
                this.status = 'playing';
                this.checkFinish();
            }
            return;
        }
        if (this.status === 'playing') {
            this.clock += dt;
            if (this.windQueue > 0 && this.windExpires <= this.clock + 1e-8) {
                this.windQueue--;
                this.startWind();
            }
            for (const e of this.entities) {
                if (!e.alive || e.falling)
                    continue;
                if (e.airdrop) {
                    this.advanceAirdrop(e, dt);
                    continue;
                }
                const previous = e.effects.length;
                e.effects = e.effects.filter(effect => effect.expires > this.clock);
                if (previous !== e.effects.length)
                    this.updateSize(e);
                if (!e.config.human)
                    e.input = this.aiEnabled ? this.npcInput(e) : zero();
                this.integrateMotion(e, dt);
            }
        }
        this.world.step();
        this.settleFallen();
        if (this.status !== 'playing')
            return;
        this.resolveContacts();
        // Resolve in stable roster order and stop at one survivor, just as native.
        for (const e of this.entities) {
            if (!e.alive || e.airdrop)
                continue;
            const p = e.body.translation();
            const leftStage = p.y < BALL_RADIUS * e.scale - .4 && this.stage.signedEdgeDistance(p.x, p.z) < .1;
            if (leftStage || e.falling || p.y < -2.2 || Math.hypot(p.x, p.z) > 13) {
                e.rank = this.aliveEntities().length;
                e.alive = false;
                e.falling = true;
                e.effects = [];
                e.input = zero();
                if (p.y < -2.2)
                    this.freezeFallen(e);
                this.checkFinish();
                if ((this.status as Snapshot['status']) === 'finished')
                    return;
            }
        }
        this.checkFinish();
    }
    private integrateMotion(e: Entity, dt: number): void {
        if (e.pending) {
            e.knockback = e.pending.response;
            e.control = e.pending.drive;
            e.impactAxis = normalized(e.knockback);
            e.impactSpeed = length(e.knockback);
            e.impactRemaining = e.impactSpeed / SLIDE_DECELERATION;
            e.impactDriveFloor = dot(e.control, e.impactAxis);
            e.preserveDrive = e.pending.preserveDrive;
            e.pending = null;
            e.recovery = .18;
        }
        const factor = this.speedFactor(e);
        const intent = e.effects.some(effect => effect.kind === 'confusion' && effect.expires > this.clock) ? mul(e.input, -1) : e.input;
        let braking = 0;
        if (e.impactRemaining > 0) {
            const driveAlong = dot(e.control, e.impactAxis), slideSpeed = e.impactSpeed + driveAlong;
            const slideAxis = slideSpeed < 0 ? mul(e.impactAxis, -1) : e.impactAxis;
            braking = clamp(-dot(intent, slideAxis), 0, 1);
            if (braking > 1e-6) {
                // Merge only the axial drive into the slide when actively braking.
                // The total velocity is continuous, but the old retained-drive floor
                // can no longer reintroduce forward motion after the player slows down.
                e.control = sub(e.control, mul(e.impactAxis, driveAlong));
                e.impactAxis = slideAxis;
                e.impactSpeed = Math.abs(slideSpeed);
                e.knockback = mul(slideAxis, e.impactSpeed);
                e.impactDriveFloor = 0;
                e.preserveDrive = false;
                e.impactRemaining = e.impactSpeed / SLIDE_DECELERATION;
                if (e.impactSpeed < .0001)
                    e.recovery = 0;
            }
        }
        let target = mul(limit(intent), BASE_SPEED * factor);
        if (e.impactRemaining > 0) {
            const targetProjection = dot(target, e.impactAxis), controlProjection = dot(e.control, e.impactAxis);
            target = add(target, mul(e.impactAxis, (e.preserveDrive ? Math.max(targetProjection, e.impactDriveFloor) : e.impactDriveFloor) - targetProjection));
            e.control = add(e.control, mul(e.impactAxis, (e.preserveDrive ? Math.max(controlProjection, e.impactDriveFloor) : e.impactDriveFloor) - controlProjection));
        }
        if (e.recovery <= 0) {
            const response = length(intent) > .0001 ? 4 : 1;
            e.control = add(e.control, mul(limit(mul(sub(target, e.control), response), 18 * factor), dt));
        }
        e.recovery = Math.max(0, e.recovery - dt);
        const previousWind = e.wind;
        if (this.counts(e).wind > 0) {
            const terminal = mul(this.windDirection, WIND_FORCE / (5 * e.scale * WIND_DRAG));
            e.wind = add(terminal, mul(sub(previousWind, terminal), Math.exp(-WIND_DRAG * dt)));
        }
        else
            e.wind = moveToward(previousWind, zero(), SLIDE_DECELERATION * dt);
        const averageWind = mul(add(previousWind, e.wind), .5);
        const nextKick = moveToward(e.knockback, zero(), SLIDE_DECELERATION * dt);
        let averageResponse = mul(add(e.knockback, nextKick), .5);
        if (e.impactRemaining > 0) {
            const nextSpeed = Math.max(0, e.impactSpeed - (SLIDE_DECELERATION + COLLISION_BRAKE_DECELERATION * braking) * dt);
            averageResponse = mul(e.impactAxis, (e.impactSpeed + nextSpeed) * .5);
            e.impactSpeed = nextSpeed;
            e.impactRemaining = nextSpeed / SLIDE_DECELERATION;
            e.knockback = mul(e.impactAxis, nextSpeed);
            if (nextSpeed < .0001) {
                e.impactRemaining = 0;
                e.knockback = zero();
                if (braking > 0)
                    e.recovery = 0;
            }
        }
        else
            e.knockback = nextKick;
        const horizontal = add(add(e.control, averageResponse), averageWind), vertical = e.body.linvel().y;
        e.body.setLinvel({ x: horizontal.x, y: Math.min(vertical, 3.5), z: horizontal.z }, true);
        e.incoming = horizontal;
        e.sampledResponse = averageResponse;
        e.sampledWind = averageWind;
        if (length(horizontal) > .15) {
            const targetYaw = Math.atan2(horizontal.x, horizontal.z);
            const difference = Math.atan2(Math.sin(targetYaw - e.yaw), Math.cos(targetYaw - e.yaw));
            e.yaw += difference * Math.min(1, dt * 10);
        }
    }
    private resolveContacts(): void {
        const current = new Map<string, [
            Entity,
            Entity
        ]>();
        const byCollider = new Map(this.entities.map(e => [e.collider.handle, e]));
        for (const a of this.aliveEntities().filter(e => !e.airdrop)) {
            this.world.contactPairsWith(a.collider, collider => {
                const b = byCollider.get(collider.handle);
                if (!b || a === b || !b.alive || b.falling || b.airdrop)
                    return;
                const key = a.config.id < b.config.id ? `${a.config.id}|${b.config.id}` : `${b.config.id}|${a.config.id}`;
                if (current.has(key))
                    return;
                let touching = false;
                this.world.contactPair(a.collider, b.collider, manifold => {
                    for (let i = 0; i < manifold.numContacts(); i++)
                        if (manifold.contactDist(i) <= .02)
                            touching = true;
                });
                if (!touching)
                    return;
                current.set(key, [a, b]);
                if (this.activeContacts.has(key))
                    return;
                const pa = a.body.translation(), pb = b.body.translation();
                const result = solveCollision(a.incoming, b.incoming, 5 * a.scale, 5 * b.scale, sub(pb, pa), 1 / FIXED_STEP);
                if (result.closingSpeed <= .0001)
                    return;
                const empoweredIds = [
                    ...((a.speedDelta > 1e-6 || a.sizeDelta >= .3 - 1e-6) && result.normalBeforeA > .3 ? [a.config.id] : []),
                    ...((b.speedDelta > 1e-6 || b.sizeDelta >= .3 - 1e-6) && result.normalBeforeB < -.3 ? [b.config.id] : []),
                ];
                // Presentation anchor on the touching surfaces, including unequal balls.
                // This does not alter the collision response or either motion channel.
                const contactFraction = a.scale / (a.scale + b.scale);
                const event: ImpactEvent = {
                    a: a.config.id, b: b.config.id,
                    x: pa.x + (pb.x - pa.x) * contactFraction,
                    y: pa.y + (pb.y - pa.y) * contactFraction,
                    z: pa.z + (pb.z - pa.z) * contactFraction,
                    at: this.clock, closingSpeed: result.closingSpeed, impulse: result.impulse,
                    distanceA: result.distanceA, distanceB: result.distanceB,
                    appliedDistanceA: result.appliedDistanceA, appliedDistanceB: result.appliedDistanceB,
                    normalBeforeA: result.normalBeforeA, normalBeforeB: result.normalBeforeB,
                    normalAfterA: result.normalAfterA, normalAfterB: result.normalAfterB,
                    normalX: result.normal.x, normalZ: result.normal.z,
                    outwardA: result.outwardA, outwardB: result.outwardB, responseMode: result.responseMode,
                    sharedScale: result.sharedScale, duration: result.duration,
                    enhanced: empoweredIds.length > 0, empoweredIds,
                    feedback: classifyCollisionFeedback(a.config.id, b.config.id, result.appliedDistanceA, result.appliedDistanceB),
                };
                this.receiveCollision(a, result.baselineA, result.channelA, event);
                this.receiveCollision(b, result.baselineB, result.channelB, event);
                this.impacts.push(event);
                this.impacts = this.impacts.slice(-32);
            });
        }
        // Cached contact stays active until the balls really separate. This prevents
        // multiple kick impulses while a contact manifold flickers near the surface.
        for (const [key, [a, b]] of this.activeContacts) {
            if (!a.alive || !b.alive || a.falling || b.falling)
                continue;
            const pa = a.body.translation(), pb = b.body.translation();
            if (Math.hypot(pa.x - pb.x, pa.y - pb.y, pa.z - pb.z) <= BALL_RADIUS * (a.scale + b.scale) + .02)
                current.set(key, [a, b]);
        }
        this.activeContacts = current;
    }
    private receiveCollision(e: Entity, baseline: Vector3, channel: MotionChannel, event: ImpactEvent): void {
        const n = channel.normal, sampledWind = e.sampledWind;
        let drive = { ...channel.driveVelocity }, response = { ...channel.responseVelocity };
        const motorBaseline = sub(baseline, sampledWind);
        if (channel.preserveDrive)
            drive = sub(drive, sampledWind);
        else {
            const normalWind = mul(n, dot(sampledWind, n));
            drive = sub(drive, sub(sampledWind, normalWind));
            response = sub(response, normalWind);
        }
        if (!e.pending) {
            const carry = e.impactRemaining > 0 ? e.sampledResponse : zero();
            e.pending = { drive: sub(motorBaseline, carry), response: { ...carry }, carry,
                preserveDrive: length(carry) > .000001 ? e.preserveDrive : true };
        }
        const oldNormalResponse = mul(n, dot(e.pending.carry, n));
        e.pending.drive = add(e.pending.drive, add(sub(drive, motorBaseline), oldNormalResponse));
        e.pending.response = add(e.pending.response, sub(response, oldNormalResponse));
        e.pending.preserveDrive = e.pending.preserveDrive && channel.preserveDrive;
        e.collisionCount++;
        e.lastImpact = event;
    }
    private markWaterEntry(e: Entity): void {
        const p = e.body.translation();
        if (e.falling && !e.withdrawn && !e.waterEntry && p.y <= -1.65 + BALL_RADIUS * e.scale)
            e.waterEntry = { x: p.x, y: -1.65, z: p.z };
    }
    private freezeFallen(e: Entity): void {
        this.markWaterEntry(e);
        e.body.setEnabled(false);
        e.frozen = true;
    }
    private settleFallen(): void {
        for (const e of this.entities) {
            this.markWaterEntry(e);
            if (!e.alive && e.falling && !e.frozen) {
                const p = e.body.translation();
                // Leaving the horizontal arena is an elimination, not permission to
                // freeze in midair. Falling bodies keep simulating after settlement.
                if (p.y < -2.2)
                    this.freezeFallen(e);
            }
        }
    }
    private aliveEntities(): Entity[] { return this.entities.filter(e => e.alive && !e.falling); }
    private checkFinish(): void {
        if (this.status !== 'playing')
            return;
        const alive = this.aliveEntities();
        if (alive.length !== 1 || alive[0].airdrop)
            return;
        this.status = 'finished';
        this.winnerId = alive[0].config.id;
        alive[0].rank = 1;
        for (const e of this.entities) {
            if (e.withdrawn) {
                e.body.setEnabled(false);
                e.frozen = true;
            }
            else if (e.alive) {
                // Disabling the dynamic winner while it shares a contact island with
                // the last loser can leave Rapier's CCD contact holding that loser up.
                // A fixed winner preserves the pose without disabling its contact island.
                e.body.setBodyType(RAPIER.RigidBodyType.Fixed, true);
                e.body.setLinvel(zero(), true);
                e.frozen = true;
            }
        }
    }
    snapshot(): Snapshot {
        const remaining = this.status === 'playing' ? Math.max(0, this.windExpires - this.clock) : 0;
        return {
            status: this.status, elapsedSeconds: this.clock, countdownRemaining: this.countdownRemaining,
            introRemaining: this.introRemaining, introDuration: this.introDuration, winnerId: this.winnerId,
            wind: { active: remaining > 0, remaining, duration: EFFECT_SECONDS, direction: { ...this.windDirection }, queued: this.status === 'playing' ? this.windQueue : 0 },
            impacts: this.impacts.map(e => ({ ...e })),
            entities: this.entities.map(e => {
                const p = e.body.translation(), v = e.body.linvel(), effectRemaining = emptyEffects();
                for (const effect of e.effects)
                    effectRemaining[effect.kind] = Math.max(effectRemaining[effect.kind], Math.max(0, effect.expires - this.clock));
                return { ...copyConfig(e.config), x: p.x, y: p.y, z: p.z, vx: v.x, vy: v.y, vz: v.z, yaw: e.yaw,
                    scale: e.scale, mass: 5 * e.scale, radius: BALL_RADIUS * e.scale, baseSize: e.baseSize, baseSpeed: e.baseSpeed,
                    actualSpeedFactor: this.speedFactor(e), alive: e.alive, falling: e.falling, withdrawn: e.withdrawn, rank: e.rank,
                    effects: this.counts(e), effectRemaining, windVx: e.wind.x, windVz: e.wind.z,
                    waterEntry: e.waterEntry ? { ...e.waterEntry } : null, collisionCount: e.collisionCount,
                    airdrop: e.airdrop ? { progress: e.airdrop.elapsed / e.airdrop.duration, duration: e.airdrop.duration } : null,
                    lastImpact: e.lastImpact ? { ...e.lastImpact } : null };
            }),
        };
    }
    dispose(): void {
        if (this.disposed)
            return;
        this.world.free();
        this.entities = [];
        this.status = 'ready';
        this.disposed = true;
    }
}
