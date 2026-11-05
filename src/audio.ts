import { assetUrl } from './asset-url';
import type { EffectKind, Snapshot } from './simulation';
export interface AudioSettings {
    sfx: number;
    music: number;
    sfxMuted: boolean;
    musicMuted: boolean;
}
type AudioBus = 'sfx' | 'music';
type Clip = 'click' | 'select' | 'confirm' | 'bump1' | 'bump2' | 'bumpPower' | 'splash' | 'grow' | 'shrink' | 'spawn' | 'boost' | 'slow' | 'wind' | 'music' | 'count' | 'win' | 'lose' | 'confusion';
type Bus = 'ui' | 'sfx' | 'music';
type Loop = {
    source: AudioBufferSourceNode;
    gain: GainNode;
    level: number;
};
const STORE = 'bumpball-audio-v2';
const LEGACY_STORE = 'bumpball-audio-v1';
const FILES: Record<Clip, string> = {
    click: 'ui-click.ogg', select: 'ui-select.ogg', confirm: 'ui-confirm.ogg', bump1: 'bump-soft.ogg', bump2: 'bump-heavy.ogg',
    splash: 'splash.ogg', grow: 'grow.ogg', shrink: 'shrink.ogg', spawn: 'spawn.ogg', boost: 'boost-loop.ogg', slow: 'slow-loop.ogg',
    wind: 'wind-loop.ogg', music: 'flowerbed-fields.ogg', count: 'countdown.ogg', win: 'victory-steel-drums.mp3', lose: 'defeat-sax.mp3', bumpPower: 'bump-powerful.ogg', confusion: 'confusion-loop.wav',
};
const clamp = (v: number) => Math.max(0, Math.min(1, Number.isFinite(v) ? v : 0));
/** Recorded CC0 assets, with independent UI / gameplay / music buses. */
export class GameAudio {
    private ctx?: AudioContext;
    private master?: GainNode;
    private buses?: Record<Bus, GainNode>;
    private buffers = new Map<Clip, AudioBuffer>();
    private bytes = new Map<Clip, ArrayBuffer>();
    private loops = new Map<string, Loop>();
    private decoding?: Promise<void>;
    private unlocked = false;
    private hidden = document.hidden;
    private playing = false;
    private paused = false;
    private musicOffset = 0;
    private musicStarted = 0;
    private lastImpact = -Infinity;
    private activeShots = new Map<AudioBufferSourceNode, {
        clip: Clip;
        bus: Bus;
    }>();
    private pending: Array<{
        clip: Clip;
        bus: Bus;
        level: number;
        rate: number;
        at: number;
    }> = [];
    private settings: AudioSettings = { sfx: .7, music: .3, sfxMuted: false, musicMuted: true };
    private celebrationUntil = 0;
    private defeatPlayed = false;
    private targets = new Map<string, number>();
    readonly ready: Promise<void>;
    constructor() {
        try {
            const saved = JSON.parse(localStorage.getItem(STORE) || 'null');
            const previous = saved ?? JSON.parse(localStorage.getItem(LEGACY_STORE) || 'null');
            for (const key of ['sfx', 'music'] as const)
                if (typeof previous?.[key] === 'number')
                    this.settings[key] = clamp(previous[key]);
            if (typeof previous?.sfxMuted === 'boolean')
                this.settings.sfxMuted = previous.sfxMuted;
            // Migrate the old music-on default to off once; remember explicit choices
            // made with the new settings while retaining both saved volume levels.
            if (typeof saved?.musicMuted === 'boolean')
                this.settings.musicMuted = saved.musicMuted;
        }
        catch { }
        this.ready = Promise.all((Object.keys(FILES) as Clip[]).map(async (clip) => {
            try {
                const r = await fetch(assetUrl('audio/' + FILES[clip]));
                if (!r.ok)
                    throw Error(String(r.status));
                this.bytes.set(clip, await r.arrayBuffer());
            }
            catch {
                console.warn('音频素材暂时不可用:', FILES[clip]);
            }
        })).then(() => undefined);
        document.addEventListener('visibilitychange', () => {
            this.hidden = document.hidden;
            if (this.hidden) {
                this.stopGameplay();
                this.stopLoop('music');
            }
            else if (this.unlocked) {
                void this.ctx?.resume().catch(() => { });
                this.ensureMusic();
            }
            this.applyVolumes();
        });
    }
    getSettings(): AudioSettings { return { ...this.settings }; }
    setVolume(bus: AudioBus, value: number) {
        this.settings[bus] = clamp(value);
        if (value > 0)
            this.settings[`${bus}Muted`] = false;
        this.applyVolumes();
        try {
            localStorage.setItem(STORE, JSON.stringify(this.settings));
        }
        catch { }
    }
    toggleMute(bus: AudioBus) { this.settings[`${bus}Muted`] = !this.settings[`${bus}Muted`]; this.applyVolumes(); try {
        localStorage.setItem(STORE, JSON.stringify(this.settings));
    }
    catch { } }
    unlock() {
        if (!this.ctx) {
            this.ctx = new AudioContext();
            const c = this.ctx;
            const limiter = c.createDynamicsCompressor();
            limiter.threshold.value = -9;
            limiter.knee.value = 8;
            limiter.ratio.value = 5;
            limiter.attack.value = .004;
            limiter.release.value = .16;
            this.master = c.createGain();
            this.master.connect(limiter).connect(c.destination);
            this.buses = { ui: c.createGain(), sfx: c.createGain(), music: c.createGain() };
            Object.values(this.buses).forEach(bus => bus.connect(this.master!));
            this.applyVolumes();
        }
        this.unlocked = true;
        void this.ctx.resume().catch(() => { });
        this.decoding ??= this.ready.then(async () => {
            await Promise.all([...this.bytes].map(async ([clip, bytes]) => {
                try {
                    this.buffers.set(clip, await this.ctx!.decodeAudioData(bytes.slice(0)));
                }
                catch {
                    console.warn('无法解码音频:', FILES[clip]);
                }
            }));
            this.bytes.clear();
            for (const p of this.pending.splice(0))
                if (performance.now() - p.at < 900)
                    this.shot(p.clip, p.bus, p.level, p.rate);
            this.ensureMusic();
        });
        this.ensureMusic();
    }
    ui(kind: 'click' | 'select' | 'confirm' = 'click') { this.unlock(); this.shot(kind, 'ui', kind === 'confirm' ? .68 : .65); }
    effect(kind: EffectKind) {
        const clip = ({ grow: 'grow', shrink: 'shrink', airdrop: 'spawn' } as Partial<Record<EffectKind, Clip>>)[kind];
        if (clip)
            this.shot(clip, 'sfx', .72);
    }
    countdown() { this.shot('count', 'sfx', .45); }
    bump(speed: number, enhanced = false) {
        if (!this.playing || this.hidden || this.paused || !this.ctx)
            return;
        if (this.ctx.currentTime - this.lastImpact < .055)
            return;
        this.lastImpact = this.ctx.currentTime;
        this.shot(enhanced ? 'bumpPower' : speed > 6 ? 'bump2' : 'bump1', 'sfx', enhanced ? .95 : Math.min(.85, .3 + speed * .045), (enhanced ? .87 : .94) + Math.random() * .1);
    }
    splash() { this.shot('splash', 'sfx', .8, .94 + Math.random() * .1); }
    win() { this.celebrationUntil = (this.ctx?.currentTime || 0) + (this.buffers.get('win')?.duration || 6); this.shot('win', 'sfx', .9); this.applyVolumes(); }
    resetRound() { this.stopGameplay(); this.celebrationUntil = 0; this.defeatPlayed = false; this.lastImpact = -Infinity; this.pending = this.pending.filter(p => p.bus === 'ui'); for (const [source, info] of this.activeShots)
        if (info.bus === 'sfx') {
            source.stop();
            this.activeShots.delete(source);
        } }
    update(snapshot: Snapshot, localId: string, screen: string, paused: boolean) {
        this.playing = screen !== 'menu' && snapshot.status === 'playing';
        this.paused = paused;
        this.applyVolumes();
        this.ensureMusic();
        const local = snapshot.entities.find(e => e.id === localId);
        if (!this.defeatPlayed && !paused && screen !== 'menu' && (snapshot.status === 'playing' || snapshot.status === 'finished') && local && !local.withdrawn && (local.falling || !local.alive) && snapshot.winnerId !== localId) {
            this.defeatPlayed = true;
            this.celebrationUntil = (this.ctx?.currentTime || 0) + (this.buffers.get('lose')?.duration || 1.8);
            this.shot('lose', 'sfx', .9);
            this.applyVolumes();
        }
        const wanted = new Set<string>();
        if (this.playing && !paused && !this.hidden) {
            if (snapshot.wind.active) {
                wanted.add('wind');
                this.loop('wind', 'wind', 'sfx', .4);
            }
            for (const e of snapshot.entities.filter(e => e.alive && !e.airdrop && (e.effectRemaining.confusion || 0) > 0)) {
                const key = e.id + ':confusion';
                wanted.add(key);
                this.loop(key, 'confusion', 'sfx', e.id === localId ? .32 : .08);
            }
            const affected = snapshot.entities.filter(e => e.alive && !e.airdrop && (e.effects.speedUp > 0 || e.effects.speedDown > 0))
                .sort((a, b) => Number(b.id === localId) - Number(a.id === localId)).slice(0, 4);
            for (const e of affected) {
                const clip = e.effects.speedUp > 0 ? 'boost' : 'slow', key = e.id + ':' + clip;
                wanted.add(key);
                const speed = Math.hypot(e.vx, e.vz), level = (e.id === localId ? .23 : .07) * (.55 + .45 * Math.min(1, speed / 6));
                this.loop(key, clip, 'sfx', level);
            }
        }
        for (const key of this.loops.keys())
            if (key !== 'music' && !wanted.has(key))
                this.stopLoop(key);
    }
    private applyVolumes() {
        if (!this.ctx || !this.buses || !this.master)
            return;
        const t = this.ctx.currentTime;
        const ramp = (key: string, param: AudioParam, value: number) => {
            if (this.targets.get(key) === value)
                return;
            this.targets.set(key, value);
            const current = param.value;
            param.cancelScheduledValues(t);
            param.setValueAtTime(current, t);
            param.linearRampToValueAtTime(value, t + .06);
        };
        ramp('master', this.master.gain, this.hidden ? 0 : 1);
        ramp('ui', this.buses.ui.gain, .48);
        ramp('sfx', this.buses.sfx.gain, this.settings.sfx * (this.paused || this.settings.sfxMuted ? 0 : 1));
        const celebrating = t < this.celebrationUntil && !this.settings.sfxMuted && this.settings.sfx > 0;
        ramp('music', this.buses.music.gain, this.settings.music * (this.settings.musicMuted ? 0 : this.paused ? .45 : celebrating ? .2 : 1));
    }
    private shot(clip: Clip, bus: Bus, level: number, rate = 1) {
        if (this.hidden || !this.unlocked || (bus === 'sfx' && this.paused))
            return;
        const buffer = this.buffers.get(clip), c = this.ctx;
        if (!c || !buffer || !this.buses) {
            if (!this.decoding)
                return;
            this.pending.push({ clip, bus, level, rate, at: performance.now() });
            this.pending = this.pending.slice(-12);
            return;
        }
        // A busy collision/water frame must not suppress the round's outcome cue.
        if (this.activeShots.size >= 14 && clip !== 'lose' && clip !== 'win')
            return;
        const source = c.createBufferSource(), gain = c.createGain();
        source.buffer = buffer;
        source.playbackRate.value = rate;
        gain.gain.value = level;
        source.connect(gain).connect(this.buses[bus]);
        this.activeShots.set(source, { clip, bus });
        source.onended = () => { this.activeShots.delete(source); source.disconnect(); gain.disconnect(); };
        source.start();
    }
    private ensureMusic() { if (this.unlocked && !this.hidden && !this.settings.musicMuted && this.settings.music > 0)
        this.loop('music', 'music', 'music', .8);
    else
        this.stopLoop('music'); }
    private loop(key: string, clip: Clip, bus: Bus, level: number) {
        const c = this.ctx, existing = this.loops.get(key);
        if (existing) {
            if (Math.abs(existing.level - level) > .015) {
                existing.gain.gain.setTargetAtTime(level, c!.currentTime, .12);
                existing.level = level;
            }
            return;
        }
        const buffer = this.buffers.get(clip);
        if (!c || !buffer || !this.buses || !this.unlocked || this.hidden)
            return;
        const source = c.createBufferSource(), gain = c.createGain();
        source.buffer = buffer;
        source.loop = true;
        gain.gain.setValueAtTime(0, c.currentTime);
        gain.gain.linearRampToValueAtTime(level, c.currentTime + .16);
        source.connect(gain).connect(this.buses[bus]);
        source.onended = () => { source.disconnect(); gain.disconnect(); };
        const offset = key === 'music' ? this.musicOffset % buffer.duration : Math.random() * .2;
        source.start(0, offset);
        if (key === 'music')
            this.musicStarted = c.currentTime - offset;
        this.loops.set(key, { source, gain, level });
    }
    private stopLoop(key: string) {
        const loop = this.loops.get(key);
        if (!loop || !this.ctx)
            return;
        if (key === 'music')
            this.musicOffset = this.ctx.currentTime - this.musicStarted;
        const t = this.ctx.currentTime;
        loop.gain.gain.cancelScheduledValues(t);
        loop.gain.gain.setTargetAtTime(0, t, .025);
        loop.source.stop(t + .13);
        this.loops.delete(key);
    }
    private stopGameplay() { for (const key of this.loops.keys())
        if (key !== 'music')
            this.stopLoop(key); }
}
