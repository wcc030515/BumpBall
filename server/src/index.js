import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import express from 'express';
import {Server} from '@colyseus/core';
import {WebSocketTransport} from '@colyseus/ws-transport';
import {GameSimulation} from '../../src/simulation.ts';
import {MULTIPLAYER_PROTOCOL,MULTIPLAYER_ROOM} from '../../src/multiplayer-protocol.ts';
import {makeBumpBallRoom} from './BumpBallRoom.js';

const moduleDir=path.dirname(fileURLToPath(import.meta.url));
const identity={appId:'ball-island-survival',name:'海岛碰碰球',version:'2.0.0-web',assetRevision:'colyseus-multiplayer-v1',protocol:MULTIPLAYER_PROTOCOL,service:'bumpball',authoritative:true};

/** Normalize only this game's namespace before Node dispatches HTTP/WS listeners. */
class BumpBallHTTPServer extends http.Server{
 emit(event,...args){
  if((event==='request'||event==='upgrade')&&args[0]?.url){
   const request=args[0],prefix='/services/bumpball';
   if(request.url===prefix||request.url.startsWith(prefix+'/')||request.url.startsWith(prefix+'?')){
    request.url=request.url.slice(prefix.length)||'/';if(request.url[0]==='?')request.url='/'+request.url;
   }
  }
  return super.emit(event,...args);
 }
}

export async function createBumpBallServer({geometry,geometryPath=path.join(moduleDir,'stage_geometry.json'),staticDir=process.env.BUMPBALL_STATIC_DIR==='off'?null:process.env.BUMPBALL_STATIC_DIR||path.resolve(moduleDir,'../../dist'),roomOptions={}}={}){
 const stage=geometry||JSON.parse(await fs.readFile(geometryPath,'utf8'));
 const httpServer=new BumpBallHTTPServer();
 const gameServer=new Server({
  transport:new WebSocketTransport({server:httpServer,maxPayload:32*1024,pingInterval:4000,pingMaxRetries:2}),greet:false,gracefullyShutdown:false,
  express:app=>{
   app.disable('x-powered-by');const health=(_request,response)=>response.set('Cache-Control','no-store').json(identity);
   app.get(['/healthz','/service/healthz','/ball-island/health','/games/bumpball/health'],health);
   if(staticDir){
    const serve=express.static(path.resolve(staticDir),{dotfiles:'deny',index:'index.html',redirect:true,fallthrough:true,setHeaders(response,file){response.setHeader('X-Game-Id',identity.appId);response.setHeader('X-Content-Type-Options','nosniff');response.setHeader('Cache-Control',file.endsWith('.html')?'no-store':'public, max-age=3600')}});
    app.get('/',(_request,response)=>response.redirect(302,'/ball-island/'));
    app.get(/^\/ball-island$/,(_request,response)=>response.redirect(302,'/ball-island/'));
    app.get(/^\/games\/bumpball$/,(_request,response)=>response.redirect(302,'/games/bumpball/'));
    app.use('/ball-island',serve);app.use('/games/bumpball',serve);
   }
   app.use((_request,response)=>response.status(404).type('text/plain').send('未找到游戏文件或联机接口'));
  },
 });
 const RoomClass=makeBumpBallRoom({createSimulation:()=>GameSimulation.create({geometry:stage}),...roomOptions});
 gameServer.define(MULTIPLAYER_ROOM,RoomClass);gameServer.bumpball={RoomClass,identity,httpServer};return gameServer;
}

export async function startBumpBallServer({host=process.env.HOST||'127.0.0.1',port=Number(process.env.PORT||54127),...options}={}){
 if(!Number.isInteger(port)||port<0||port>65535)throw Error('PORT must be an integer from 0 to 65535');
 const server=await createBumpBallServer(options);await server.listen(port,host);return server;
}
export function installShutdown(server){let stopping=false;const stop=async()=>{if(stopping)return;stopping=true;await server.gracefullyShutdown(false)};process.once('SIGINT',stop);process.once('SIGTERM',stop)}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){startBumpBallServer().then(server=>{console.log(`海岛碰碰球联机服务：http://${process.env.HOST||'127.0.0.1'}:${server.bumpball.httpServer.address().port}/ball-island/`);installShutdown(server)}).catch(error=>{console.error(error);process.exitCode=1})}
