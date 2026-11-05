import * as THREE from 'three';
// Approved B preview faded at 3 seconds. Aging at 75% gives a 4-second lifetime.
export const SLOW_MARK_FADE_RATE = .75;
export const SLOW_MARK_LIFETIME = 3 / SLOW_MARK_FADE_RATE;
// Five radii from the centre leaves about two ball diameters behind its rear.
export const SLOW_MARK_LENGTH_IN_RADII = 5;
const MAX_MARKS = 64;
type Mark = {
    x: number;
    z: number;
    dx: number;
    dz: number;
    scale: number;
    age: number;
    travel: number;
};
const vertex = `
attribute vec4 aPose;
attribute vec3 aScaleAge;
varying vec2 vLocal;
varying vec2 vGround;
varying float vAge;
varying float vTailOpacity;
void main(){
 vLocal=position.xy*1.3;
 vec2 forward=aPose.zw,across=vec2(forward.y,-forward.x);
 vec2 point=aPose.xy+(across*vLocal.x*.37+forward*vLocal.y*.17)*aScaleAge.x;
 vGround=point;vAge=aScaleAge.y;vTailOpacity=aScaleAge.z;
 gl_Position=projectionMatrix*modelViewMatrix*vec4(point.x,.028,point.y,1.);
}`;
const fragment = `
uniform float fadeRate;
varying vec2 vLocal;
varying vec2 vGround;
varying float vAge;
varying float vTailOpacity;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float noise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1)),f.x),f.y);}
void main(){
 float r=length(vLocal);
 float edge=1.-smoothstep(.36,1.16,r+noise(vGround*21.)*.16);
 float alpha=edge*(1.-smoothstep(.9,3.,vAge*fadeRate))*vTailOpacity*.52;
 if(alpha<.002)discard;
 gl_FragColor=vec4(vec3(.12,.055,.015),alpha);
 #include <colorspace_fragment>
}`;
/** Soft, broad oval imprints placed along the actual path on the XZ ground. */
export class SlowdownMarks {
    readonly mesh: THREE.Mesh<THREE.InstancedBufferGeometry, THREE.ShaderMaterial>;
    private readonly marks: Mark[] = [];
    private readonly poses = new THREE.InstancedBufferAttribute(new Float32Array(MAX_MARKS * 4), 4).setUsage(THREE.DynamicDrawUsage);
    private readonly scaleAges = new THREE.InstancedBufferAttribute(new Float32Array(MAX_MARKS * 3), 3).setUsage(THREE.DynamicDrawUsage);
    private readonly previous = new THREE.Vector2();
    private emitting = false;
    private hasPrevious = false;
    private distance = 0;
    private travelled = 0;
    private radius = .7;
    constructor(scene: THREE.Scene) {
        const plane = new THREE.PlaneGeometry(2, 2), geometry = new THREE.InstancedBufferGeometry();
        geometry.setIndex(plane.index!.clone());
        geometry.setAttribute('position', plane.getAttribute('position').clone());
        plane.dispose();
        geometry.setAttribute('aPose', this.poses);
        geometry.setAttribute('aScaleAge', this.scaleAges);
        geometry.instanceCount = 0;
        const material = new THREE.ShaderMaterial({ vertexShader: vertex, fragmentShader: fragment, transparent: true, depthWrite: false, toneMapped: false, side: THREE.DoubleSide, uniforms: { fadeRate: { value: SLOW_MARK_FADE_RATE } } });
        this.mesh = new THREE.Mesh(geometry, material);
        this.mesh.name = 'slowdown-soft-imprints';
        this.mesh.frustumCulled = false;
        this.mesh.renderOrder = 1;
        this.mesh.visible = false;
        this.mesh.userData = { scheme: 'B-soft-imprints', fadeRate: SLOW_MARK_FADE_RATE, lifetime: SLOW_MARK_LIFETIME, maxLengthInRadii: SLOW_MARK_LENGTH_IN_RADII };
        scene.add(this.mesh);
    }
    record(at: THREE.Vector3, velocity: THREE.Vector3, active: boolean, radius: number) {
        const point = new THREE.Vector2(at.x, at.z);
        const scale = Math.max(.1, radius / .7), spacing = Math.max(.22, .31 * scale);
        const segment = this.hasPrevious ? point.clone().sub(this.previous) : new THREE.Vector2(), length = segment.length();
        if (length > 2.5 * scale)
            this.clear();
        this.radius = radius;
        const step = this.hasPrevious ? length : 0, startTravel = this.travelled;
        this.travelled += step;
        this.hasPrevious = true;
        if (!active) {
            this.emitting = false;
            this.distance = 0;
            this.previous.copy(point);
            return;
        }
        const direction = new THREE.Vector2(velocity.x, velocity.z).normalize();
        if (direction.lengthSq() < .001) {
            this.emitting = false;
            this.distance = 0;
            this.previous.copy(point);
            return;
        }
        if (!this.emitting) {
            this.emitting = true;
            this.previous.copy(point);
            this.distance = 0;
            this.add(point, direction, scale);
            return;
        }
        if (step > .00001) {
            // Interpolate along travelled distance, so faster frames do not leave gaps.
            this.distance %= spacing;
            for (let along = spacing - this.distance; along <= step + 1e-6; along += spacing)
                this.add(this.previous.clone().addScaledVector(segment, Math.min(1, along / step)), direction, scale, startTravel + along);
            this.distance = (this.distance + step) % spacing;
        }
        this.previous.copy(point);
    }
    update(dt: number) {
        if (dt <= 0)
            return;
        for (let i = this.marks.length - 1; i >= 0; i--) {
            const mark = this.marks[i];
            mark.age += dt;
            if (mark.age >= SLOW_MARK_LIFETIME || this.travelled - mark.travel >= this.lengthBudget(mark))
                this.marks.splice(i, 1);
        }
        this.marks.forEach((mark, i) => {
            const behind = this.travelled - mark.travel, budget = this.lengthBudget(mark);
            const tailOpacity = Math.pow(1 - THREE.MathUtils.smoothstep(behind, budget * .15, budget), 1.35);
            this.poses.setXYZW(i, mark.x, mark.z, mark.dx, mark.dz);
            this.scaleAges.setXYZ(i, mark.scale, mark.age, tailOpacity);
        });
        this.poses.needsUpdate = true;
        this.scaleAges.needsUpdate = true;
        this.mesh.geometry.instanceCount = this.marks.length;
        this.mesh.visible = this.marks.length > 0;
    }
    clear() { this.marks.length = 0; this.emitting = false; this.hasPrevious = false; this.distance = 0; this.travelled = 0; this.mesh.geometry.instanceCount = 0; this.mesh.visible = false; }
    dispose() { this.clear(); this.mesh.removeFromParent(); this.mesh.geometry.dispose(); this.mesh.material.dispose(); }
    private lengthBudget(mark: Mark) { return Math.max(.01, this.radius * SLOW_MARK_LENGTH_IN_RADII - .22 * mark.scale); }
    private add(point: THREE.Vector2, direction: THREE.Vector2, scale: number, travel = this.travelled) {
        if (this.marks.length === MAX_MARKS)
            this.marks.shift();
        this.marks.push({ x: point.x, z: point.y, dx: direction.x, dz: direction.y, scale, age: 0, travel });
    }
}
