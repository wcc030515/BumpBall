import * as THREE from 'three';
import { GroundTrail, pathDistance, type GroundTrailSample as Sample } from './ground-trail';
import { SlowdownMarks } from './slowdown-marks';
// Native v1.0.27: broadly feathered ground ribbon, boost-only transient dust,
// separate slow-mode sweat/friction. Trails/dust stay in world space; sweat is
// attached to its owner's head anchor so it cannot be left behind by movement.
const dustFragment = `uniform float opacity;uniform float progress;uniform float variation;varying vec2 vUv;float lobe(vec2 p,vec2 c,float r){return 1.-smoothstep(r*.54,r,length(p-c));}void main(){vec2 p=vec2((vUv.x-.5)*2.,(.5-vUv.y)*2.);p.x+=sin(p.y*7.+variation+progress*2.7)*.035;float cloud=max(max(lobe(p,vec2(-.26,-.12),.60),lobe(p,vec2(.23,-.12),.64)),max(lobe(p,vec2(.02,.23),.57),max(lobe(p,vec2(-.36,.15),.38),lobe(p,vec2(.40,.17),.35))));vec3 ink=mix(vec3(.34,.29,.24),vec3(.88,.82,.71),smoothstep(-.75,.53,p.y+p.x*.16));ink*=mix(.82,1.,smoothstep(0.,.65,cloud));gl_FragColor=vec4(ink,cloud*opacity);
#include <tonemapping_fragment>
#include <colorspace_fragment>
}`;
const dustVertex = `uniform vec3 travelDirection;varying vec2 vUv;void main(){vUv=uv;vec4 center=modelViewMatrix*vec4(0.,0.,0.,1.);vec3 scale=vec3(length(modelMatrix[0].xyz),length(modelMatrix[1].xyz),length(modelMatrix[2].xyz));vec2 projected=(viewMatrix*vec4(travelDirection,0.)).xy;vec2 behind=length(projected)>.0001?-normalize(projected):vec2(0.,1.);vec2 across=vec2(behind.y,-behind.x);center.xy+=across*position.x*scale.x+behind*position.y*scale.y;gl_Position=projectionMatrix*center;}`;
type Puff = {
    mesh: THREE.Mesh<THREE.PlaneGeometry, THREE.ShaderMaterial>;
    age: number;
    life: number;
    velocity: THREE.Vector3;
    size: number;
    alpha: number;
};
type Fleck = {
    mesh: THREE.Mesh;
    age: number;
    life: number;
    velocity: THREE.Vector3;
    kind: 'sweat';
};
export class MovementEffects {
    private trail = new GroundTrail();
    private samples: Sample[] = [];
    private puffs: Puff[] = [];
    private flecks: Fleck[] = [];
    private emission = 0;
    private sweatClock = 0;
    private last = new THREE.Vector3();
    private hasLast = false;
    private readonly slowMarks: SlowdownMarks;
    private readonly sweatAnchor = new THREE.Group();
    private camera?: THREE.PerspectiveCamera;
    private plane = new THREE.PlaneGeometry(1, 1);
    private sweatGeo = new THREE.SphereGeometry(.075, 8, 6);
    constructor(readonly scene: THREE.Scene) { this.slowMarks = new SlowdownMarks(scene); this.trail.renderOrder = 1; this.trail.frustumCulled = false; scene.add(this.trail, this.sweatAnchor); for (let i = 0; i < 40; i++) {
        const mat = new THREE.ShaderMaterial({ vertexShader: dustVertex, fragmentShader: dustFragment, transparent: true, depthWrite: false, uniforms: { opacity: { value: 0 }, progress: { value: 0 }, variation: { value: Math.random() * 17 }, travelDirection: { value: new THREE.Vector3(0, 0, 1) } } });
        const mesh = new THREE.Mesh(this.plane, mat);
        mesh.visible = false;
        mesh.renderOrder = 2;
        scene.add(mesh);
        this.puffs.push({ mesh, age: -1, life: .35, velocity: new THREE.Vector3(), size: .55, alpha: .75 });
    } }
    update(at: THREE.Vector3, v: THREE.Vector3, yaw: number, head: THREE.Vector3, mode: string, dt: number, radius: number, camera?: THREE.PerspectiveCamera) {
        if (dt <= 0)
            return;
        this.camera = camera;
        const speed = Math.hypot(v.x, v.z), scale = Math.max(.1, radius / .7);
        let moved = this.hasLast ? at.distanceTo(this.last) : 0;
        if (moved > 2.5 * scale) {
            this.clear();
            moved = 0;
        }
        this.last.copy(at);
        this.hasLast = true;
        this.sweatAnchor.position.copy(head);
        this.sweatAnchor.rotation.y = yaw;
        this.sweatAnchor.scale.setScalar(1);
        const moving = speed > .12 && mode !== 'idle';
        const direction = new THREE.Vector3(v.x, 0, v.z).normalize(), contact = at.clone();
        contact.y -= radius;
        const projectedSpeed = camera ? speed * THREE.MathUtils.clamp(pathDistance(contact.clone().add(direction), contact, camera), .18, 1.2) : speed;
        this.samples.forEach(s => s.age += dt);
        this.samples = this.samples.filter(s => s.age < s.life);
        if (moving && mode !== 'slow') {
            const boost = mode === 'boost';
            if (!this.samples.length || this.samples[0].p.distanceTo(contact) > .045 * scale) {
                const p = contact.clone();
                p.y = .018 * scale;
                this.samples.unshift({ p, age: 0, life: THREE.MathUtils.clamp((boost ? 2.8 : 2.25) * scale / Math.max(projectedSpeed, .5), .24, 1.1), width: (THREE.MathUtils.clamp(.56 + speed / 5.8 * .07, .56, .68) + (boost ? .09 : 0)) * (boost ? 3 : 1) * scale, strength: boost ? .66 : .54 });
            }
            let total = 0;
            for (let i = 1; i < this.samples.length; i++) {
                total += pathDistance(this.samples[i].p, this.samples[i - 1].p, camera);
                if (total > (boost ? 2.25 : 1.75) * scale) {
                    this.samples.length = i + 1;
                    break;
                }
            }
            if (boost) {
                this.emission += dt * THREE.MathUtils.clamp(8 + speed * 1.55, 11, 25);
                while (this.emission >= 1) {
                    this.emission--;
                    const p = this.puffs.find(p => p.age < 0) || this.puffs.reduce((a, b) => a.age > b.age ? a : b);
                    p.mesh.material.uniforms.travelDirection.value.copy(direction);
                    p.age = 0;
                    p.life = THREE.MathUtils.clamp(2.9 * scale / Math.max(speed, .5), .25, .5) * (.91 + Math.random() * .18);
                    p.size = (.47 + Math.random() * .12) * scale;
                    p.alpha = .66 + Math.random() * .18;
                    const side = new THREE.Vector3(direction.z, 0, -direction.x);
                    p.mesh.position.copy(contact).addScaledVector(direction, -(.1 + Math.random() * .14) * scale).addScaledVector(side, (Math.random() - .5) * .3 * scale);
                    p.mesh.position.y = .36 * scale;
                    p.velocity.copy(direction).multiplyScalar(-(.1 + Math.random() * .2)).addScaledVector(side, (Math.random() - .5) * .36);
                    p.velocity.y = .22 + Math.random() * .16;
                    p.mesh.visible = true;
                }
            }
            else
                this.emission = 0;
        }
        else
            this.emission = 0;
        if (mode === 'slow') {
            this.sweatClock += dt;
            if (this.sweatClock > .23) {
                this.sweatClock = 0;
                for (const side of [-1, 1]) {
                    const mesh = new THREE.Mesh(this.sweatGeo, new THREE.MeshStandardMaterial({ color: '#46c9f0', roughness: .2, transparent: true }));
                    mesh.position.set(side * .085, .13, -.42);
                    mesh.scale.set(.8, 1.35, .8);
                    mesh.renderOrder = 2;
                    this.sweatAnchor.add(mesh);
                    this.flecks.push({ mesh, age: 0, life: .58, velocity: new THREE.Vector3(side * .045, .22, -.055), kind: 'sweat' });
                }
            }
        }
        else {
            this.sweatClock = 0;
        }
        this.slowMarks.record(contact, v, mode === 'slow' && moving, radius);
        this.rebuild();
    }
    private rebuild() { this.trail.updateTrail(this.samples, this.camera); }
    animate(dt: number) { if (dt <= 0)
        return; this.slowMarks.update(dt); for (const p of this.puffs) {
        if (p.age < 0)
            continue;
        p.age += dt;
        const t = p.age / p.life;
        if (t >= 1) {
            p.age = -1;
            p.mesh.visible = false;
            continue;
        }
        p.mesh.position.addScaledVector(p.velocity, dt);
        p.mesh.scale.setScalar(p.size * (.72 + t * .7) * 1.6);
        p.mesh.material.uniforms.opacity.value = p.alpha * THREE.MathUtils.smoothstep(t, 0, .13) * (1 - THREE.MathUtils.smoothstep(t, .3, 1));
        p.mesh.material.uniforms.progress.value = t;
    } for (let i = this.flecks.length - 1; i >= 0; i--) {
        const f = this.flecks[i];
        f.age += dt;
        if (f.age >= f.life) {
            f.mesh.removeFromParent();
            (f.mesh.material as THREE.Material).dispose();
            this.flecks.splice(i, 1);
            continue;
        }
        const t = f.age / f.life;
        f.velocity.y -= 1.8 * dt;
        f.mesh.position.addScaledVector(f.velocity, dt);
        (f.mesh.material as THREE.MeshBasicMaterial).opacity = 1 - t;
    } }
    clear() { this.slowMarks.clear(); this.samples = []; this.trail.visible = false; this.hasLast = false; this.emission = 0; for (const p of this.puffs) {
        p.age = -1;
        p.mesh.visible = false;
    } for (const f of this.flecks) {
        f.mesh.removeFromParent();
        (f.mesh.material as THREE.Material).dispose();
    } this.flecks = []; }
    dispose() { this.clear(); this.slowMarks.dispose(); this.sweatAnchor.removeFromParent(); this.trail.removeFromParent(); this.trail.geometry.dispose(); this.trail.material.dispose(); for (const p of this.puffs) {
        p.mesh.removeFromParent();
        p.mesh.material.dispose();
    } this.plane.dispose(); this.sweatGeo.dispose(); }
}
