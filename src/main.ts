import { GameSimulation, type Snapshot, type PlayerConfig, type EffectKind } from './simulation';
import { GameRenderer, type CameraScope } from './render/game-renderer';
import { UI } from './ui';
import { RoomConnection, type RoomMessage } from './network';
import { GameAudio } from './audio';
import { assetUrl } from './asset-url';
import type { StageGeometryData } from './stage-geometry';
import './style.css';
import './menu.css';
import './interactions.css';
import './audio.css';
import './multiplayer.css';

type Screen = 'menu' | 'playing' | 'finished';
const boot = document.querySelector<HTMLDivElement>('#boot')!;

async function bootstrap() {
  const canvas = document.querySelector<HTMLCanvasElement>('#game')!;
  const stageGeometry = fetch(assetUrl('island/stage_geometry.json')).then(async response => {
    if (!response.ok) throw new Error(`海岛场地加载失败 (${response.status})`);
    return await response.json() as StageGeometryData;
  });
  const [renderer, sim] = await Promise.all([
    GameRenderer.create(canvas, stageGeometry),
    stageGeometry.then(geometry => GameSimulation.create({ geometry })),
  ]);
  const connection = new RoomConnection(), audio = new GameAudio();
  const keys = new Set<string>(), touchKeys = new Set<string>(), touch = { x: 0, y: 0 };
  const offline = !!(window as any).__BALL_ISLAND_STANDALONE__?.offline;
  let screen: Screen = 'menu', mode: 'solo'|'pk' = 'solo', localId = 'player';
  let snapshot = sim.snapshot(), paused = false, elapsed = 0, resultVisible = false;
  let netTimer = 0, uiTimer = 0, lastCountdown = 0, previewDrag: number|null = null, dragX = 0;
  let networkRound = -1, hideNetworkMatch = false, localNetworkMenu = false;
  let cameraScope: CameraScope|null = null, lastFrame = performance.now();
  const frameSamples: number[] = [], playedImpacts = new Set<string>(), fallen = new Set<string>();
  const ui = new UI({ onAction: (action, payload) => { void handleAction(action, payload); }, onUIClick:kind=>audio.ui(kind) });
  ui.setAudioSettings(audio.getSettings());
  addEventListener('pointerdown',()=>audio.unlock(),{once:true,capture:true});
  addEventListener('keydown',()=>audio.unlock(),{once:true,capture:true});
  for (const scope of ['match','victory'] as const) renderer.setCameraSettings(scope, ui.cameraSettings[scope]);
  const selectionConfig = (id = localId, name = '你'): PlayerConfig => ({ ...ui.getSelection(), id, name, human: true });
  const entity = () => snapshot.entities.find(e => e.id === localId);
  const resetInput = () => {
    keys.clear(); touchKeys.clear(); touch.x = touch.y = 0;
    if (screen !== 'menu') sim.setInput(localId, 0, 0);
    if (mode === 'pk') connection.input(0,0);
  };

  function setPaused(value: boolean, broadcast = false) {
    if (screen === 'menu' || snapshot.status === 'finished') return;
    if (broadcast && mode === 'pk') {
      if (connection.role === 'guest') {
        localNetworkMenu=value;resetInput();ui.setPaused(paused||localNetworkMenu);return;
      }
      if (connection.role !== 'host' || !entity()?.alive) return;
      resetInput(); connection.pause(value); return;
    }
    if (broadcast && value && !entity()?.alive) return;
    paused = value; sim.setPaused(value); resetInput(); ui.setPaused(value);
  }
  function beginRound(next:Snapshot = sim.snapshot()) {
    audio.resetRound();
    screen = 'playing'; snapshot = next; paused = false; localNetworkMenu=false; resultVisible = false; cameraScope = null;
    playedImpacts.clear(); fallen.clear(); lastCountdown = 0; resetInput();
    renderer.setCameraPreview(null); ui.setScreen('playing'); ui.setMode(mode); ui.setPaused(false); ui.setWinnerVisible(false); ui.update(snapshot, localId);
    audio.unlock();
  }
  function startSolo() {
    mode = 'solo'; void connection.close(); ui.setRoom(null); localId = 'player';
    sim.start([selectionConfig('player', '你')], 5); beginRound();
  }
  function startRoom() {
    if (connection.role !== 'host') { ui.toast('正在等待房主开始游戏'); return; }
    connection.start();
  }
  function showMenu() {
    audio.resetRound();
    mode = 'solo'; void connection.close(); sim.clear(); snapshot = sim.snapshot(); screen = 'menu'; localId = 'player';
    networkRound = -1; hideNetworkMatch = false; localNetworkMenu=false;
    paused = false; cameraScope = null; resetInput(); renderer.setCameraPreview(null);
    ui.setPaused(false); ui.setMode('solo'); ui.setRoom(null); ui.setScreen('menu'); ui.setWinnerVisible(false);
  }
  function showRoom() {
    audio.resetRound(); resetInput(); sim.clear(); snapshot=sim.snapshot();
    screen='menu';paused=false;localNetworkMenu=false;resultVisible=false;cameraScope=null;
    renderer.setCameraPreview(null);ui.setPaused(false);ui.setWinnerVisible(false);ui.setScreen('menu');ui.setMode('pk');roomUI();ui.openRoom();
  }
  async function connectRoom(code?: string, name='') {
    if (offline) { ui.toast('联机请使用“启动HTML版”打开完整版'); return; }
    if(connection.active){ui.openRoom();return}
    mode='pk';ui.setMode('pk');
    try {
      if(code)await connection.join(code,selectionConfig('',name));
      else await connection.create(selectionConfig('',name));
    } catch (error) { mode='solo';ui.setMode('solo');ui.toast((error as Error).message);ui.setRoom(null); }
  }
  function roomUI() {
    if (!connection.info || !connection.role) return;
    ui.setRoom({...connection.info,localId:connection.localId,role:connection.role,connected:connection.connected,reconnecting:connection.status==='reconnecting'});
  }
  function triggerEffect(kind: EffectKind, targetId = localId) {
    if (paused || localNetworkMenu || screen !== 'playing' || snapshot.status !== 'playing') return;
    if (mode === 'pk') {
      if(targetId!==localId){ui.toast('只能为自己的角色触发互动');return}
      connection.effect(kind); return;
    }
    const result = sim.applyEffect(targetId, kind);
    if (!result.ok) ui.toast(result.message);
    if (result.ok) {audio.effect(kind);if(kind==='airdrop')ui.toast(result.message)}
    snapshot = sim.snapshot(); ui.update(snapshot, localId);
  }
  connection.onMessage = (message: RoomMessage) => {
    switch (message.type) {
      case 'room':
        mode='pk';localId=connection.localId;ui.setMode('pk');roomUI();
        if(message.info.phase==='lobby'){networkRound=-1;hideNetworkMatch=false;showRoom()}
        else if(!connection.participating||message.info.phase==='loading')showRoom();
        else{paused=message.info.paused;ui.setPaused(paused||localNetworkMenu)}
        break;
      case 'prepare':
        if(message.participantIds.includes(connection.localId)){
          hideNetworkMatch=false;resetInput();connection.loaded(message.roundId);
        }
        break;
      case 'state':
        if(!connection.participating||hideNetworkMatch||message.roundId!==connection.roundId||!['match','finished'].includes(connection.info?.phase||''))break;
        if(networkRound!==message.roundId){networkRound=message.roundId;beginRound(message.snapshot)}
        snapshot=message.snapshot;paused=!!connection.info?.paused;
        if(!snapshot.entities.find(e=>e.id===localId)?.alive)localNetworkMenu=false;
        ui.setPaused(paused||localNetworkMenu);
        break;
      case 'effect-result':
        if(message.roundId!==connection.roundId)break;
        if(!message.ok){if(message.actorId===localId)ui.toast(message.message)}
        else{audio.effect(message.kind);if(message.kind==='airdrop'&&message.actorId===localId)ui.toast(message.message)}
        break;
      case 'notice': ui.toast(message.notice.message);break;
      case 'error': ui.toast(message.message); break;
    }
  };
  connection.onStatus=status=>{
    ui.setConnectionStatus(status);roomUI();
    if(status==='reconnecting'){resetInput();if(screen!=='menu'){paused=true;ui.setPaused(true)}ui.toast('连接中断，正在重连…')}
    if(status==='idle'&&mode==='pk'&&!connection.active){showMenu();ui.openRoom()}
  };
  async function handleAction(action: string, payload?: any) {
    audio.unlock();
    switch (action) {
      case 'start': if (payload?.mode === 'pk') await connectRoom(); else startSolo(); break;
      case 'effect': triggerEffect(payload.kind, payload.targetId || localId); break;
      case 'restart':
        if (mode === 'pk') { if (connection.role === 'host') {hideNetworkMatch=true;connection.returnLobby();showRoom()} else ui.toast('正在等待房主开始游戏'); }
        else startSolo();
        break;
      case 'pause': setPaused(!(paused||localNetworkMenu), true); break;
      case 'resume': setPaused(false, true); break;
      case 'menu': case 'leaveRoom': showMenu(); break;
      case 'closeRoom': if(!connection.info)showMenu();break;
      case 'returnRoom': hideNetworkMatch=true;if(connection.role==='host'&&connection.info?.phase==='finished')connection.returnLobby();showRoom();break;
      case 'createRoom': await connectRoom(undefined,payload?.name||''); break;
      case 'joinRoom': await connectRoom(payload.code,payload?.name||''); break;
      case 'startRoom': startRoom(); break;
      case 'touch':
        if (payload.pressed) touchKeys.add(payload.direction); else touchKeys.delete(payload.direction);
        touch.x = Number(touchKeys.has('right')) - Number(touchKeys.has('left'));
        touch.y = Number(touchKeys.has('down')) - Number(touchKeys.has('up')); break;
      case 'modal': resetInput(); break;
      case 'volume': if(payload?.bus==='sfx'||payload?.bus==='music'){audio.setVolume(payload.bus,payload.value);ui.setAudioSettings(audio.getSettings());}break;
      case 'mute': if(payload?.bus==='sfx'||payload?.bus==='music'){audio.toggleMute(payload.bus);ui.setAudioSettings(audio.getSettings());}break;
      case 'copyInvite': {
        const url = new URL(location.href); url.search = ''; url.searchParams.set('room', connection.code);
        try { await navigator.clipboard.writeText(url.href); ui.toast('邀请链接已复制'); } catch { ui.toast(`房间码：${connection.code}`); }
        break;
      }
    }
  }
  function inputVector() {
    let x = touch.x, y = touch.y;
    if (keys.has('KeyA') || keys.has('ArrowLeft')) x--;
    if (keys.has('KeyD') || keys.has('ArrowRight')) x++;
    if (keys.has('KeyW') || keys.has('ArrowUp')) y--;
    if (keys.has('KeyS') || keys.has('ArrowDown')) y++;
    const length = Math.hypot(x,y); if (length > 1) { x /= length; y /= length; }
    return renderer.inputToWorld(x,y,entity());
  }
  addEventListener('keydown', event => {
    if(event.code==='Escape'&&ui.closeSound()){event.preventDefault();audio.ui();return;}
    if ((event.target as HTMLElement)?.closest('input,textarea,select')) return;
    if (['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Space'].includes(event.code)) event.preventDefault();
    if (!event.repeat && (event.code === 'Escape' || event.code === 'KeyP')) {
      if (screen !== 'menu') {audio.ui();setPaused(!(paused||localNetworkMenu), true);}
      return;
    }
    if (ui.getInteractionBlocked()) return;
    keys.add(event.code);
    if (!event.repeat && screen === 'playing' && !paused && snapshot.status === 'playing') {
      const kind = ({Digit1:'grow',Digit2:'shrink',Digit3:'speedUp',Digit4:'speedDown',Digit5:'wind',Digit6:'airdrop',Digit7:'confusion'} as Record<string,EffectKind>)[event.code];
      if (kind) triggerEffect(kind);
      if ((import.meta.env.DEV || import.meta.env.VITE_ENABLE_QA === 'true') && (event.code === 'KeyN' || event.code === 'KeyM') && mode === 'solo') {
        const result = event.code === 'KeyN' ? sim.addNPC() : sim.removeNPC(); if (!result.ok) ui.toast(result.message);
      }
    }
  });
  addEventListener('keyup', event => keys.delete(event.code));
  addEventListener('blur', resetInput);
  document.addEventListener('visibilitychange', () => {
    resetInput();
    // The server keeps simulating even when a broadcaster switches windows.
  });
  // Only the character half of the menu rotates. Keep the normal pointer cursor.
  addEventListener('pointerdown', event => {
    if (screen !== 'menu' || event.button !== 0 || event.clientX > innerWidth*.54 || (event.target as HTMLElement)?.closest('.menu-panel,.character-panel,.bottom-controls,.room-panel,.toast-stack,button,input')) return;
    previewDrag = event.pointerId; dragX = event.clientX;
  });
  addEventListener('pointermove', event => {
    if (previewDrag !== event.pointerId || screen !== 'menu') return;
    renderer.rotatePreview((event.clientX-dragX)*.009); dragX = event.clientX;
  });
  const endDrag = () => { previewDrag = null; };
  addEventListener('pointerup',endDrag); addEventListener('pointercancel',endDrag);
  addEventListener('resize', () => renderer.resize());
  addEventListener('ball-renderer-context', ((event: CustomEvent) => {
    if (event.detail.lost) { setPaused(true,true); ui.toast('画面正在恢复'); }
    else { renderer.resize(); ui.toast('画面已恢复，可继续游戏'); }
  }) as EventListener);

  ui.setScreen('menu'); boot.remove();
  const invitation = new URL(location.href).searchParams.get('room');
  if (!offline) {
    void(async()=>{
      const restored=await connection.restore();
      if(!restored&&invitation&&/^\d{6}$/.test(invitation))await connectRoom(invitation);
    })();
  }
  function frame(now: number) {
    const dt = Math.min(.05, Math.max(0,(now-lastFrame)/1000)); lastFrame = now;
    if (!paused) elapsed += dt;
    frameSamples.push(dt); if (frameSamples.length > 180) frameSamples.shift();
    netTimer += dt; uiTimer += dt;
    if (screen !== 'menu') {
      const input = paused || localNetworkMenu || ui.getInteractionBlocked() || cameraScope ? {x:0,z:0} : inputVector();
      if (mode === 'pk') {
        if (netTimer >= 1/30) { connection.input(input.x,input.z); netTimer = 0; }
      } else {
        sim.setInput(localId,input.x,input.z); if (!paused) sim.step(dt); snapshot = sim.snapshot();
      }
      const countdown = snapshot.status === 'countdown' ? Math.ceil(snapshot.countdownRemaining) : 0;
      if (countdown && countdown !== lastCountdown) audio.countdown();
      lastCountdown = countdown;
      if (snapshot.status === 'playing' || snapshot.status === 'finished') {
        for (const impact of snapshot.impacts) {
          const key = `${impact.a}:${impact.b}:${impact.at}`;
          if (!playedImpacts.has(key)) { playedImpacts.add(key); audio.bump(impact.closingSpeed,impact.enhanced); }
        }
      }
      for (const e of snapshot.entities) if (e.waterEntry && !e.withdrawn && !fallen.has(e.id)) { fallen.add(e.id); audio.splash(); }
      if (snapshot.status === 'finished') screen = 'finished';
    }
    audio.update(snapshot,localId,screen,paused);
    renderer.update(snapshot,localId,{screen,paused,dt,elapsed,selected:selectionConfig(),cameraScope,interpolate:mode==='pk'});
    renderer.render();
    if (screen !== 'menu' && uiTimer >= .06) { ui.update(snapshot,localId); uiTimer = 0; }
    if (screen === 'finished' && !resultVisible && renderer.isFocusDone()) {
      resultVisible = true; ui.setScreen('finished');
      const winner = snapshot.entities.find(e=>e.id===snapshot.winnerId);
      ui.showResult(winner?.name || '玩家',snapshot.winnerId===localId); ui.setWinnerVisible(true);
      if(snapshot.winnerId===localId)audio.win();
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  if ((import.meta.env.DEV || import.meta.env.VITE_ENABLE_QA === 'true') && new URL(location.href).searchParams.has('qa')) {
    (window as any).__audio = audio;
    (window as any).__simulation = sim;
    (window as any).__game = {
      ready:true,version:'2.0.0-web',startSolo,getSnapshot:()=>structuredClone(snapshot),effect:(kind:EffectKind,id=localId)=>triggerEffect(kind,id),
      action:handleAction,getSelection:()=>ui.getSelection(),addNPC:()=>sim.addNPC(),removeNPC:()=>sim.removeNPC(),forceFall:(id:string)=>sim.forceFall(id),
      setAI:(value:boolean)=>sim.setAIEnabled(value),getRoom:()=>({code:connection.code,role:connection.role,id:connection.localId,info:connection.info,status:connection.status,endpoint:connection.endpoint}),
      camera:(scope:CameraScope,settings:any)=>renderer.setCameraSettings(scope,settings),inputToWorld:(x:number,y:number)=>renderer.inputToWorld(x,y,entity()),
      project:(x:number,y:number,z:number)=>{ const p=renderer.camera.position.clone().set(x,y,z).project(renderer.camera);return{x:(p.x*.5+.5)*innerWidth,y:(-p.y*.5+.5)*innerHeight}; },
      getRender:()=>({camera:renderer.camera.position.toArray(),previewYaw:(renderer as any).previewYaw,animations:[...(renderer as any).views.values()].map((v:any)=>({id:v.config.id,clip:v.currentClip,ballColor:v.sphere.material.color.getHexString(),floating:v.floating,bodyY:v.body.position.y})),stats:renderer.renderer.info.render}),
      metrics:()=>({fps:Math.round(1/(frameSamples.reduce((a,b)=>a+b,0)/frameSamples.length)),calls:renderer.renderer.info.render.calls,triangles:renderer.renderer.info.render.triangles,screen,paused,drawingBuffer:{width:canvas.width,height:canvas.height},offline}),
    };
  }
}
bootstrap().catch(error=>{
  console.error(error);
  boot.innerHTML='<strong>游戏暂时无法加载</strong><span>请使用 Chrome 或 Edge，并开启硬件加速。</span><button onclick="location.reload()">重新加载</button>';
});
