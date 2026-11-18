import {Client, type Room} from '@colyseus/sdk';
import type {EffectKind, PlayerConfig} from './simulation';
import {MULTIPLAYER_PROTOCOL, MULTIPLAYER_ROOM, type LobbyState, type PrepareRound,
  type MatchUpdate, type InteractionEvent, type RoomNotice} from './multiplayer-protocol';

export type ConnectionStatus = 'idle' | 'connecting' | 'connected' | 'reconnecting';
export type RoomRole = 'host' | 'guest';
export type RoomMessage =
  | {type:'room'; info:LobbyState}
  | ({type:'prepare'} & PrepareRound)
  | ({type:'state'} & MatchUpdate)
  | ({type:'effect-result'} & InteractionEvent)
  | {type:'notice'; notice:RoomNotice}
  | {type:'error'; message:string};
const SESSION_KEY='bumpball.multiplayer.session.v1';

export function multiplayerEndpoint():string {
  const env=(import.meta as ImportMeta & {env?:Record<string,string>}).env;
  const url=new URL(env?.VITE_MULTIPLAYER_URL?.trim()||`${location.origin}/services/bumpball`);
  if(url.protocol==='wss:')url.protocol='https:';
  if(url.protocol==='ws:')url.protocol='http:';
  if(!['http:','https:'].includes(url.protocol)||url.username||url.password)throw Error('联机服务地址无效');
  if(location.protocol==='https:'&&url.protocol!=='https:')throw Error('请使用安全的联机服务地址');
  return url.href.replace(/\/+$/,'');
}
function friendlyError(error:unknown):Error {
  const message=String((error as Error)?.message||'');
  if(/[\u4e00-\u9fff]/.test(message))return Error(message);
  if(/not found|not exist|invalid room|couldn't find/i.test(message))return Error('房间不存在或已关闭');
  if(/locked|full|maxClients|seats/i.test(message))return Error('房间已满，请等待空位');
  if(/protocol|version/i.test(message))return Error('游戏版本不一致，请刷新页面');
  return Error('无法连接联机服务，请稍后重试');
}

/** Colyseus owns connections; all clients render the same server simulation. */
export class RoomConnection {
  private room:Room|null=null;
  private client:Client|null=null;
  private attempt=0;
  private joining=false;
  private deliberate=false;
  private inputSequence=0;
  private effectSequence=0;
  private snapshotSequence=-1;
  private snapshotRound=-1;
  private notices=new Set<string>();
  private effectEvents=new Set<string>();
  info:LobbyState|null=null;
  status:ConnectionStatus='idle';
  endpoint='';
  onMessage:(message:RoomMessage)=>void=()=>{};
  onStatus:(status:ConnectionStatus)=>void=()=>{};
  get localId(){return this.room?.sessionId||''}
  get role():RoomRole|null{return this.info&&this.localId?(this.info.hostId===this.localId?'host':'guest'):null}
  get code(){return this.info?.code||''}
  get active(){return !!this.room||this.joining}
  get connected(){return this.status==='connected'}
  get roundId(){return this.info?.roundId||0}
  get participating(){const own=this.info?.members.find(p=>p.id===this.localId);return !!own?.connected&&!own.queued&&!!this.info?.participantIds.includes(this.localId)}
  async create(config:PlayerConfig){return this.joinRoom(null,config)}
  async join(code:string,config:PlayerConfig){
    if(!/^\d{6}$/.test(code))throw Error('请输入6位数字房间码');
    return this.joinRoom(code,config);
  }
  private async joinRoom(code:string|null,config:PlayerConfig){
    if(this.active)throw Error('请先离开当前房间');
    const attempt=++this.attempt;this.joining=true;this.deliberate=false;this.changeStatus('connecting');
    try{
      this.endpoint=multiplayerEndpoint();this.client=new Client(this.endpoint);
      const options={protocol:MULTIPLAYER_PROTOCOL,config:{name:config.name,animal:config.animal,character:config.character,ball:config.ball}};
      const room=code?await this.client.joinById(code,options):await this.client.create(MULTIPLAYER_ROOM,options);
      if(attempt!==this.attempt){await room.leave(true);return}
      this.attach(room);return room;
    }catch(error){if(attempt===this.attempt){this.forget();this.changeStatus('idle');throw friendlyError(error)}}
    finally{if(attempt===this.attempt)this.joining=false}
  }
  async restore():Promise<boolean>{
    if(this.active)return false;
    let saved:{endpoint?:string;token?:string}|null=null;
    try{saved=JSON.parse(sessionStorage.getItem(SESSION_KEY)||'null')}catch{}
    if(!saved?.token)return false;
    try{this.endpoint=multiplayerEndpoint()}catch{return false}
    if(saved.endpoint!==this.endpoint){this.forget();return false}
    const attempt=++this.attempt;this.joining=true;this.deliberate=false;this.changeStatus('reconnecting');
    try{
      this.client=new Client(this.endpoint);const room=await this.client.reconnect(saved.token);
      if(attempt!==this.attempt){await room.leave(true);return false}
      this.attach(room);return true;
    }catch{if(attempt===this.attempt){this.forget();this.changeStatus('idle')}return false}
    finally{if(attempt===this.attempt)this.joining=false}
  }
  private attach(room:Room){
    room.reconnection.minUptime=0;
    room.reconnection.maxEnqueuedMessages=0;
    this.room=room;this.inputSequence=0;this.snapshotSequence=-1;this.snapshotRound=-1;
    this.notices.clear();this.effectEvents.clear();this.changeStatus('connected');this.save();
    const current=()=>this.room===room;
    room.onMessage('lobby',(info:LobbyState)=>{
      if(!current())return;
      if(info.protocol!==MULTIPLAYER_PROTOCOL){this.onMessage({type:'error',message:'游戏版本不一致，请刷新页面'});void this.close();return}
      this.info=info;this.onMessage({type:'room',info});
    });
    room.onMessage('prepare',(data:PrepareRound)=>{if(current())this.onMessage({type:'prepare',...data})});
    room.onMessage('snapshot',(data:MatchUpdate)=>{
      if(!current()||data.roundId<this.snapshotRound||data.roundId===this.snapshotRound&&data.sequence<=this.snapshotSequence)return;
      this.snapshotRound=data.roundId;this.snapshotSequence=data.sequence;this.onMessage({type:'state',...data});
    });
    room.onMessage('effect-result',(data:InteractionEvent)=>{
      if(!current()||this.effectEvents.has(data.eventId))return;
      this.effectEvents.add(data.eventId);if(this.effectEvents.size>512)this.effectEvents.delete(this.effectEvents.values().next().value!);
      this.onMessage({type:'effect-result',...data});
    });
    room.onMessage('notice',(notice:RoomNotice)=>{
      if(!current()||this.notices.has(notice.id))return;
      this.notices.add(notice.id);if(this.notices.size>128)this.notices.delete(this.notices.values().next().value!);
      this.onMessage({type:'notice',notice});
    });
    room.onMessage('error',(error:{message:string})=>{if(current())this.onMessage({type:'error',message:error.message})});
    room.onError((_code,message)=>{if(current())this.onMessage({type:'error',message:friendlyError(Error(message)).message})});
    room.onDrop(()=>{if(current()&&!this.deliberate)this.changeStatus('reconnecting')});
    room.onReconnect(()=>{if(current()){this.changeStatus('connected');this.save();room.send('sync')}});
    room.onLeave(()=>{
      if(!current())return;
      const unexpected=!this.deliberate;
      this.room=null;this.info=null;this.forget();this.changeStatus('idle');
      if(unexpected)this.onMessage({type:'error',message:'联机连接已断开，请重新加入房间'});
    });
    room.send('sync');
  }
  input(x:number,z:number){if(this.connected&&this.participating)this.room?.send('input',{roundId:this.roundId,sequence:++this.inputSequence,x,z})}
  start(){if(this.connected&&this.role==='host')this.room?.send('start')}
  loaded(roundId:number){if(this.connected)this.room?.send('loaded',{roundId})}
  effect(kind:EffectKind){if(this.connected&&this.participating)this.room?.send('effect',{roundId:this.roundId,requestId:`${this.localId}:${Date.now()}:${++this.effectSequence}`,kind})}
  pause(paused:boolean){if(this.connected&&this.role==='host')this.room?.send('pause',{roundId:this.roundId,paused})}
  returnLobby(){if(this.connected&&this.role==='host')this.room?.send('return-lobby')}
  async close(){
    this.deliberate=true;++this.attempt;this.joining=false;
    const room=this.room;this.room=null;this.info=null;this.client=null;this.forget();this.changeStatus('idle');
    if(room)try{await room.leave(true)}catch{}
  }
  private changeStatus(status:ConnectionStatus){if(this.status===status)return;this.status=status;this.onStatus(status)}
  private save(){try{if(this.room?.reconnectionToken)sessionStorage.setItem(SESSION_KEY,JSON.stringify({endpoint:this.endpoint,token:this.room.reconnectionToken}))}catch{}}
  private forget(){try{sessionStorage.removeItem(SESSION_KEY)}catch{}}
}
