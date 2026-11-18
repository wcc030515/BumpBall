import {startBumpBallServer,installShutdown} from './server/dist/index.js';

startBumpBallServer().then(server=>{
  console.log(`海岛碰碰球 HTML 版：http://${process.env.HOST||'127.0.0.1'}:${server.bumpball.httpServer.address().port}/ball-island/`);
  installShutdown(server);
}).catch(error=>{
  console.error(error);
  process.exitCode=1;
});
