import { GameSimulation, type Snapshot, type PlayerConfig, type EffectKind } from './simulation';
import { GameRenderer, type CameraScope } from './render/game-renderer';
import { UI } from './ui';
import { RoomConnection, type RoomMessage } from './network';
import { GameAudio } from './audio';
import './style.css';
import './menu.css';
import './interactions.css';
import './audio.css';
type Screen = 'menu' | 'playing' | 'finished';
const boot = document.querySelector<HTMLDivElement>('#boot')!;
async function bootstrap() {
    const canvas = document.querySelector<HTMLCanvasElement>('#game')!;
    const [renderer, sim] = await Promise.all([GameRenderer.create(canvas), GameSimulation.create()]);
    const connection = new RoomConnection(), audio = new GameAudio();
    const keys = new Set<string>(), touchKeys = new Set<string>(), touch = { x: 0, y: 0 };
    const offline = !!(window as any).__BALL_ISLAND_STANDALONE__?.offline;
    let screen: Screen = 'menu', mode: 'solo' | 'pk' = 'solo', localId = 'player';
    let snapshot = sim.snapshot(), paused = false, elapsed = 0, resultVisible = false;
    let netTimer = 0, uiTimer = 0, lastCountdown = 0, previewDrag: number | null = null, dragX = 0, guestInputAt = 0;
    let cameraScope: CameraScope | null = null, lastFrame = performance.now();
    const playedImpacts = new Set<string>(), fallen = new Set<string>();
    const ui = new UI({ onAction: (action, payload) => { void handleAction(action, payload); }, onUIClick: kind => audio.ui(kind) });
    ui.setAudioSettings(audio.getSettings());
    addEventListener('pointerdown', () => audio.unlock(), { once: true, capture: true });
    addEventListener('keydown', () => audio.unlock(), { once: true, capture: true });
    for (const scope of ['match', 'victory'] as const)
        renderer.setCameraSettings(scope, ui.cameraSettings[scope]);
    const selectionConfig = (id = localId, name = '你'): PlayerConfig => ({ ...ui.getSelection(), id, name, human: true });
    const entity = () => snapshot.entities.find(e => e.id === localId);
    const resetInput = () => {
        keys.clear();
        touchKeys.clear();
        touch.x = touch.y = 0;
        if (screen !== 'menu')
            sim.setInput(localId, 0, 0);
        if (mode === 'pk' && connection.role === 'guest')
            connection.send({ type: 'input', x: 0, z: 0 });
    };
    function setPaused(value: boolean, broadcast = false) {
        if (screen === 'menu' || snapshot.status === 'finished')
            return;
        if (broadcast && value && (connection.role === 'guest' || !entity()?.alive))
            return;
        paused = value;
        sim.setPaused(value);
        resetInput();
        ui.setPaused(value);
        if (broadcast && mode === 'pk')
            connection.send({ type: 'pause', paused: value });
    }
    function beginRound() {
        audio.resetRound();
        screen = 'playing';
        snapshot = sim.snapshot();
        paused = false;
        resultVisible = false;
        cameraScope = null;
        playedImpacts.clear();
        fallen.clear();
        lastCountdown = 0;
        resetInput();
        renderer.setCameraPreview(null);
        ui.setScreen('playing');
        ui.setMode(mode);
        ui.setPaused(false);
        ui.setWinnerVisible(false);
        ui.update(snapshot, localId);
        audio.unlock();
    }
    function startSolo() {
        connection.close();
        ui.setRoom(null);
        mode = 'solo';
        localId = 'player';
        sim.start([selectionConfig('player', '你')], 5);
        beginRound();
    }
    function startRoom() {
        if (connection.role !== 'host' || !connection.hostConfig || !connection.guestConfig) {
            ui.toast('等待另一位玩家加入');
            return;
        }
        const players = [connection.hostConfig, connection.guestConfig];
        mode = 'pk';
        localId = 'host';
        sim.start(players, 4);
        beginRound();
        connection.send({ type: 'start', players });
        connection.send({ type: 'state', snapshot });
    }
    function showMenu() {
        audio.resetRound();
        connection.close();
        sim.clear();
        snapshot = sim.snapshot();
        mode = 'solo';
        screen = 'menu';
        localId = 'player';
        paused = false;
        cameraScope = null;
        resetInput();
        renderer.setCameraPreview(null);
        ui.setPaused(false);
        ui.setMode('solo');
        ui.setRoom(null);
        ui.setScreen('menu');
        ui.setWinnerVisible(false);
    }
    async function connectRoom(code?: string) {
        if (offline) {
            ui.toast('联机请使用“启动HTML版”打开完整版');
            return;
        }
        connection.close();
        try {
            await connection.connect();
            mode = 'pk';
            ui.setMode('pk');
            if (code)
                connection.join(code, selectionConfig('guest', '玩家二'));
            else
                connection.create(selectionConfig('host', '玩家一'));
        }
        catch (error) {
            ui.toast((error as Error).message);
            ui.setRoom(null);
        }
    }
    function roomUI() {
        if (!connection.role)
            return;
        ui.setRoom({ code: connection.code, role: connection.role, connected: true, ready: !!connection.guestConfig, peerName: connection.role === 'host' ? connection.guestConfig?.name : connection.hostConfig?.name });
    }
    function triggerEffect(kind: EffectKind, targetId = localId, actor = localId) {
        if (paused || screen !== 'playing' || snapshot.status !== 'playing')
            return;
        if (mode === 'pk' && connection.role === 'guest') {
            connection.send({ type: 'effect', targetId, kind });
            return;
        }
        const result = sim.applyEffect(targetId, kind);
        if (!result.ok)
            ui.toast(result.message);
        if (result.ok) {
            audio.effect(kind);
            if (kind === 'airdrop')
                ui.toast(result.message);
        }
        if (mode === 'pk')
            connection.send({ type: 'effect-result', ...result, targetId, kind, actor });
        snapshot = sim.snapshot();
        ui.update(snapshot, localId);
    }
    connection.onMessage = (message: RoomMessage) => {
        switch (message.type) {
            case 'room':
                localId = message.role;
                roomUI();
                break;
            case 'peer-joined':
                roomUI();
                ui.toast('另一位玩家已就绪');
                break;
            case 'start':
                if (connection.role === 'guest') {
                    mode = 'pk';
                    localId = 'guest';
                    beginRound();
                }
                break;
            case 'state':
                if (connection.role === 'guest')
                    snapshot = message.snapshot;
                break;
            case 'input':
                if (connection.role === 'host') {
                    guestInputAt = performance.now();
                    sim.setInput('guest', message.x, message.z);
                }
                break;
            case 'effect':
                if (connection.role === 'host')
                    triggerEffect(message.kind, message.targetId, 'guest');
                break;
            case 'effect-result':
                if (!message.ok)
                    ui.toast(message.message);
                else
                    audio.effect(message.kind);
                break;
            case 'pause':
                setPaused(message.paused);
                break;
            case 'peer-left':
                showMenu();
                ui.toast(message.message);
                break;
            case 'error':
                ui.toast(message.message);
                break;
        }
    };
    async function handleAction(action: string, payload?: any) {
        audio.unlock();
        switch (action) {
            case 'start':
                if (payload?.mode === 'pk')
                    await connectRoom();
                else
                    startSolo();
                break;
            case 'effect':
                triggerEffect(payload.kind, payload.targetId || localId);
                break;
            case 'restart':
                if (mode === 'pk') {
                    if (connection.role === 'host')
                        startRoom();
                    else
                        ui.toast('等待房主开始下一局');
                }
                else
                    startSolo();
                break;
            case 'pause':
                setPaused(!paused, true);
                break;
            case 'resume':
                setPaused(false, true);
                break;
            case 'menu':
            case 'leaveRoom':
                showMenu();
                break;
            case 'createRoom':
                await connectRoom();
                break;
            case 'joinRoom':
                await connectRoom(payload.code);
                break;
            case 'startRoom':
                startRoom();
                break;
            case 'touch':
                if (payload.pressed)
                    touchKeys.add(payload.direction);
                else
                    touchKeys.delete(payload.direction);
                touch.x = Number(touchKeys.has('right')) - Number(touchKeys.has('left'));
                touch.y = Number(touchKeys.has('down')) - Number(touchKeys.has('up'));
                break;
            case 'modal':
                resetInput();
                break;
            case 'volume':
                if (payload?.bus === 'sfx' || payload?.bus === 'music') {
                    audio.setVolume(payload.bus, payload.value);
                    ui.setAudioSettings(audio.getSettings());
                }
                break;
            case 'mute':
                if (payload?.bus === 'sfx' || payload?.bus === 'music') {
                    audio.toggleMute(payload.bus);
                    ui.setAudioSettings(audio.getSettings());
                }
                break;
            case 'copyInvite': {
                const url = new URL(location.href);
                url.search = '';
                url.searchParams.set('room', connection.code);
                try {
                    await navigator.clipboard.writeText(url.href);
                    ui.toast('邀请链接已复制');
                }
                catch {
                    ui.toast(`房间码：${connection.code}`);
                }
                break;
            }
        }
    }
    function inputVector() {
        let x = touch.x, y = touch.y;
        if (keys.has('KeyA') || keys.has('ArrowLeft'))
            x--;
        if (keys.has('KeyD') || keys.has('ArrowRight'))
            x++;
        if (keys.has('KeyW') || keys.has('ArrowUp'))
            y--;
        if (keys.has('KeyS') || keys.has('ArrowDown'))
            y++;
        const length = Math.hypot(x, y);
        if (length > 1) {
            x /= length;
            y /= length;
        }
        return renderer.inputToWorld(x, y, entity());
    }
    addEventListener('keydown', event => {
        if (event.code === 'Escape' && ui.closeSound()) {
            event.preventDefault();
            audio.ui();
            return;
        }
        if ((event.target as HTMLElement)?.closest('input,textarea,select'))
            return;
        if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space'].includes(event.code))
            event.preventDefault();
        if (!event.repeat && (event.code === 'Escape' || event.code === 'KeyP')) {
            if (screen !== 'menu') {
                audio.ui();
                setPaused(!paused, true);
            }
            return;
        }
        if (ui.getInteractionBlocked())
            return;
        keys.add(event.code);
        if (!event.repeat && screen === 'playing' && !paused && snapshot.status === 'playing') {
            const kind = ({ Digit1: 'grow', Digit2: 'shrink', Digit3: 'speedUp', Digit4: 'speedDown', Digit5: 'wind', Digit6: 'airdrop', Digit7: 'confusion' } as Record<string, EffectKind>)[event.code];
            if (kind)
                triggerEffect(kind);
            if ((event.code === 'KeyN' || event.code === 'KeyM') && connection.role !== 'guest') {
                const result = event.code === 'KeyN' ? sim.addNPC() : sim.removeNPC();
                if (!result.ok)
                    ui.toast(result.message);
            }
        }
    });
    addEventListener('keyup', event => keys.delete(event.code));
    addEventListener('blur', resetInput);
    document.addEventListener('visibilitychange', () => {
        resetInput();
        // A hidden host is throttled by browsers. Freeze both peers together rather
        // than letting one screen look live while the authoritative match stalls.
        if (document.hidden && mode === 'pk' && connection.role === 'host' && screen === 'playing' && snapshot.status !== 'finished') {
            setPaused(true);
            connection.send({ type: 'pause', paused: true });
        }
    });
    // Only the character half of the menu rotates. Keep the normal pointer cursor.
    addEventListener('pointerdown', event => {
        if (screen !== 'menu' || event.button !== 0 || event.clientX > innerWidth * .54 || (event.target as HTMLElement)?.closest('.menu-panel,.character-panel,.top-controls,.room-panel,.toast-stack,button,input'))
            return;
        previewDrag = event.pointerId;
        dragX = event.clientX;
    });
    addEventListener('pointermove', event => {
        if (previewDrag !== event.pointerId || screen !== 'menu')
            return;
        renderer.rotatePreview((event.clientX - dragX) * .009);
        dragX = event.clientX;
    });
    const endDrag = () => { previewDrag = null; };
    addEventListener('pointerup', endDrag);
    addEventListener('pointercancel', endDrag);
    addEventListener('resize', () => renderer.resize());
    addEventListener('ball-renderer-context', ((event: CustomEvent) => {
        if (event.detail.lost) {
            setPaused(true, true);
            ui.toast('画面正在恢复');
        }
        else {
            renderer.resize();
            ui.toast('画面已恢复，可继续游戏');
        }
    }) as EventListener);
    ui.setScreen('menu');
    boot.remove();
    const invitation = new URL(location.href).searchParams.get('room');
    if (invitation && /^[A-Z0-9]{6}$/i.test(invitation))
        await connectRoom(invitation);
    function frame(now: number) {
        const dt = Math.min(.05, Math.max(0, (now - lastFrame) / 1000));
        lastFrame = now;
        if (!paused)
            elapsed += dt;
        netTimer += dt;
        uiTimer += dt;
        if (screen !== 'menu') {
            const input = paused || ui.getInteractionBlocked() || cameraScope ? { x: 0, z: 0 } : inputVector();
            if (mode === 'pk' && connection.role === 'guest') {
                if (netTimer >= 1 / 30) {
                    connection.send({ type: 'input', ...input });
                    netTimer = 0;
                }
            }
            else {
                if (mode === 'pk' && now - guestInputAt > 500)
                    sim.setInput('guest', 0, 0);
                sim.setInput(localId, input.x, input.z);
                if (!paused)
                    sim.step(dt);
                snapshot = sim.snapshot();
                if (mode === 'pk' && netTimer >= 1 / 15) {
                    connection.send({ type: 'state', snapshot });
                    netTimer = 0;
                }
            }
            const countdown = snapshot.status === 'countdown' ? Math.ceil(snapshot.countdownRemaining) : 0;
            if (countdown && countdown !== lastCountdown)
                audio.countdown();
            lastCountdown = countdown;
            if (snapshot.status === 'playing' || snapshot.status === 'finished') {
                for (const impact of snapshot.impacts) {
                    const key = `${impact.a}:${impact.b}:${impact.at}`;
                    if (!playedImpacts.has(key)) {
                        playedImpacts.add(key);
                        audio.bump(impact.closingSpeed, impact.enhanced);
                    }
                }
            }
            for (const e of snapshot.entities)
                if (e.waterEntry && !e.withdrawn && !fallen.has(e.id)) {
                    fallen.add(e.id);
                    audio.splash();
                }
            if (snapshot.status === 'finished')
                screen = 'finished';
        }
        audio.update(snapshot, localId, screen, paused);
        renderer.update(snapshot, localId, { screen, paused, dt, elapsed, selected: selectionConfig(), cameraScope, interpolate: mode === 'pk' && connection.role === 'guest' });
        renderer.render();
        if (screen !== 'menu' && uiTimer >= .06) {
            ui.update(snapshot, localId);
            uiTimer = 0;
        }
        if (screen === 'finished' && !resultVisible && renderer.isFocusDone()) {
            resultVisible = true;
            ui.setScreen('finished');
            const winner = snapshot.entities.find(e => e.id === snapshot.winnerId);
            ui.showResult(winner?.name || '玩家', snapshot.winnerId === localId);
            ui.setWinnerVisible(true);
            if (snapshot.winnerId === localId)
                audio.win();
        }
        requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
}
bootstrap().catch(error => {
    console.error(error);
    boot.innerHTML = '<strong>游戏暂时无法加载</strong><span>请使用 Chrome 或 Edge，并开启硬件加速。</span><button onclick="location.reload()">重新加载</button>';
});
