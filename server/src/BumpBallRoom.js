import {randomInt, randomUUID} from 'node:crypto';
import {Room, ServerError} from '@colyseus/core';
import {MULTIPLAYER_PROTOCOL, MIN_ROOM_PLAYERS, MAX_ROOM_PLAYERS} from '../../src/multiplayer-protocol.ts';

const ANIMALS=new Set(['rabbit','bear','hamster','cat','dog','fox','panda','raccoon']);
const SEAT_APPEARANCES = [
 { animal: 'dog', ballColor: '#16C751' },
 { animal: 'cat', ballColor: '#E91C49' },
 { animal: 'panda', ballColor: '#1A5CF0' },
 { animal: 'raccoon', ballColor: '#FFD429' },
];
const EFFECTS=new Set(['grow','shrink','speedUp','speedDown','wind','airdrop','confusion']);
const zero=()=>({x:0,z:0});
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const number=value=>typeof value==='number'&&Number.isFinite(value);
const color=value=>typeof value==='string'&&/^#[a-f\d]{6}$/i.test(value);
const safeName=value=>typeof value==='string'?value.replace(/[\p{Cc}\p{Cf}]/gu,'').trim().slice(0,16):'';
const field=(value,key)=>Object.prototype.hasOwnProperty.call(value,key);

function cleanOptions(options){
 if(!object(options)||options.protocol!==MULTIPLAYER_PROTOCOL)throw new ServerError(409,'游戏版本不一致，请刷新页面后重试');
 const config=options.config;
 if(!object(config)||!ANIMALS.has(config.animal))throw new ServerError(400,'请选择有效的动物角色');
 const appearance=(value,fallback)=>({colors:Array.isArray(value?.colors)?value.colors.filter(color).slice(0,3):[...fallback]});
 return{name:safeName(config.name),animal:config.animal,character:appearance(config.character,[]),ball:appearance(config.ball,['#173e69'])};
}

