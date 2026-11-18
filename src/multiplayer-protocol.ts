import type {AnimalKind, Appearance, EffectKind, PlayerConfig, Snapshot} from './simulation';

export const MULTIPLAYER_PROTOCOL = 1;
export const MULTIPLAYER_ROOM = 'bumpball';
export const MIN_ROOM_PLAYERS = 2;
export const MAX_ROOM_PLAYERS = 4;
export type RoomPhase = 'lobby' | 'loading' | 'match' | 'finished';

export interface RoomMember {
  id: string;
  name: string;
  animal: AnimalKind;
  character: Appearance;
  ball: Appearance;
  seat?: number;
  connected: boolean;
  queued: boolean;
}
export interface LobbyState {
  protocol: number;
  roomId: string;
  code: string;
  hostId: string;
  phase: RoomPhase;
  roundId: number;
  members: RoomMember[];
  participantIds: string[];
  paused: boolean;
}
export interface RoomView extends LobbyState {
  localId: string;
  role: 'host' | 'guest';
  connected: boolean;
  reconnecting?: boolean;
}
export interface PrepareRound {
  roundId: number;
  participantIds: string[];
}
export interface MatchUpdate {
  roundId: number;
  sequence: number;
  snapshot: Snapshot;
}
export interface InteractionRequest {
  roundId: number;
  requestId: string;
  kind: EffectKind;
  targetId?: string;
}
export interface InteractionEvent {
  eventId: string;
  roundId: number;
  actorId: string;
  targetId: string;
  kind: EffectKind;
  ok: boolean;
  message: string;
}
export interface RoomNotice {
  id: string;
  kind: 'joined' | 'left' | 'reconnected' | 'host-changed' | 'aborted' | 'info';
  message: string;
}
export interface JoinOptions {
  protocol: number;
  code?: string;
  config: Pick<PlayerConfig, 'name' | 'animal' | 'character' | 'ball'>;
}
