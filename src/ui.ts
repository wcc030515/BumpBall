import type { AnimalKind, Appearance, EffectKind, Snapshot } from './simulation';
import { PRIMARY_COLORS } from './character-colors';
import { assetUrl } from './asset-url';
import { limitReason } from './interaction-rules';
import { INTERACTION_ICONS } from './interaction-icons';
export type { AnimalKind, Appearance, EffectKind } from './simulation';
export interface PlayerSelection {
    animal: AnimalKind;
    character: Appearance;
    ball: Appearance;
}
export interface UICallbacks {
    onAction: (action: string, payload?: any) => void;
    onSelectionChange?: (selection: PlayerSelection) => void;
    onUIClick?: (kind: 'click' | 'select' | 'confirm') => void;
}
export interface RoomState {
    code: string;
    role: 'host' | 'guest';
    connected: boolean;
    ready?: boolean;
    peerName?: string;
}
export interface CameraSettings {
    height: number;
    distance: number;
    fov: number;
    yaw: number;
}
export type CameraScope = 'match' | 'victory';
export type CameraSettingsSet = Record<CameraScope, CameraSettings>;
export const CAMERA_DEFAULTS: CameraSettingsSet = {
    match: { height: 15, distance: 15, fov: 40, yaw: -11.7 },
    victory: { height: 2, distance: 4, fov: 44.9, yaw: 36 },
};
const LABELS: Record<AnimalKind, string> = { cat: '小猫', dog: '小狗', rabbit: '小兔', raccoon: '小浣熊', panda: '熊猫', fox: '小狐狸', bear: '小熊', hamster: '仓鼠' };
const ANIMALS = Object.keys(LABELS) as AnimalKind[];
const EFFECTS: Array<{
    kind: EffectKind;
    label: string;
}> = [{ kind: 'grow', label: '变大' }, { kind: 'shrink', label: '变小' }, { kind: 'speedUp', label: '加速' }, { kind: 'speedDown', label: '减速' }, { kind: 'wind', label: '侧风' }, { kind: 'airdrop', label: '空降NPC' }, { kind: 'confusion', label: '方向混乱' }];
const SELECT_STORE = 'ball-island-web-profile-v2', COLOR_STORE = 'ball-island-primary-colors-v2';
const PRESET_COLORS = [['#e34c43', '红色'], ['#f4c647', '黄色'], ['#49b783', '绿色'], ['#438fe3', '蓝色'], ['#a06bdb', '紫色']] as const;
const clone = <T>(value: T): T => structuredClone(value);
const escape = (value: unknown) => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const validColor = (value: unknown): value is string => typeof value === 'string' && /^#[a-f\d]{6}$/i.test(value);
const soloIcon = '<svg viewBox="0 0 32 32" aria-hidden="true"><circle cx="16" cy="10" r="5"/><path d="M6 28v-3c0-6 4-9 10-9s10 3 10 9v3"/></svg>';
const onlineIcon = '<svg viewBox="0 0 36 32" aria-hidden="true"><circle cx="13" cy="9" r="4.5"/><path d="M4 28v-3c0-6 3.5-9 9-9s9 3 9 9v3M25 5a4.5 4.5 0 0 1 0 9M27 18c3.5 1 5 3.5 5 7v3"/></svg>';
const speakerIcon = (muted: boolean) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4V5ZM${muted ? '16 9l6 6M22 9l-6 6' : '15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14'}"/></svg>`;
const volumeRow = (bus: 'sfx' | 'music', label: string) => `<div class="sound-slider"><span><label for="sound-${bus}">${label}</label><output id="sound-${bus}-value"></output></span><div class="sound-track"><button type="button" class="sound-mute" data-action="mute" data-bus="${bus}" aria-label="静音${label}" title="静音${label}" aria-pressed="false">${speakerIcon(false)}</button><input id="sound-${bus}" type="range" min="0" max="100" step="1" value="${bus === 'sfx' ? 70 : 30}" data-volume="${bus}"></div></div>`;
export class UI {
    private readonly root: HTMLElement;
    private readonly callbacks: UICallbacks;
    private selection: PlayerSelection = { animal: 'rabbit', character: { colors: [PRIMARY_COLORS.rabbit] }, ball: { colors: ['#173e69', '#173e69', '#173e69'] } };
    private primaryColors: Record<AnimalKind, string> = { ...PRIMARY_COLORS };
    private originalPaint = new Set<AnimalKind>(ANIMALS);
    private roomOpen = false;
    private soundOpen = false;
    private room: RoomState | null = null;
    private mode: 'solo' | 'pk' = 'solo';
    private screen: 'menu' | 'playing' | 'finished' = 'menu';
    private snapshot: Snapshot | null = null;
    private localId = 'player';
    private paused = false;
    private winnerVisible = false;
    private spectator = false;
    constructor(callbacks: UICallbacks) {
        this.callbacks = callbacks;
        this.restore();
        this.root = document.createElement('div');
        this.root.id = 'game-ui';
        this.root.innerHTML = `
      <h1 class="menu-title">海岛碰碰球</h1>
      <section class="character-panel" aria-label="选择角色和主色">
        <h2 id="selected-animal-name"></h2>
        <div class="character-color-row" role="group" aria-label="角色主色"><button type="button" class="paint-original" data-paint="original" aria-label="恢复角色原色" title="原色">原色</button>${PRESET_COLORS.map(([hex, name]) => `<button type="button" class="paint-swatch" data-paint="${hex}" style="--paint:${hex}" aria-label="${name}主色" title="${name}" aria-pressed="false"></button>`).join('')}<label class="paint-custom" title="自选颜色"><input type="color" id="primary-color" aria-label="自定义角色主色" value="${this.selection.character.colors[0]}"><span aria-hidden="true">✎</span></label></div>
        <div class="animal-picker" role="group" aria-label="选择角色">${ANIMALS.map(kind => `<button type="button" class="animal-choice" data-animal="${kind}" aria-label="${LABELS[kind]}" title="${LABELS[kind]}" aria-pressed="false"><img src="${assetUrl(`portraits/${kind}.webp?rev=new-animals-20261106`)}" alt="${LABELS[kind]}" draggable="false"><span class="choice-check" aria-hidden="true">✓</span></button>`).join('')}</div>
      </section>
      <section class="menu-panel" aria-label="游戏开始菜单"><div class="mode-actions"><button type="button" class="primary mode-button" data-action="start">${soloIcon}<span>单人游戏</span><span class="mode-chevron" aria-hidden="true">›</span></button><button type="button" class="mode-button" data-action="room">${onlineIcon}<span>联机游玩</span><span class="mode-chevron" aria-hidden="true">›</span></button></div></section>
      <section class="match-hud" aria-label="比赛时间"><span>持续时间</span><strong id="game-timer">00:00</strong></section>
      <nav class="top-controls" aria-label="游戏控制"><button type="button" class="sound-toggle" data-action="sound" aria-label="声音设置" aria-expanded="false" aria-controls="sound-panel" title="声音设置"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4V5ZM15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14"/></svg></button><button type="button" data-action="pause">暂停</button></nav>
      <section id="sound-panel" class="sound-panel" hidden aria-label="声音设置"><div class="panel-heading"><h2>声音设置</h2><button type="button" class="close-button" data-action="closeSound" aria-label="关闭声音设置">×</button></div>${volumeRow('sfx', '游戏音效')}${volumeRow('music', '背景音乐')}</section>
      <section class="effect-controls" aria-label="互动模拟">${EFFECTS.map(effect => `<button type="button" class="effect-button" data-effect="${effect.kind}" aria-label="${effect.label}">${INTERACTION_ICONS[effect.kind]}<span class="effect-label">${effect.label}</span><small hidden></small></button>`).join('')}</section>
      <p class="match-help" hidden>控制方向将对手撞出小岛，最后留下的玩家获胜<br><span>WASD / 方向键移动 · 1–7 互动 · Esc 暂停</span></p>
      <div class="countdown" hidden aria-live="assertive"><span id="countdown-number">3</span></div>
      <section class="pause-overlay" hidden aria-label="游戏暂停"><div class="bottom-actions pause-actions"><button type="button" class="mint" data-action="resume">继续游戏</button><button type="button" data-action="restart">重新开始</button><button type="button" data-action="menu">返回开始界面</button></div></section>
      <section class="result-overlay" hidden aria-label="比赛结果"><div class="bottom-actions result-actions"><button type="button" class="primary" data-action="restart">再来一局</button><button type="button" data-action="menu">返回开始界面</button></div></section>
      <section class="spectator-panel" hidden aria-label="观战"><p>你已被淘汰 · 正在观战</p><div class="spectator-actions"><button type="button" class="primary" data-action="restart">再来一局</button><button type="button" data-action="menu">返回开始界面</button></div></section>
      <div class="room-backdrop" hidden><section class="room-panel" aria-label="联机房间"><div class="panel-heading"><h2>联机游玩</h2><button type="button" class="close-button" data-action="closeRoom" aria-label="关闭联机房间">×</button></div><div id="room-content"></div></section></div>
      <div class="toast-stack" aria-live="polite" aria-atomic="false"></div>
      <div class="touch-controls" aria-label="触屏方向控制"><button type="button" data-touch="up" aria-label="向上">↑</button><button type="button" data-touch="left" aria-label="向左">←</button><button type="button" data-touch="down" aria-label="向下">↓</button><button type="button" data-touch="right" aria-label="向右">→</button></div>`;
        (document.querySelector('#ui') || document.body).appendChild(this.root);
        this.bindEvents();
        this.updateSelection(false);
        this.renderRoom();
        this.refresh();
    }
    get cameraSettings(): CameraSettingsSet { return clone(CAMERA_DEFAULTS); }
    getSelection(): PlayerSelection { return clone(this.selection); }
    getInteractionBlocked(): boolean { return this.roomOpen || this.soundOpen || !!document.activeElement?.matches('input,textarea,select'); }
    setAudioSettings(settings: {
        sfx: number;
        music: number;
        sfxMuted?: boolean;
        musicMuted?: boolean;
    }) { for (const bus of ['sfx', 'music'] as const) {
        const value = Math.round(settings[bus] * 100), muted = !!settings[`${bus}Muted`], name = bus === 'sfx' ? '游戏音效' : '背景音乐';
        this.query<HTMLInputElement>('#sound-' + bus).value = String(value);
        this.query('#sound-' + bus + '-value').textContent = value + '%';
        const button = this.query<HTMLButtonElement>(`[data-bus="${bus}"]`);
        button.setAttribute('aria-pressed', String(muted));
        button.setAttribute('aria-label', (muted ? '取消静音' : '静音') + name);
        button.title = (muted ? '取消静音' : '静音') + name;
        button.innerHTML = speakerIcon(muted);
        button.classList.toggle('muted', muted);
    } }
    closeSound(): boolean { if (!this.soundOpen)
        return false; this.soundOpen = false; this.refresh(); this.query<HTMLButtonElement>('[data-action="sound"]').focus(); return true; }
    setMode(mode: 'solo' | 'pk') { this.mode = mode; this.refresh(); }
    setScreen(screen: 'menu' | 'playing' | 'finished') {
        if (screen !== this.screen) {
            this.winnerVisible = false;
            this.soundOpen = false;
        }
        this.screen = screen;
        if (screen !== 'menu')
            this.roomOpen = false;
        if (screen === 'menu') {
            this.paused = false;
            this.spectator = false;
        }
        this.refresh();
    }
    setPaused(value: boolean) { this.paused = value; this.refresh(); }
    setWinnerVisible(value: boolean) { this.winnerVisible = value; this.refresh(); }
    showResult(_name: string, _won: boolean) { this.setScreen('finished'); this.setWinnerVisible(true); }
    setRoom(room: RoomState | null) { this.room = room ? { ...room } : null; if (room) {
        this.mode = 'pk';
        if (this.screen === 'menu')
            this.roomOpen = true;
    } this.renderRoom(); this.refresh(); }
    update(snapshot: Snapshot, localId: string) {
        this.snapshot = snapshot;
        this.localId = localId;
        const own = snapshot.entities.find(e => e.id === localId);
        this.spectator = this.screen !== 'menu' && snapshot.status === 'playing' && !!own && !own.alive;
        const seconds = Math.max(0, Math.floor(snapshot.elapsedSeconds || 0));
        this.query('#game-timer').textContent = `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
        this.query('.countdown').hidden = this.screen === 'menu' || snapshot.status !== 'countdown';
        const count = String(Math.max(1, Math.ceil(snapshot.countdownRemaining || 0))), number = this.query('#countdown-number');
        if (number.textContent !== count) {
            number.textContent = count;
            number.classList.remove('tick');
            void number.offsetWidth;
            number.classList.add('tick');
        }
        for (const effect of EFFECTS) {
            const button = this.query<HTMLButtonElement>(`[data-effect="${effect.kind}"]`), blocked = limitReason(effect.kind, own, snapshot);
            button.disabled = this.paused || this.spectator || snapshot.status !== 'playing' || !!blocked;
            button.classList.toggle('at-limit', !!blocked);
            const label = blocked || effect.label;
            button.querySelector('.effect-label')!.textContent = label;
            button.setAttribute('aria-label', label);
            button.title = blocked || effect.label;
            const readout = button.querySelector<HTMLElement>('small')!;
            if (effect.kind === 'wind') {
                const remaining = Number(own?.effectRemaining.wind || 0), queued = snapshot.wind.queued || 0;
                readout.hidden = remaining <= 0 && queued === 0;
                readout.textContent = `${Math.ceil(remaining)}s${queued ? ` +${queued}` : ''}`;
                button.classList.toggle('active', remaining > 0);
            }
            else if (effect.kind === 'airdrop') {
                readout.hidden = false;
                readout.textContent = '随机属性';
                button.classList.remove('active');
            }
            else if (effect.kind === 'confusion') {
                const remaining = Number(own?.effectRemaining.confusion || 0);
                readout.hidden = remaining <= 0;
                readout.textContent = Math.ceil(remaining) + 's';
                button.classList.toggle('active', remaining > 0);
            }
            else {
                const size = effect.kind === 'grow' || effect.kind === 'shrink', value = size ? own?.scale : own?.actualSpeedFactor;
                readout.hidden = value === undefined;
                readout.textContent = '×' + (value || 1).toFixed(2);
                button.classList.toggle('active', (own?.effects[effect.kind] || 0) > 0);
            }
        }
        this.refresh();
    }
    reward(_amount = 10) { }
    toast(message: string) { const toast = document.createElement('div'); toast.className = 'ui-toast'; toast.textContent = message; const stack = this.query('.toast-stack'); stack.appendChild(toast); while (stack.children.length > 3)
        stack.firstElementChild?.remove(); window.setTimeout(() => toast.remove(), 3400); }
    dispose() { this.root.remove(); }
    private query<T extends HTMLElement = HTMLElement>(selector: string): T { return this.root.querySelector<T>(selector)!; }
    private refresh() {
        const menu = this.screen === 'menu', result = this.screen === 'finished' && this.winnerVisible, guest = this.mode === 'pk' && this.room?.role === 'guest';
        this.root.dataset.screen = this.screen;
        this.root.dataset.paused = String(this.paused);
        this.root.dataset.spectator = String(this.spectator);
        this.query('.menu-title').hidden = !menu;
        this.query('.menu-panel').hidden = !menu;
        this.query('.character-panel').hidden = !menu || this.roomOpen;
        if (menu)
            this.query('.countdown').hidden = true;
        this.query('.match-hud').hidden = menu;
        this.query('.effect-controls').hidden = menu || this.screen === 'finished' || this.paused || this.spectator;
        this.query('.match-help').hidden = menu || this.screen === 'finished' || this.paused || this.spectator || this.snapshot?.status !== 'playing' || (this.snapshot?.elapsedSeconds || 0) > 8;
        this.query('.pause-overlay').hidden = !this.paused || menu || this.spectator || this.screen === 'finished';
        this.query('.spectator-panel').hidden = !this.spectator || this.paused;
        this.query('.result-overlay').hidden = !result;
        this.query('.room-backdrop').hidden = !this.roomOpen;
        this.query('.sound-panel').hidden = !this.soundOpen;
        this.query('[data-action="sound"]').setAttribute('aria-expanded', String(this.soundOpen));
        const focused = document.activeElement as HTMLElement | null;
        if (focused && this.root.contains(focused) && focused.closest('[hidden]'))
            focused.blur();
        this.query('.touch-controls').hidden = menu || this.paused || this.spectator || this.screen === 'finished';
        const pause = this.query<HTMLButtonElement>('[data-action="pause"]');
        pause.hidden = menu || this.screen === 'finished';
        pause.disabled = this.spectator || guest;
        pause.textContent = this.paused ? '继续' : '暂停';
        pause.title = this.spectator ? '观战时无法暂停' : guest ? '由房主控制暂停' : '';
        this.root.querySelectorAll<HTMLButtonElement>('[data-action="restart"]').forEach(b => { b.disabled = guest; b.title = guest ? '等待房主开始下一局' : ''; });
    }
    private bindEvents() {
        this.root.addEventListener('click', event => {
            const button = (event.target as HTMLElement).closest<HTMLButtonElement>('button');
            if (!button || button.disabled)
                return;
            if (!button.dataset.touch && !button.dataset.paint && !button.dataset.effect)
                this.callbacks.onUIClick?.(button.dataset.animal ? 'select' : ['start', 'startRoom', 'restart', 'createRoom', 'joinRoom'].includes(button.dataset.action || '') ? 'confirm' : 'click');
            const paint = button.dataset.paint;
            if (paint) {
                this.choosePrimary(paint === 'original' ? null : paint);
                return;
            }
            const animal = button.dataset.animal as AnimalKind | undefined;
            if (animal && ANIMALS.includes(animal)) {
                this.selection.animal = animal;
                this.selection.character.colors = [this.primaryColors[animal]];
                this.persistSelection();
                this.updateSelection();
                return;
            }
            const effect = button.dataset.effect as EffectKind | undefined;
            if (effect) {
                this.callbacks.onAction('effect', { kind: effect, targetId: this.localId });
                button.classList.remove('triggered');
                void button.offsetWidth;
                button.classList.add('triggered');
                return;
            }
            const action = button.dataset.action;
            if (!action)
                return;
            switch (action) {
                case 'mute':
                    this.callbacks.onAction('mute', { bus: button.dataset.bus });
                    return;
                case 'sound':
                    this.soundOpen = !this.soundOpen;
                    this.refresh();
                    this.callbacks.onAction('modal');
                    return;
                case 'closeSound':
                    this.closeSound();
                    return;
                case 'resetPrimary':
                    this.choosePrimary(null);
                    return;
                case 'room':
                    this.roomOpen = true;
                    this.renderRoom();
                    this.refresh();
                    return;
                case 'closeRoom':
                    this.roomOpen = false;
                    this.refresh();
                    return;
                case 'start':
                    this.callbacks.onAction('start', { mode: 'solo', selection: this.getSelection() });
                    return;
                case 'joinRoom': {
                    const code = this.query<HTMLInputElement>('#room-code').value.trim().toUpperCase();
                    if (!/^[A-Z0-9]{6}$/.test(code)) {
                        this.toast('请输入6位房间码');
                        return;
                    }
                    this.callbacks.onAction('joinRoom', { code });
                    return;
                }
                case 'copyRoom':
                    if (this.room)
                        void navigator.clipboard?.writeText(this.room.code).then(() => this.toast('房间码已复制')).catch(() => this.toast(`房间码：${this.room?.code}`));
                    return;
                case 'menu':
                case 'restart':
                    this.roomOpen = false;
                    break;
            }
            this.callbacks.onAction(action);
        });
        this.root.addEventListener('input', event => { const input = event.target as HTMLInputElement; if (input.dataset.volume) {
            const bus = input.dataset.volume;
            this.query('#sound-' + bus + '-value').textContent = input.value + '%';
            this.callbacks.onAction('volume', { bus, value: Number(input.value) / 100 });
            return;
        } if (input.id === 'room-code')
            input.value = input.value.replace(/[^a-z0-9]/gi, '').toUpperCase(); if (input.id === 'primary-color' && validColor(input.value))
            this.choosePrimary(input.value); });
        document.addEventListener('pointerdown', event => { if (this.soundOpen && !(event.target as HTMLElement).closest('.sound-panel,[data-action="sound"]')) {
            this.soundOpen = false;
            this.refresh();
        } });
        this.query('.room-backdrop').addEventListener('click', e => { if (e.target === e.currentTarget) {
            this.roomOpen = false;
            this.refresh();
        } });
        this.root.addEventListener('keydown', e => { if (e.key === 'Escape' && this.soundOpen) {
            e.preventDefault();
            e.stopPropagation();
            this.closeSound();
            return;
        } if (e.key === 'Escape' && this.roomOpen) {
            e.preventDefault();
            e.stopPropagation();
            this.roomOpen = false;
            this.refresh();
        } if ((e.target as HTMLElement).matches('input,textarea,select') && !['Escape', 'Tab'].includes(e.key))
            e.stopPropagation(); });
        this.root.querySelectorAll<HTMLButtonElement>('[data-touch]').forEach(b => { const emit = (pressed: boolean) => this.callbacks.onAction('touch', { direction: b.dataset.touch, pressed }); b.addEventListener('pointerdown', e => { e.preventDefault(); b.setPointerCapture(e.pointerId); emit(true); }); b.addEventListener('pointerup', () => emit(false)); b.addEventListener('pointercancel', () => emit(false)); b.addEventListener('lostpointercapture', () => emit(false)); });
    }
    private updateSelection(notify = true) {
        this.root.querySelectorAll<HTMLButtonElement>('[data-animal]').forEach(b => { const selected = b.dataset.animal === this.selection.animal; b.classList.toggle('selected', selected); b.setAttribute('aria-pressed', String(selected)); });
        this.query('#selected-animal-name').textContent = LABELS[this.selection.animal];
        this.query<HTMLInputElement>('#primary-color').value = this.primaryColors[this.selection.animal];
        const original = this.originalPaint.has(this.selection.animal), color = this.primaryColors[this.selection.animal];
        this.root.querySelectorAll<HTMLButtonElement>('[data-paint]').forEach(button => { const selected = button.dataset.paint === 'original' ? original : !original && button.dataset.paint === color; button.classList.toggle('selected', selected); button.setAttribute('aria-pressed', String(selected)); });
        this.query('.paint-custom').classList.toggle('selected', !original && !PRESET_COLORS.some(([hex]) => hex === color));
        if (notify)
            this.callbacks.onSelectionChange?.(this.getSelection());
    }
    private choosePrimary(color: string | null) { if (color !== null && !validColor(color))
        return; const animal = this.selection.animal; if (color === null)
        this.originalPaint.add(animal);
    else
        this.originalPaint.delete(animal); this.primaryColors[animal] = color?.toLowerCase() ?? PRIMARY_COLORS[animal]; this.selection.character.colors = [this.primaryColors[animal]]; this.persistSelection(); this.updateSelection(); }
    private persistSelection() { try {
        localStorage.setItem(SELECT_STORE, JSON.stringify({ animal: this.selection.animal }));
        localStorage.setItem(COLOR_STORE, JSON.stringify(Object.fromEntries(ANIMALS.map(a => [a, this.originalPaint.has(a) ? null : this.primaryColors[a]]))));
    }
    catch { } }
    private restore() { try {
        const saved = JSON.parse(localStorage.getItem(SELECT_STORE) || 'null'), old = JSON.parse(localStorage.getItem('ball-island-wardrobe-v1') || 'null'), id = saved?.animal ?? old?.selection?.animal, animal = id === 'pig' ? 'hamster' : id;
        if (ANIMALS.includes(animal))
            this.selection.animal = animal;
        const current = JSON.parse(localStorage.getItem(COLOR_STORE) || 'null'), colors = current ?? JSON.parse(localStorage.getItem('ball-island-primary-colors-v1') || 'null');
        for (const animal of ANIMALS)
            if (validColor(colors?.[animal])) {
                this.primaryColors[animal] = colors[animal].toLowerCase();
                if (current || this.primaryColors[animal] !== PRIMARY_COLORS[animal])
                    this.originalPaint.delete(animal);
            }
    }
    catch { } this.selection.character.colors = [this.primaryColors[this.selection.animal]]; }
    private renderRoom() {
        const content = this.query('#room-content'), room = this.room;
        if (!room) {
            content.innerHTML = '<button type="button" class="primary room-create" data-action="createRoom">创建房间</button><p class="room-divider">或加入房间</p><form class="join-room"><input id="room-code" aria-label="6位房间码" placeholder="输入6位房间码" maxlength="6" autocomplete="off" autocapitalize="characters" spellcheck="false"><button type="button" data-action="joinRoom">加入</button></form>';
            content.querySelector('form')?.addEventListener('submit', e => { e.preventDefault(); content.querySelector<HTMLButtonElement>('[data-action="joinRoom"]')!.click(); });
            return;
        }
        const ready = room.ready ?? room.connected;
        content.innerHTML = `<div class="room-code-display"><span>房间码</span><strong>${escape(room.code)}</strong><button type="button" class="text-button" data-action="copyRoom">复制房间码</button></div><p class="room-status">${ready ? '双方已就绪' : '等待另一位玩家加入'}</p>${room.role === 'host' ? `<button type="button" class="primary room-start" data-action="startRoom" ${ready ? '' : 'disabled'}>开始比赛</button>` : '<p class="room-waiting">等待房主开始比赛</p>'}<button type="button" class="text-button leave-room" data-action="leaveRoom">离开房间</button>`;
    }
}