/** Colyseus owns seats and reconnection; one shared simulation owns every outcome. */
export function makeBumpBallRoom({createSimulation,loadingTimeoutMs=20000,reconnectSeconds=10,settlementMs=8000,introSeconds=1.6,countdownSeconds=3,inputTimeoutMs=500,maxRooms=32}={}){
 if(typeof createSimulation!=='function')throw new TypeError('createSimulation is required');
 return class BumpBallRoom extends Room{
  static activeCodes=new Set();
  maxClients=MAX_ROOM_PLAYERS;
  maxMessagesPerSecond=120;
  members=new Map();hostId='';phase='lobby';roundId=0;participantIds=[];loadedIds=new Set();paused=false;
  simulation=null;sequence=0;broadcastElapsed=0;preparingTimer=null;settlementTimer=null;eventReceipts=new Map();

  async onCreate(){
   if(BumpBallRoom.activeCodes.size>=maxRooms)throw new ServerError(503,'联机服务繁忙，请稍后再试');
   let code;do code=String(randomInt(100000,1000000));while(BumpBallRoom.activeCodes.has(code));
   this.roomId=code;BumpBallRoom.activeCodes.add(code);await this.setPrivate(true);
   try{this.simulation=await createSimulation()}catch(error){BumpBallRoom.activeCodes.delete(code);throw error}
   this.onMessage('start',client=>this.start(client));
   this.onMessage('loaded',(client,data)=>this.loaded(client,data));
   this.onMessage('input',(client,data)=>this.input(client,data));
   this.onMessage('effect',(client,data)=>this.effect(client,data));
   this.onMessage('pause',(client,data)=>this.pause(client,data));
   this.onMessage('return-lobby',client=>this.returnRequest(client));
   this.onMessage('sync',client=>{const m=this.members.get(client.sessionId),now=Date.now();if(!m||now-(m.lastSyncAt||0)<100)return;m.lastSyncAt=now;this.sendLobby(client);if(this.phase==='loading')client.send('prepare',{roundId:this.roundId,participantIds:[...this.participantIds]});this.sendSnapshot(client)});
   this.onMessage('ping',(client,data)=>{if(number(data?.clientTime))client.send('pong',{clientTime:data.clientTime,serverTime:Date.now()})});
   this.onMessage('*',client=>this.fail(client,'INVALID_MESSAGE','无效的联机请求'));
   this.setSimulationInterval(deltaMs=>this.advance(deltaMs),1000/60);
  }

  onAuth(_client,options){if(this.members.size>=MAX_ROOM_PLAYERS)throw new ServerError(409,'房间已满');return cleanOptions(options)}

  onJoin(client,_options,auth){
   if(this.members.size>=MAX_ROOM_PLAYERS)throw new ServerError(409,'房间已满');
   const used=new Set([...this.members.values()].map(member=>member.seat));let seat=0;while(used.has(seat))seat++;
   const { animal, ballColor } = SEAT_APPEARANCES[seat];
   const member={id:client.sessionId,name:auth.name||`玩家${seat+1}`,animal,character:{colors:[]},ball:{colors:[ballColor]},seat,client,connected:true,queued:this.phase!=='lobby',lastInput:zero(),lastInputAt:0,lastSequence:-1,rateWindow:0,eventPackets:0,lastSyncAt:0};
   const names=new Set([...this.members.values()].map(value=>value.name));if(names.has(member.name))member.name=`${member.name.slice(0,13)}·${seat+1}`;
   this.members.set(member.id,member);this.chooseHost();this.sendLobby();this.sendSnapshot(client);this.notice('joined',`${member.name}加入了房间`);
  }

  onDrop(client){
   const member=this.members.get(client.sessionId);if(!member)return;
   this.allowReconnection(client,reconnectSeconds).catch(()=>{});
   member.client=null;member.connected=false;this.handleDeparture(member,false);
  }

  onReconnect(client){
   const member=this.members.get(client.sessionId);if(!member)return;
   member.client=client;member.connected=true;member.queued=this.phase!=='lobby';member.lastInput=zero();member.lastInputAt=0;member.lastSequence=-1;
   this.chooseHost();this.sendLobby();this.sendSnapshot(client);this.notice('reconnected',`${member.name}已重新连接${member.queued?'，等待下一局':''}`);
  }

  onLeave(client){
   const member=this.members.get(client.sessionId);if(!member)return;
   const wasConnected=member.connected;member.connected=false;member.client=null;this.members.delete(member.id);
   if(wasConnected)this.handleDeparture(member,true);else{this.chooseHost();this.sendLobby()}
  }

  onDispose(){BumpBallRoom.activeCodes.delete(this.roomId);this.clearRoundTimers();this.simulation?.dispose();this.simulation=null;this.members.clear();this.eventReceipts.clear()}

  chooseHost(){
   if(this.members.get(this.hostId)?.connected)return;
   const old=this.hostId;this.hostId=[...this.members.values()].find(member=>member.connected)?.id||'';
   if(old&&this.hostId&&old!==this.hostId){
    // A pause belongs to the old host; never leave the room stuck behind it.
    if(this.phase==='match'&&this.paused){
     this.paused=false;this.simulation?.setPaused(false);
     for(const member of this.members.values()){member.lastInput=zero();member.lastInputAt=0;this.simulation?.setInput(member.id,0,0)}
    }
    this.notice('host-changed',`${this.members.get(this.hostId).name}成为了房主`);
   }
  }

  handleDeparture(member,intentional){
   member.lastInput=zero();member.lastInputAt=0;this.simulation?.setInput(member.id,0,0);
   const participating=this.participantIds.includes(member.id)&&!member.queued;
   member.queued=this.phase!=='lobby';this.loadedIds.delete(member.id);this.chooseHost();
   this.notice('left',`${member.name}已离开游戏${intentional?'':'（连接中断）'}`);
   if(participating&&(this.phase==='loading'||this.phase==='match')){
    if(this.connectedParticipants()<MIN_ROOM_PLAYERS){this.abort('由于剩余玩家人数不足两人，游戏自动终止');return}
    if(this.phase==='loading'){this.participantIds=this.participantIds.filter(id=>id!==member.id);this.tryBegin()}
    else{this.simulation?.withdrawPlayer(member.id);this.checkFinished()}
   }
   this.sendLobby();this.sendSnapshot();
  }

  connectedParticipants(){return this.participantIds.filter(id=>{const member=this.members.get(id);return member?.connected&&!member.queued}).length}
  participant(client){const member=this.members.get(client.sessionId);return member?.connected&&!member.queued&&this.participantIds.includes(member.id)?member:null}
  fail(client,code,message){client.send('error',{code,message})}

  start(client){
   if(this.hostId!==client.sessionId)return this.fail(client,'HOST_ONLY','正在等待房主开始游戏');
   if(this.phase!=='lobby'&&this.phase!=='finished')return this.fail(client,'WRONG_PHASE','本局已开始，请等待结束');
   const online=[...this.members.values()].filter(member=>member.connected).sort((a,b)=>a.seat-b.seat);
   if(online.length<MIN_ROOM_PLAYERS)return this.fail(client,'MIN_PLAYERS','至少两名玩家才能开始游戏');
   this.clearRoundTimers();this.simulation.clear();this.phase='loading';this.roundId++;
   this.participantIds=online.map(member=>member.id);this.loadedIds.clear();this.eventReceipts.clear();this.sequence=0;this.broadcastElapsed=0;this.paused=false;
   for(const member of this.members.values()){member.queued=!member.connected;member.lastInput=zero();member.lastInputAt=0;member.lastSequence=-1}
   this.preparingTimer=this.clock.setTimeout(()=>{if(this.phase==='loading')this.abort('有玩家加载超时，已返回房间，请重新开始')},loadingTimeoutMs);
   this.sendLobby();this.broadcast('prepare',{roundId:this.roundId,participantIds:[...this.participantIds]});
  }

  loaded(client,data){if(this.phase!=='loading'||data?.roundId!==this.roundId||!this.participant(client))return;this.loadedIds.add(client.sessionId);this.tryBegin()}
  tryBegin(){
   if(this.phase!=='loading'||this.connectedParticipants()<MIN_ROOM_PLAYERS)return;
   if(!this.participantIds.every(id=>this.members.get(id)?.connected&&this.loadedIds.has(id)))return;
   this.preparingTimer?.clear();this.preparingTimer=null;
   const players=this.participantIds.map(id=>{const member=this.members.get(id);return{id,name:member.name,animal:member.animal,character:member.character,ball:member.ball,human:true}});
   this.simulation.start(players,Math.max(0,6-players.length),countdownSeconds,introSeconds);this.phase='match';this.sendLobby();this.sendSnapshot();
  }

  input(client,data){
   const member=this.participant(client);
   if(!member||this.phase!=='match'||this.paused||!object(data)||data.roundId!==this.roundId)return;
   if(['actorId','targetId','playerId','position','state','snapshot'].some(key=>field(data,key)))return;
   if(!Number.isSafeInteger(data.sequence)||data.sequence<=member.lastSequence||!number(data.x)||!number(data.z))return;
   const divisor=Math.max(1,Math.hypot(data.x,data.z));member.lastInput={x:data.x/divisor,z:data.z/divisor};
   member.lastSequence=data.sequence;member.lastInputAt=Date.now();this.simulation.setInput(member.id,member.lastInput.x,member.lastInput.z);
  }

  effect(client,data){
   if(!object(data))return;const member=this.participant(client);
   if(!member)return this.fail(client,'NOT_PARTICIPATING','请等待下一局开始后再触发互动');
   if(['actorId','playerId','state','snapshot'].some(key=>field(data,key))||(data.targetId!==undefined&&data.targetId!==client.sessionId))return this.fail(client,'INVALID_TARGET','只能为自己的角色触发互动');
   if(typeof data.requestId!=='string'||!/^[A-Za-z0-9_.:-]{1,100}$/.test(data.requestId))return;
   const now=Date.now();if(now-member.rateWindow>=1000){member.rateWindow=now;member.eventPackets=0}
   if(++member.eventPackets>12)return this.fail(client,'RATE_LIMIT','互动触发过快，请稍候');
   const result=this.applyInteraction({actorId:member.id,eventId:data.requestId,roundId:data.roundId,kind:data.kind,origin:'client'});
   if(!result.ok)client.send('effect-result',result);
  }

  /** Gift adapters authenticate the live room before calling this server-owned entry. */
  applyInteraction({actorId,eventId,roundId,kind,origin}){
   const key=`${actorId}:${eventId}`,base={eventId:`${roundId}:${key}`,roundId,actorId,targetId:actorId,kind};
   if(roundId!==this.roundId)return{...base,ok:false,message:'上一局的互动已失效'};
   if(this.eventReceipts.has(key))return this.eventReceipts.get(key);
   // Do not evict identities and allow a delayed replay to apply for a second time.
   if(this.eventReceipts.size>=10000)return{...base,ok:false,message:'本局互动请求数量已达上限'};
   const member=this.members.get(actorId);let result;
   if(!['client','gift'].includes(origin)||!EFFECTS.has(kind))result={ok:false,message:'无效的互动事件'};
   else if(this.phase!=='match'||this.paused||!member?.connected||member.queued||!this.participantIds.includes(actorId))result={ok:false,message:'本局进行时才能触发互动'};
   else result=this.simulation.applyEffect(actorId,kind);
   const receipt={...base,...result};this.eventReceipts.set(key,receipt);
   if(receipt.ok){this.broadcast('effect-result',receipt);this.sendSnapshot()}
   return receipt;
  }

  pause(client,data){
   if(client.sessionId!==this.hostId)return this.fail(client,'HOST_ONLY','由房主控制暂停');
   if(data?.roundId!==this.roundId||typeof data.paused!=='boolean'||this.phase!=='match')return;
   const own=this.simulation.snapshot().entities.find(entity=>entity.id===client.sessionId);
   if(!own?.alive)return this.fail(client,'SPECTATING','观战时无法暂停');
   this.paused=data.paused;this.simulation.setPaused(this.paused);
   for(const member of this.members.values()){member.lastInput=zero();member.lastInputAt=0;this.simulation.setInput(member.id,0,0)}
   this.sendLobby();this.sendSnapshot();
  }

  returnRequest(client){
   if(client.sessionId!==this.hostId)return this.fail(client,'HOST_ONLY','等待房主操作');
   if(this.phase!=='finished'&&!(this.phase==='match'&&this.paused))return this.fail(client,'WRONG_PHASE','比赛结束后返回房间');
   this.returnToLobby();
  }

  advance(deltaMs){
   if(!this.simulation||(this.phase!=='match'&&this.phase!=='finished'))return;
   const now=Date.now();for(const member of this.members.values())if(!member.connected||now-member.lastInputAt>inputTimeoutMs){member.lastInput=zero();this.simulation.setInput(member.id,0,0)}
   this.simulation.step(Math.max(0,Math.min(.1,deltaMs/1000)));this.checkFinished();this.broadcastElapsed+=Math.max(0,deltaMs);
   if(this.broadcastElapsed>=50){this.broadcastElapsed%=50;this.sendSnapshot()}
  }

  checkFinished(){
   if(this.phase!=='match'||this.simulation.snapshot().status!=='finished')return;
   this.phase='finished';this.paused=false;this.simulation.setPaused(false);this.sendLobby();this.sendSnapshot();
   this.settlementTimer=this.clock.setTimeout(()=>{if(this.phase==='finished')this.returnToLobby()},settlementMs);
  }
  abort(message){this.notice('aborted',message);this.returnToLobby()}
  returnToLobby(){
   this.clearRoundTimers();this.simulation?.clear();this.phase='lobby';this.paused=false;this.participantIds=[];this.loadedIds.clear();this.eventReceipts.clear();this.sequence=0;
   for(const member of this.members.values()){member.queued=false;member.lastInput=zero();member.lastInputAt=0;member.lastSequence=-1}
   this.chooseHost();this.sendLobby();
  }
  clearRoundTimers(){this.preparingTimer?.clear();this.preparingTimer=null;this.settlementTimer?.clear();this.settlementTimer=null}
  lobbyState(){return{protocol:MULTIPLAYER_PROTOCOL,roomId:this.roomId,code:this.roomId,hostId:this.hostId,phase:this.phase,roundId:this.roundId,paused:this.paused,participantIds:[...this.participantIds],members:[...this.members.values()].map(({id,name,animal,character,ball,seat,connected,queued})=>({id,name,animal,character,ball,seat,connected,queued}))}}
  sendLobby(client){if(client)client.send('lobby',this.lobbyState());else this.broadcast('lobby',this.lobbyState())}
  sendSnapshot(client){if(!this.simulation||(this.phase!=='match'&&this.phase!=='finished'))return;const update={roundId:this.roundId,sequence:++this.sequence,snapshot:this.simulation.snapshot()};if(client)client.send('snapshot',update);else this.broadcast('snapshot',update)}
  notice(kind,message){this.broadcast('notice',{id:randomUUID(),kind,message})}
 };
}
export{cleanOptions};
