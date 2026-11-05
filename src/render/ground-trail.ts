import * as THREE from 'three';
export type GroundTrailSample = {
    p: THREE.Vector3;
    age: number;
    life: number;
    width: number;
    strength: number;
};
const MAX_NODES = 32;
const screenPoint = (p: THREE.Vector3, camera: THREE.PerspectiveCamera) => { const q = p.clone().project(camera); return new THREE.Vector2(q.x * camera.aspect, -q.y); };
const projectionScale = (p: THREE.Vector3, camera: THREE.PerspectiveCamera) => 1 / (Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2) * Math.max(.1, -p.clone().applyMatrix4(camera.matrixWorldInverse).z));
export function pathDistance(a: THREE.Vector3, b: THREE.Vector3, camera?: THREE.PerspectiveCamera) { return camera ? screenPoint(a, camera).distanceTo(screenPoint(b, camera)) / projectionScale(a, camera) : a.distanceTo(b); }
const vertex = `
uniform float uAspect;
uniform bool uProjected;
varying vec3 vProjection;
varying vec2 vGround;
void main(){
 vec4 world=modelMatrix*vec4(position,1.);
 vec4 clip=projectionMatrix*viewMatrix*world;
 vProjection=uProjected?vec3(clip.x*uAspect,-clip.y,clip.w):vec3(world.xz,1.);
 vGround=world.xz;
 gl_Position=clip;
}`;
const fragment = `
uniform int uCount;
uniform vec4 uNodes[${MAX_NODES}];
uniform float uOpacity[${MAX_NODES}];
varying vec3 vProjection;
varying vec2 vGround;
float hash(vec2 p){return fract(sin(dot(p,vec2(123.34,456.21)))*45678.9123);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1.,0.)),f.x),mix(hash(i+vec2(0.,1.)),hash(i+vec2(1.,1.)),f.x),f.y);}
void main(){
 vec2 p=vProjection.xy/vProjection.z;
 float alpha=0.;
 for(int i=0;i<${MAX_NODES - 1};i++){
  if(i+1>=uCount)break;
  vec4 a=uNodes[i],b=uNodes[i+1];
  vec2 segment=b.xy-a.xy;
  float t=clamp(dot(p-a.xy,segment)/max(dot(segment,segment),.00000001),0.,1.);
  vec4 node=mix(a,b,t);
  vec2 delta=(p-node.xy)/max(node.z,.00001);
  float along=(node.w-.4)/.6;
  float r2=dot(delta,delta)+along*along;
  float soft=exp(-1.5*r2)*(1.-smoothstep(.4,1.08,sqrt(r2)));
  float opacity=mix(uOpacity[i],uOpacity[i+1],t)*smoothstep(0.,.14,node.w);
  // Union the soft footprint once. Crossing paths never stack opaque triangles.
  alpha=max(alpha,soft*opacity);
 }
 alpha*=.8+.2*noise(vGround*4.);
 gl_FragColor=vec4(vec3(.87,.78,.60),alpha);
 #include <tonemapping_fragment>
 #include <colorspace_fragment>
}`;
/** A soft distance field on one ground quad, rather than a folding ribbon.
 * The visible silhouette comes from distance to the rolling path. Its carrier
 * quad extends beyond the zero-alpha boundary, including at tight hairpins. */
export class GroundTrail extends THREE.Mesh<THREE.BufferGeometry, THREE.ShaderMaterial> {
    constructor() {
        const geometry = new THREE.BufferGeometry();
        geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(12), 3));
        geometry.setIndex([0, 1, 2, 0, 2, 3]);
        super(geometry, new THREE.ShaderMaterial({ vertexShader: vertex, fragmentShader: fragment, transparent: true, depthWrite: false, side: THREE.DoubleSide, uniforms: { uAspect: { value: 1 }, uProjected: { value: false }, uCount: { value: 0 }, uNodes: { value: Array.from({ length: MAX_NODES }, () => new THREE.Vector4()) }, uOpacity: { value: new Float32Array(MAX_NODES) } } }));
        this.frustumCulled = false;
        this.renderOrder = 1;
        this.visible = false;
    }
    updateTrail(samples: GroundTrailSample[], camera?: THREE.PerspectiveCamera) {
        if (samples.length < 2) {
            this.visible = false;
            return;
        }
        const distances = [0];
        for (let i = 1; i < samples.length; i++)
            distances.push(distances[i - 1] + pathDistance(samples[i].p, samples[i - 1].p, camera));
        const total = distances.at(-1)!;
        if (total < .001) {
            this.visible = false;
            return;
        }
        const count = Math.min(MAX_NODES, samples.length), uniforms = this.material.uniforms, nodes = uniforms.uNodes.value as THREE.Vector4[], opacity = uniforms.uOpacity.value as Float32Array;
        const groundY = Math.max(...samples.map(s => s.p.y));
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        for (let i = 0; i < count; i++) {
            const index = Math.round(i * (samples.length - 1) / (count - 1)), s = samples[index], p = s.p.clone();
            p.y = groundY;
            const point = camera ? screenPoint(p, camera) : new THREE.Vector2(p.x, p.z), radius = s.width * .5 * 1.35 * (camera ? projectionScale(p, camera) : 1);
            nodes[i].set(point.x, point.y, radius, distances[index] / total);
            opacity[i] = s.strength * (1 - THREE.MathUtils.smoothstep(s.age / s.life, .82, 1));
            const margin = radius * 1.15;
            minX = Math.min(minX, point.x - margin);
            maxX = Math.max(maxX, point.x + margin);
            minY = Math.min(minY, point.y - margin);
            maxY = Math.max(maxY, point.y + margin);
        }
        const position = this.geometry.getAttribute('position') as THREE.BufferAttribute;
        for (const [i, [x, y]] of [[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]].entries()) {
            let p = new THREE.Vector3(x, groundY, y);
            if (camera) {
                const ray = new THREE.Vector3(x / camera.aspect, -y, 0).unproject(camera).sub(camera.position);
                if (Math.abs(ray.y) < 1e-6) {
                    this.visible = false;
                    return;
                }
                p = ray.multiplyScalar((groundY - camera.position.y) / ray.y).add(camera.position);
            }
            position.setXYZ(i, p.x, p.y, p.z);
        }
        position.needsUpdate = true;
        uniforms.uCount.value = count;
        uniforms.uAspect.value = camera?.aspect || 1;
        uniforms.uProjected.value = !!camera;
        this.visible = true;
    }
}
