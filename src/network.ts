import type { EffectKind, PlayerConfig, Snapshot } from './simulation';
export type RoomRole = 'host' | 'guest';
export type RoomMessage = {
    type: 'room';
    code: string;
    role: RoomRole;
    hostConfig: PlayerConfig;
    guestConfig?: PlayerConfig;
} | {
    type: 'peer-joined';
    config: PlayerConfig;
} | {
    type: 'peer-left';
    message: string;
} | {
    type: 'start';
    players: PlayerConfig[];
} | {
    type: 'state';
    snapshot: Snapshot;
} | {
    type: 'input';
    x: number;
    z: number;
} | {
    type: 'effect';
    targetId: string;
    kind: EffectKind;
} | {
    type: 'effect-result';
    ok: boolean;
    message: string;
    targetId: string;
    kind: EffectKind;
    actor?: string;
} | {
    type: 'pause';
    paused: boolean;
} | {
    type: 'error';
    message: string;
};
/** The host browser owns physics. The server relays guest input and host state. */
export class RoomConnection {
    socket: WebSocket | null = null;
    role: RoomRole | null = null;
    code = '';
    hostConfig: PlayerConfig | null = null;
    guestConfig: PlayerConfig | null = null;
    onMessage: (message: RoomMessage) => void = () => { };
    onStatus: (status: string) => void = () => { };
    private deliberatelyClosed = false;
    private appearanceCache = new Map<string, PlayerConfig>();
    connect(): Promise<void> {
        if (this.socket?.readyState === WebSocket.OPEN)
            return Promise.resolve();
        this.deliberatelyClosed = false;
        const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
        return new Promise((resolve, reject) => {
            const socket = new WebSocket(`${scheme}//${location.host}/ws`);
            this.socket = socket;
            const timeout = window.setTimeout(() => {
                socket.close();
                reject(new Error('连接超时，请确认联机服务已启动'));
            }, 8000);
            socket.onopen = () => {
                window.clearTimeout(timeout);
                this.onStatus('已连接');
                resolve();
            };
            socket.onerror = () => {
                window.clearTimeout(timeout);
                reject(new Error('无法连接联机服务，请使用 npm start 启动游戏'));
            };
            socket.onclose = () => {
                window.clearTimeout(timeout);
                if (this.socket !== socket)
                    return;
                this.role = null;
                this.guestConfig = null;
                if (!this.deliberatelyClosed) {
                    this.onStatus('连接中断');
                    this.onMessage({ type: 'peer-left', message: '联机连接已中断，请重新创建或加入房间' });
                }
            };
            socket.onmessage = event => {
                if (this.socket !== socket)
                    return;
                try {
                    const message = JSON.parse(event.data) as RoomMessage;
                    if (message.type === 'room') {
                        this.role = message.role;
                        this.code = message.code;
                        this.hostConfig = message.hostConfig;
                        this.guestConfig = message.guestConfig || null;
                        this.appearanceCache.set(message.hostConfig.id, message.hostConfig);
                        if (message.guestConfig)
                            this.appearanceCache.set(message.guestConfig.id, message.guestConfig);
                    }
                    else if (message.type === 'peer-joined') {
                        this.guestConfig = message.config;
                        this.appearanceCache.set(message.config.id, message.config);
                    }
                    else if (message.type === 'start') {
                        for (const player of message.players)
                            this.appearanceCache.set(player.id, player);
                    }
                    else if (message.type === 'state') {
                        for (const entity of message.snapshot.entities) {
                            const config = this.appearanceCache.get(entity.id);
                            if (config) {
                                entity.character = config.character;
                                entity.ball = config.ball;
                            }
                        }
                    }
                    else if (message.type === 'peer-left')
                        this.guestConfig = null;
                    this.onMessage(message);
                }
                catch {
                    this.onStatus('收到无效联机数据');
                }
            };
        });
    }
    create(config: PlayerConfig): void {
        this.send({ type: 'create', config });
    }
    join(code: string, config: PlayerConfig): void {
        this.send({ type: 'join', code: code.trim().toUpperCase(), config });
    }
    send(payload: Record<string, unknown>): boolean {
        if (this.socket?.readyState !== WebSocket.OPEN) {
            this.onStatus('尚未连接联机服务');
            return false;
        }
        if (this.socket.bufferedAmount > 3000000)
            return false;
        if (payload.type === 'state' && payload.snapshot) {
            const snapshot = payload.snapshot as Snapshot;
            this.socket.send(JSON.stringify({ ...payload, snapshot: { ...snapshot, entities: snapshot.entities.map(entity => ({
                        ...entity, character: { colors: entity.character.colors }, ball: { colors: entity.ball.colors },
                    })) } }));
        }
        else
            this.socket.send(JSON.stringify(payload));
        return true;
    }
    close(): void {
        this.deliberatelyClosed = true;
        this.socket?.close();
        this.socket = null;
        this.role = null;
        this.code = '';
        this.hostConfig = null;
        this.guestConfig = null;
        this.appearanceCache.clear();
    }
}
