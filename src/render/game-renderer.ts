import * as THREE from 'three';
import { GLTFLoader, type GLTF } from 'three/addons/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';
import { clone as cloneSkeleton } from 'three/addons/utils/SkeletonUtils.js';
import { Sky } from 'three/addons/objects/Sky.js';
import { Ocean } from './ocean';
import { MovementEffects } from './movement-effects';
import { CollisionSparks } from './collision-sparks';
import { PRIMARY_COLORS, PRIMARY_SOURCE_LUMINANCE, characterPrimaryColor } from '../character-colors';
import { assetUrl } from '../asset-url';
import { applyPrimaryColorMaterials, configureAnimalTextureSampling } from './primary-color';
import { ConfusionEffect } from './confusion-effect';
import { classifyCollisionFeedback } from '../collision-feedback';
import type { PlayerConfig, EntitySnapshot, Snapshot } from '../simulation';
export type CameraScope = 'match' | 'victory';
export interface CameraSettings {
    height: number;
    distance: number;
    fov: number;
    yaw: number;
    azimuth?: number;
}
export interface RenderOptions {
    screen: 'menu' | 'playing' | 'finished';
    paused: boolean;
    dt: number;
    elapsed: number;
    selected: PlayerConfig;
    cameraScope?: CameraScope | null;
    previewYaw?: number;
    interpolate?: boolean;
}
export const ANIMALS = ['rabbit', 'bear', 'hamster', 'cat', 'dog', 'fox', 'panda', 'raccoon'] as const;
const BASE_RADIUS = .7, MODEL_SCALE = .7 / .82;
const INKS: Record<string, string> = { rabbit: '#173e69', bear: '#a86663', hamster: '#b47a35', cat: '#5f8e69', dog: '#a78337', fox: '#88709e', panda: '#514a50', raccoon: '#676e8c' };
export { assetUrl } from '../asset-url';
const clamp = THREE.MathUtils.clamp;
const smooth = (x: number) => { x = clamp(x, 0, 1); return x * x * (3 - 2 * x); };
const angleLerp = (a: number, b: number, t: number) => a + Math.atan2(Math.sin(b - a), Math.cos(b - a)) * t;
function entityPos(e: EntitySnapshot): THREE.Vector3 { const p = (e as unknown as {
    pos?: {
        x: number;
        y: number;
        z: number;
    };
}).pos; return new THREE.Vector3(p?.x ?? (e as unknown as {
    x: number;
}).x, p?.y ?? (e as unknown as {
    y: number;
}).y, p?.z ?? (e as unknown as {
    z: number;
}).z); }
function entityVel(e: EntitySnapshot): THREE.Vector3 { const v = (e as unknown as {
    vel?: {
        x: number;
        y: number;
        z: number;
    };
}).vel; return new THREE.Vector3(v?.x ?? (e as unknown as {
    vx: number;
}).vx ?? 0, v?.y ?? 0, v?.z ?? (e as unknown as {
    vz: number;
}).vz ?? 0); }
/** Native import accepted a downward-facing two-sided turf surface. In WebGL,
 * shadow normal bias follows the vertex normal before back-face lighting flips it,
 * which puts the entire meadow in its own shadow. Correct winding/normals only in
 * the browser copy; the approved GLB bytes and gameplay outline stay unchanged. */
function correctArenaSurface(mesh: THREE.Mesh) {
    mesh.geometry = mesh.geometry.clone();
    const index = mesh.geometry.index;
    if (!index)
        return;
    for (let i = 0; i < index.count; i += 3) {
        const b = index.getX(i + 1);
        index.setX(i + 1, index.getX(i + 2));
        index.setX(i + 2, b);
    }
    index.needsUpdate = true;
    // computeVertexNormals() accumulates in the existing attribute array, which
    // must be floating point. Mesh compression may deliver normalized Int16 data.
    // Recreate these derived attributes before fixing the two-sided turf winding.
    mesh.geometry.deleteAttribute('normal');
    mesh.geometry.deleteAttribute('tangent');
    mesh.geometry.computeVertexNormals();
    if (mesh.geometry.getAttribute('uv'))
        mesh.geometry.computeTangents();
}
class AnimalView {
    readonly root = new THREE.Group();
    readonly ballRoot = new THREE.Group();
    readonly body = new THREE.Group();
    readonly mixer: THREE.AnimationMixer;
    readonly model: THREE.Object3D;
    readonly effects: MovementEffects;
    private confusion?: ConfusionEffect;
    readonly bubble: HTMLDivElement;
    readonly sphere: THREE.Mesh;
    readonly actions: Record<string, THREE.AnimationAction> = {};
    readonly head: THREE.Object3D | undefined;
    readonly spine: THREE.Object3D | undefined;
    readonly lifering = new THREE.Group();
    private currentClip = '';
    private floating = false;
    private floatTime = 0;
    private startYaw = 0;
    private turnYaw = 0;
    private floatAnchor = new THREE.Vector3();
    private sinkStart = 0;
    private bodyStart = 0;
    private headHeight = 2.1;
    private hasRenderedPosition = false;
    private headRestY = 0;
    private role = '';
    private scale = 1;
    private customMaterials: THREE.Material[] = [];
    private readonly usesSharedAnimalRig: boolean;
    private primarySetters: Array<(hex: string) => void> = [];
    private primaryHex = '';
    constructor(public config: PlayerConfig, asset: GLTF, paw: THREE.Texture, mask: THREE.Texture, scene: THREE.Scene, labels: HTMLElement, private readonly waterHeight: (x: number, z: number) => number) {
        let sharedRig = !!asset.scene.getObjectByName('Cat_Rig_Forward');
        asset.scene.traverse(o => { if (o.userData.common_animal_asset === true || o.name.startsWith('NewCommonAnimal_Rig_'))
            sharedRig = true; });
        this.usesSharedAnimalRig = sharedRig;
        this.model = cloneSkeleton(asset.scene);
        this.model.scale.setScalar(MODEL_SCALE);
        this.model.position.y = -1.64 * MODEL_SCALE;
        this.model.traverse(o => { if (/Ball_Independent/.test(o.name))
            o.visible = false; if (o instanceof THREE.Mesh) {
            o.castShadow = true;
            o.receiveShadow = true;
            o.frustumCulled = false;
        } });
        const paint = applyPrimaryColorMaterials(this.model, mask, PRIMARY_COLORS[config.animal], PRIMARY_SOURCE_LUMINANCE[config.animal]);
        this.customMaterials.push(...paint.materials);
        this.primarySetters.push(paint.setColor);
        this.body.add(this.model);
        this.root.add(this.body, this.ballRoot);
        scene.add(this.root);
        this.mixer = new THREE.AnimationMixer(this.model);
        asset.animations.forEach(clip => { this.actions[clip.name] = this.mixer.clipAction(clip); });
        this.head = this.model.getObjectByName('head');
        this.spine = this.model.getObjectByName('spine');
        this.model.updateMatrixWorld(true);
        const bounds = new THREE.Box3();
        this.model.traverse(o => { if (o instanceof THREE.Mesh && o.visible && !/Ball_Independent/.test(o.name))
            bounds.expandByObject(o); });
        this.headHeight = Math.max(1.25, bounds.max.y - this.root.position.y);
        const material = new THREE.MeshStandardMaterial({ color: '#173e69', roughness: .39, metalness: .015 });
        const uniforms = { base: { value: new THREE.Color('#173e69') }, ink: { value: new THREE.Color('#173e69') }, paw: { value: paw } };
        material.onBeforeCompile = s => {
            Object.assign(s.uniforms, { uBallBase: uniforms.base, uPawInk: uniforms.ink, uPawMask: uniforms.paw });
            s.vertexShader = 'varying vec3 vBallLocal;\n' + s.vertexShader;
            s.vertexShader = s.vertexShader.replace('#include <begin_vertex>', '#include <begin_vertex>\nvBallLocal=position;');
            s.fragmentShader = 'uniform vec3 uBallBase;uniform vec3 uPawInk;uniform sampler2D uPawMask;varying vec3 vBallLocal;\n' + s.fragmentShader;
            s.fragmentShader = s.fragmentShader.replace('#include <color_fragment>', `#include <color_fragment>
   vec3 sphere=normalize(vBallLocal);float rear=sphere.z<0.0?-1.0:1.0;
   vec2 disk=vec2(sphere.x*rear,-sphere.y)/0.8;
   float medallion=1.0-smoothstep(.99,1.01,length(disk));
   float ink=texture2D(uPawMask,disk*.5+.5).a*medallion;
   diffuseColor.rgb=mix(mix(uBallBase,vec3(.98,.969,.937),medallion),uPawInk,ink);`);
        };
        material.userData.ballUniforms = uniforms;
        this.customMaterials.push(material);
        this.sphere = new THREE.Mesh(new THREE.SphereGeometry(BASE_RADIUS, 48, 32), material);
        this.sphere.castShadow = true;
        this.sphere.receiveShadow = true;
        this.ballRoot.add(this.sphere);
        const ringMat = new THREE.MeshStandardMaterial({ color: '#ffb85a', roughness: .43 });
        const ropeMat = new THREE.MeshStandardMaterial({ color: '#fff0cf', roughness: .58 });
        this.customMaterials.push(ringMat, ropeMat);
        const ring = new THREE.Mesh(new THREE.TorusGeometry(.425, .14, 12, 48), ringMat);
        ring.rotation.x = -Math.PI / 2;
        ring.position.y = .43;
        ring.castShadow = true;
        this.lifering.add(ring);
        const rope = new THREE.Mesh(new THREE.TorusGeometry(.565, .012, 6, 48), ropeMat);
        rope.rotation.x = -Math.PI / 2;
        rope.position.y = .445;
        this.lifering.add(rope);
        for (const s of [-1, 1]) {
            const h = new THREE.Mesh(new THREE.TorusGeometry(.071, .012, 6, 16), ropeMat);
            h.rotation.x = -Math.PI / 2;
            h.position.set(s * .59, .43, 0);
            this.lifering.add(h);
        }
        this.lifering.visible = false;
        this.body.add(this.lifering);
        this.effects = new MovementEffects(scene);
        this.bubble = document.createElement('div');
        this.bubble.className = 'world-name-bubble';
        Object.assign(this.bubble.style, { position: 'absolute', pointerEvents: 'none', font: '700 12px/1.25 "Microsoft YaHei",sans-serif', padding: '4px 9px', borderRadius: '8px', color: '#fff', textShadow: '0 1px 1px #0004', whiteSpace: 'nowrap', boxShadow: '0 1px 3px #0002', transform: 'translate(-50%,-100%)', transformOrigin: '50% 100%' });
        const tip = document.createElement('span');
        Object.assign(tip.style, { position: 'absolute', width: '0', height: '0', left: 'calc(50% - 4px)', bottom: '-4px', borderLeft: '4px solid transparent', borderRight: '4px solid transparent', borderTop: '5px solid var(--bubble-color)' });
        this.bubble.append(tip);
        labels.append(this.bubble);
        this.play('ready_balance');
        this.mixer.update(0);
        this.model.updateMatrixWorld(true);
        if (this.head)
            this.headRestY = this.body.worldToLocal(this.head.getWorldPosition(new THREE.Vector3())).y;
    }
    setPrimaryColor() { const hex = characterPrimaryColor(this.config); if (hex === this.primaryHex)
        return; this.primaryHex = hex; this.primarySetters.forEach(set => set(hex)); }
    private play(name: string) { if (name === this.currentClip)
        return; const next = this.actions[name]; if (!next)
        return; Object.values(this.actions).forEach(a => { if (a !== next)
        a.fadeOut(.13); }); next.reset().setEffectiveWeight(1).fadeIn(.13).play(); this.currentClip = name; }
    setRole(local: boolean) {
        const role = local ? 'local' : this.config.human ? 'opponent' : 'npc';
        if (role === this.role)
            return;
        this.role = role;
        const base = role === 'local' ? '#173e69' : role === 'opponent' ? '#8f2936' : this.config.ball.colors[0] || '#efb8b0';
        (this.sphere.material as THREE.MeshStandardMaterial).color.set(base);
        const u = (this.sphere.material as THREE.MeshStandardMaterial).userData.ballUniforms;
        u.base.value.set(base);
        u.ink.value.set(role === 'npc' ? INKS[this.config.animal] || '#173e69' : base);
        const color = role === 'local' ? 'rgba(49,125,196,.7)' : role === 'opponent' ? 'rgba(201,72,72,.7)' : 'rgba(221,172,45,.7)';
        this.bubble.style.background = color;
        this.bubble.style.setProperty('--bubble-color', color);
        this.bubble.style.color = role === 'npc' ? '#574524' : '#fff';
        this.bubble.insertBefore(document.createTextNode(local ? '你' : this.config.name), this.bubble.firstChild);
        while (this.bubble.childNodes.length > 2)
            this.bubble.removeChild(this.bubble.childNodes[1]);
    }
    update(e: EntitySnapshot, phase: string, winnerId: string | null, dt: number, time: number, menu = false, yaw = 0, interpolate = false, camera?: THREE.PerspectiveCamera) {
        const at = entityPos(e), v = entityVel(e);
        if (interpolate && !menu && e.alive && !e.falling && this.hasRenderedPosition && this.root.position.distanceTo(at) <= 2.5) {
            at.lerpVectors(this.root.position, at, 1 - Math.exp(-dt * 20));
        }
        this.hasRenderedPosition = true;
        if (phase === 'finished' && winnerId === e.id)
            v.set(0, 0, 0);
        const speed = Math.hypot(v.x, v.z);
        const eAny = e as unknown as {
            yaw?: number;
            collisionCount?: number;
        };
        const afloat = !e.alive && !e.withdrawn && at.y < -1.1;
        if (afloat && !this.floating) {
            this.floating = true;
            this.floatTime = 0;
            this.floatAnchor.copy(e.waterEntry ? new THREE.Vector3(e.waterEntry.x, e.waterEntry.y, e.waterEntry.z) : at);
            this.floatAnchor.y = -1.7;
            this.sinkStart = at.y;
            this.bodyStart = .7 * e.scale;
            this.startYaw = this.body.rotation.y;
            this.turnYaw = Math.atan2(-at.x, -at.z);
            this.lifering.visible = true;
            this.effects.clear();
        }
        this.scale = e.scale || 1;
        this.root.visible = !e.withdrawn;
        if (this.floating) {
            this.floatTime += dt;
            this.root.position.set(this.floatAnchor.x, 0, this.floatAnchor.z);
            const t = smooth(this.floatTime / .55);
            const bob = Math.sin(time * 1.4 + this.floatAnchor.x * .18) * .012 + Math.sin(time * 2.35 + this.floatAnchor.z) * .006;
            this.body.position.x = Math.sin(time * .85) * .035 * t;
            this.body.position.z = Math.cos(time * .7) * .025 * t;
            const surface = this.waterHeight(this.floatAnchor.x + this.body.position.x, this.floatAnchor.z + this.body.position.z);
            this.body.position.y = THREE.MathUtils.lerp(this.sinkStart + this.bodyStart, surface - .38 + bob, t);
            this.body.rotation.set(Math.sin(time * .8) * .025, angleLerp(this.startYaw, this.turnYaw, smooth(this.floatTime / .9)), Math.sin(time * 1.2) * .025);
            this.ballRoot.position.y = THREE.MathUtils.lerp(this.sinkStart, -3.5, smooth(this.floatTime / 1.75));
            this.ballRoot.visible = this.floatTime < 1.75;
            this.play('ready_balance');
            this.mixer.timeScale = 1;
        }
        else {
            this.root.position.copy(at);
            this.body.position.set(0, .7 * this.scale, 0);
            this.body.rotation.x = 0;
            this.body.rotation.z = 0;
            this.ballRoot.scale.setScalar(this.scale);
            if (menu) {
                this.root.rotation.y = yaw;
                this.body.rotation.y = .4;
            }
            else {
                this.root.rotation.y = 0;
                if (speed > .05) {
                    const target = Math.atan2(v.x, v.z);
                    this.body.rotation.y = angleLerp(this.body.rotation.y, target, Math.min(1, dt * 10));
                    const axis = new THREE.Vector3(v.z, 0, -v.x).normalize();
                    this.ballRoot.quaternion.premultiply(new THREE.Quaternion().setFromAxisAngle(axis, speed * dt / (BASE_RADIUS * this.scale)));
                }
                else {
                    if ((phase === 'intro' || phase === 'countdown' || e.airdrop) && eAny.yaw !== undefined)
                        this.body.rotation.y = eAny.yaw;
                }
            }
            const boost = (e.effects.speedUp || 0) > (e.effects.speedDown || 0), slow = (e.effects.speedDown || 0) > (e.effects.speedUp || 0);
            const locomotion = boost ? 'roll_boost' : 'roll_move';
            const clip = e.falling ? 'fall' : phase === 'finished' && winnerId === e.id ? 'victory' : phase === 'playing' && speed > .12 ? locomotion : 'ready_balance';
            this.play(clip);
            // The approved shared animal motions already bake the approved 1.5x cadence into its 0.667s cycle.
            this.mixer.timeScale = clip.startsWith('roll_') ? (this.usesSharedAnimalRig ? 1 : 1.5) * speed / 5.8 : 1;
            if (phase === 'finished' && winnerId === e.id)
                this.body.rotation.y = angleLerp(this.body.rotation.y, THREE.MathUtils.degToRad(36), Math.min(dt * 3, 1));
            const mode = menu || phase !== 'playing' || e.falling ? 'idle' : slow ? 'slow' : boost ? 'boost' : 'normal';
            this.effects.update(at, v, this.body.rotation.y, this.getHead(), mode, dt, BASE_RADIUS * this.scale, camera);
        }
        this.mixer.update(dt);
        if (!this.usesSharedAnimalRig && this.currentClip.startsWith('roll_') && this.spine) {
            const phaseTime = (this.actions[this.currentClip]?.time || 0) * Math.PI * 2;
            this.spine.rotation.z -= Math.sin(phaseTime) * .09 * Math.min(speed / 5.8, 1);
            this.spine.position.x += Math.sin(phaseTime) * .032;
        }
        const confused = !menu && !e.falling && phase === 'playing' && (e.effectRemaining?.confusion || 0) > 0;
        if (confused && !this.confusion)
            this.confusion = new ConfusionEffect(this.effects.scene);
        if (camera)
            this.confusion?.update(this.getHead(), this.scale, camera, confused, dt);
        this.effects.animate(dt);
    }
    getHead() { if (this.head)
        return this.head.getWorldPosition(new THREE.Vector3()); return this.body.getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, 1, 0)); }
    victoryCenter(headroom = false) {
        // Use the animal's resting silhouette, so the camera does not bob with its celebration.
        const extra = headroom ? Math.max(0, this.headHeight - 1.5) * .25 : 0;
        return this.body.getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, this.headHeight * .5 + extra, 0));
    }
    nameAnchor() { if (this.head)
        return this.head.getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, this.headHeight - this.headRestY, 0)); return this.body.getWorldPosition(new THREE.Vector3()).add(new THREE.Vector3(0, this.headHeight, 0)); }
    dispose() { this.confusion?.dispose(); this.bubble.remove(); this.root.removeFromParent(); this.effects.dispose(); this.mixer.stopAllAction(); this.mixer.uncacheRoot(this.model); this.sphere.geometry.dispose(); this.lifering.traverse(o => { if (o instanceof THREE.Mesh)
        o.geometry.dispose(); }); this.customMaterials.forEach(m => m.dispose()); }
}
export class GameRenderer {
    readonly scene = new THREE.Scene();
    readonly camera = new THREE.PerspectiveCamera(40, 1, .1, 500);
    readonly renderer: THREE.WebGLRenderer;
    private readonly canvas: HTMLCanvasElement;
    private readonly assets = new Map<string, GLTF>();
    private readonly paws = new Map<string, THREE.Texture>();
    private readonly masks = new Map<string, THREE.Texture>();
    private readonly views = new Map<string, AnimalView>();
    private readonly labels: HTMLDivElement;
    private ocean!: Ocean;
    private islandMixer?: THREE.AnimationMixer;
    private outline: number[][] = [];
    private previewScope: CameraScope | null = null;
    private previewYaw = 0;
    private windLines: THREE.Line[] = [];
    private windDirection = new THREE.Vector3(1, 0, 0);
    private windTime = 0;
    private lastPhase = '';
    private width = 1;
    private height = 1;
    private time = 0;
    private focusTime = 0;
    private focusWinner: string | null = null;
    private focusStartPos = new THREE.Vector3();
    private focusStartQuat = new THREE.Quaternion();
    private focusStartFov = 40;
    private lastScreen = '';
    private lost = false;
    private seenImpacts = new Set<string>();
    private impactClock = 0;
    private readonly collisionSparks = new CollisionSparks(this.scene);
    private readonly warmColorMaterials: THREE.Material[] = [];
    private settings: Record<CameraScope, CameraSettings> = { match: { height: 15, distance: 15, fov: 40, yaw: -11.7 }, victory: { height: 2, distance: 4, fov: 44.9, yaw: 36 } };
    private contextLost = (e: Event) => { e.preventDefault(); this.lost = true; window.dispatchEvent(new CustomEvent('ball-renderer-context', { detail: { lost: true } })); };
    private contextRestored = () => { this.lost = false; this.renderer.resetState(); this.resize(); window.dispatchEvent(new CustomEvent('ball-renderer-context', { detail: { lost: false } })); };
    private constructor(canvas: HTMLCanvasElement) {
        this.canvas = canvas;
        this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, powerPreference: 'high-performance' });
        this.renderer.outputColorSpace = THREE.SRGBColorSpace;
        this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
        this.renderer.toneMappingExposure = 1.05;
        this.renderer.shadowMap.enabled = true;
        this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
        this.labels = document.createElement('div');
        Object.assign(this.labels.style, { position: 'absolute', inset: '0', overflow: 'hidden', pointerEvents: 'none', zIndex: '3' });
        canvas.parentElement!.append(this.labels);
        canvas.addEventListener('webglcontextlost', this.contextLost);
        canvas.addEventListener('webglcontextrestored', this.contextRestored);
        this.resize();
    }
    static async create(canvas: HTMLCanvasElement) { const self = new GameRenderer(canvas); await self.load(); return self; }
    private async load() {
        const manager = new THREE.LoadingManager();
        // Offline HTML embeds models as data URLs, which have no directory for their
        // shared images. Resolve only those hashed textures through the embedded map.
        if ((window as unknown as {
            __BALL_ISLAND_STANDALONE__?: unknown;
        }).__BALL_ISLAND_STANDALONE__)
            manager.setURLModifier(url => { const image = url.match(/(?:^|\/)textures\/([a-f0-9]{64}\.(?:webp|png|jpg))$/); return image ? assetUrl(`textures/${image[1]}`) : url; });
        const loader = new GLTFLoader(manager).setMeshoptDecoder(MeshoptDecoder);
        const textureLoader = new THREE.TextureLoader(manager);
        const jobs = ANIMALS.map(async (animal) => {
            const [asset, paw, mask] = await Promise.all([loader.loadAsync(assetUrl(`animals/${animal}.glb?rev=new-animals-20261106`)), textureLoader.loadAsync(assetUrl(`ball-prints/${animal}.svg`)), textureLoader.loadAsync(assetUrl(`primary-masks/${animal}.png?rev=new-animals-20261106`))]);
            // Normalize the shared atlas before menu, warm-up and match instances clone it.
            asset.scene.traverse(o => { if (o instanceof THREE.Mesh)
                for (const m of Array.isArray(o.material) ? o.material : [o.material])
                    if (m instanceof THREE.MeshStandardMaterial && m.map)
                        configureAnimalTextureSampling(m.map); });
            paw.colorSpace = THREE.NoColorSpace;
            paw.anisotropy = Math.min(8, this.renderer.capabilities.getMaxAnisotropy());
            mask.colorSpace = THREE.SRGBColorSpace;
            mask.premultiplyAlpha = false;
            mask.flipY = false;
            configureAnimalTextureSampling(mask);
            this.assets.set(animal, asset);
            this.paws.set(animal, paw);
            this.masks.set(animal, mask);
        });
        const islandJob = loader.loadAsync(assetUrl('island/island_stage.glb')).then(gltf => { gltf.scene.name = 'ApprovedIslandStageV3Refined'; gltf.scene.traverse(o => { if (o instanceof THREE.Mesh) {
            if (o.name === 'Arena_Flat_Grass')
                correctArenaSurface(o);
            o.castShadow = true;
            o.receiveShadow = true;
            if (o.material instanceof THREE.MeshStandardMaterial && o.material.map)
                o.material.map.anisotropy = Math.min(8, this.renderer.capabilities.getMaxAnisotropy());
        } }); this.scene.add(gltf.scene); this.islandMixer = new THREE.AnimationMixer(gltf.scene); gltf.animations.forEach(a => { if (a.name.includes('SeaBreeze'))
            this.islandMixer!.clipAction(a).play(); }); });
        const geometryJob = fetch(assetUrl('island/stage_geometry.json')).then(r => r.json()).then(j => { this.outline = j.outline_xz || []; return j; });
        this.setupLight();
        this.setupWind();
        const [, geometry] = await Promise.all([Promise.all([...jobs, islandJob]), geometryJob]);
        this.ocean = new Ocean(this.scene, this.renderer, { radius: 9.05, waterY: -1.7 });
        this.ocean.setShoreline(geometry.shoreline_radii || []);
        await this.warmCharacterColors();
    }
    private async warmCharacterColors() {
        const warmScene = new THREE.Scene();
        for (const animal of ANIMALS) {
            const model = cloneSkeleton(this.assets.get(animal)!.scene);
            model.traverse(o => { if (o instanceof THREE.Mesh) {
                o.castShadow = true;
                o.receiveShadow = true;
            } });
            const paint = applyPrimaryColorMaterials(model, this.masks.get(animal)!, PRIMARY_COLORS[animal], PRIMARY_SOURCE_LUMINANCE[animal]);
            this.warmColorMaterials.push(...paint.materials);
            warmScene.add(model);
        }
        // Reuse these programs when an NPC appears; color changes are uniforms only.
        await this.renderer.compileAsync(warmScene, this.camera, this.scene);
        warmScene.traverse(o => { if (o instanceof THREE.SkinnedMesh)
            o.skeleton.dispose(); });
        warmScene.clear();
    }
    private setupWind() { for (let i = 0; i < 44; i++) {
        const pts = [new THREE.Vector3(), new THREE.Vector3()];
        const line = new THREE.Line(new THREE.BufferGeometry().setFromPoints(pts), new THREE.LineBasicMaterial({ color: '#eefbff', transparent: true, opacity: 0, depthWrite: false }));
        line.visible = false;
        line.frustumCulled = false;
        line.renderOrder = 3;
        this.scene.add(line);
        this.windLines.push(line);
    } }
    private updateWind(snapshot: Snapshot, dt: number) { const wind = snapshot.wind; this.windTime += dt; const active = !!wind?.active; if (active)
        this.windDirection.set(wind.direction.x, 0, wind.direction.z).normalize(); const d = this.windDirection, side = new THREE.Vector3(d.z, 0, -d.x); for (let i = 0; i < this.windLines.length; i++) {
        const line = this.windLines[i];
        line.visible = active;
        if (!active)
            continue;
        const phase = (this.windTime * 12 + i * 1.73) % 32 - 16;
        const lateral = Math.sin(i * 7.13) * 13;
        const y = .4 + (i % 7) * .44;
        const center = d.clone().multiplyScalar(phase).addScaledVector(side, lateral);
        center.y = y;
        const array = line.geometry.getAttribute('position') as THREE.BufferAttribute;
        const length = .5 + (i % 4) * .24;
        array.setXYZ(0, center.x, center.y, center.z);
        array.setXYZ(1, center.x - d.x * length, center.y + .07 * Math.sin(this.windTime * 4 + i), center.z - d.z * length);
        array.needsUpdate = true;
        (line.material as THREE.LineBasicMaterial).opacity = .19 + Math.sin((phase + 16) / 32 * Math.PI) * .31;
    } }
    private setupLight() { this.scene.background = new THREE.Color('#b8dce6'); this.scene.fog = new THREE.FogExp2('#bedee5', .0025); const sky = new Sky(); sky.scale.setScalar(450); const sun = new THREE.Vector3(-.4, .82, .35).normalize(); Object.assign(sky.material.uniforms.turbidity, { value: 2.2 }); sky.material.uniforms.rayleigh.value = 1.2; sky.material.uniforms.sunPosition.value.copy(sun); this.scene.add(sky); const env = new THREE.Scene(); env.add(sky.clone()); const pmrem = new THREE.PMREMGenerator(this.renderer); const target = pmrem.fromScene(env, .03); this.scene.environment = target.texture; this.scene.environmentIntensity = .30; pmrem.dispose(); this.scene.add(new THREE.HemisphereLight('#d8f4ff', '#697c4a', .85)); const light = new THREE.DirectionalLight('#fff0d0', 2.35); light.position.copy(sun).multiplyScalar(30); light.castShadow = true; light.shadow.mapSize.set(2048, 2048); Object.assign(light.shadow.camera, { left: -15, right: 15, top: 15, bottom: -15, near: 1, far: 65 }); light.shadow.camera.updateProjectionMatrix(); light.shadow.autoUpdate = true; light.shadow.needsUpdate = true; light.shadow.normalBias = .025; light.shadow.bias = -.00015; this.scene.add(light); }
    update(snapshot: Snapshot, localId: string, options: RenderOptions) {
        const dt = options.paused ? 0 : Math.min(.06, Math.max(options.dt, 0));
        this.time += dt;
        this.islandMixer?.update(dt);
        this.updateWind(snapshot, dt);
        const phase = String(snapshot.status);
        const menu = options.screen === 'menu';
        const snap = snapshot as unknown as {
            introRemaining?: number;
            introDuration?: number;
        };
        if (menu || (phase === 'intro' && this.lastPhase !== 'intro') || snapshot.elapsedSeconds < this.impactClock - 1e-6) {
            this.seenImpacts.clear();
            this.collisionSparks.clear();
            for (const v of this.views.values())
                v.effects.clear();
        }
        this.impactClock = snapshot.elapsedSeconds;
        if (phase === 'intro' && this.lastPhase !== 'intro') {
            for (const v of this.views.values())
                v.dispose();
            this.views.clear();
        }
        this.lastPhase = phase;
        const selected = options.selected;
        const entities = menu ? [{ ...selected, id: '__preview__', pos: { x: 0, y: .7, z: 0 }, scale: 1, alive: true, falling: false, effects: {}, vel: { x: 0, y: 0, z: 0 } } as unknown as EntitySnapshot] : snapshot.entities;
        const present = new Set(entities.map(e => e.id));
        for (const [id, view] of this.views)
            if (!present.has(id)) {
                view.dispose();
                this.views.delete(id);
            }
        for (const e of entities) {
            let view = this.views.get(e.id);
            if (view && view.config.animal !== e.animal) {
                view.dispose();
                this.views.delete(e.id);
                view = undefined;
            }
            if (!view) {
                view = new AnimalView(e, this.assets.get(e.animal) || this.assets.get('rabbit')!, this.paws.get(e.animal) || this.paws.get('rabbit')!, this.masks.get(e.animal) || this.masks.get('rabbit')!, this.scene, this.labels, (x, z) => this.ocean.sampleHeight(x, z, this.time));
                this.views.set(e.id, view);
            }
            view.config = e;
            view.setPrimaryColor();
            view.setRole(menu || e.id === localId);
            view.update(e, menu ? 'ready' : phase, snapshot.winnerId, dt, this.time, menu, options.previewYaw ?? this.previewYaw, options.interpolate ?? false, this.camera);
        }
        // Consume every contact, including simultaneous contacts and batched PK snapshots.
        const retained = new Set(snapshot.impacts.map(hit => `${hit.a}:${hit.b}:${hit.at}`));
        if (!menu && phase !== 'intro' && phase !== 'countdown')
            for (const hit of snapshot.impacts) {
                const key = `${hit.a}:${hit.b}:${hit.at}`;
                if (this.seenImpacts.has(key))
                    continue;
                this.seenImpacts.add(key);
                const feedback = hit.feedback ?? classifyCollisionFeedback(hit.a, hit.b, hit.appliedDistanceA, hit.appliedDistanceB);
                const a = snapshot.entities.find(e => e.id === hit.a), b = snapshot.entities.find(e => e.id === hit.b);
                if (!a || !b || a.withdrawn || b.withdrawn || snapshot.elapsedSeconds - hit.at > .35)
                    continue;
                this.collisionSparks.emit(new THREE.Vector3(hit.x, hit.y, hit.z), Math.min(a.radius, b.radius), feedback.tier, feedback.strongerId, key);
            }
        for (const key of this.seenImpacts)
            if (!retained.has(key))
                this.seenImpacts.delete(key);
        if (options.cameraScope !== undefined)
            this.previewScope = options.cameraScope;
        if (menu && this.previewScope === null) {
            this.focusWinner = null;
            this.focusTime = 0;
            this.placeMenuCamera();
        }
        else if (this.previewScope === 'victory') {
            const view = this.views.get(snapshot.winnerId || localId) || this.views.values().next().value;
            this.placeFocusCamera(view);
        }
        else if (phase === 'finished' && snapshot.winnerId) {
            const winner = this.views.get(snapshot.winnerId);
            if (this.focusWinner !== snapshot.winnerId) {
                this.focusWinner = snapshot.winnerId;
                this.focusTime = 0;
                this.focusStartPos.copy(this.camera.position);
                this.focusStartQuat.copy(this.camera.quaternion);
                this.focusStartFov = this.camera.fov;
            }
            this.focusTime += dt;
            const oldPos = this.focusStartPos.clone(), oldQuat = this.focusStartQuat.clone();
            this.placeFocusCamera(winner);
            const t = smooth(this.focusTime / 2);
            this.camera.position.lerpVectors(oldPos, this.camera.position, t);
            this.camera.quaternion.slerpQuaternions(oldQuat, this.camera.quaternion.clone(), t);
            this.camera.fov = THREE.MathUtils.lerp(this.focusStartFov, this.settings.victory.fov, t);
            this.camera.updateProjectionMatrix();
        }
        else {
            this.focusWinner = null;
            this.focusTime = 0;
            this.placeMatchCamera();
            if (phase === 'intro') {
                const progress = smooth(1 - (snap.introRemaining ?? 1.6) / (snap.introDuration || 1.6));
                const backward = new THREE.Vector3(0, 0, 1).applyQuaternion(this.camera.quaternion);
                this.camera.position.addScaledVector(backward, Math.max(8, this.camera.position.length() * .65) * (1 - progress));
            }
        }
        this.camera.updateMatrixWorld(true);
        this.collisionSparks.update(dt, this.camera);
        for (const view of this.views.values()) {
            const anchor = view.nameAnchor(), depth = -anchor.clone().applyMatrix4(this.camera.matrixWorldInverse).z, a = anchor.project(this.camera);
            const visible = !menu && view.root.visible && a.z < 1 && a.z > -1 && Math.abs(a.x) < 1.15 && Math.abs(a.y) < 1.15;
            view.bubble.style.display = visible ? 'block' : 'none';
            if (visible) {
                const reference = 1080 / (2 * Math.tan(THREE.MathUtils.degToRad(40) / 2) * Math.hypot(15, 15));
                const pixelsPerUnit = this.height / (2 * Math.tan(THREE.MathUtils.degToRad(this.camera.fov) / 2) * Math.max(.1, depth));
                const scale = clamp(pixelsPerUnit / reference, .1, 10);
                view.bubble.style.transform = `translate(-50%,-100%) scale(${scale})`;
                view.bubble.style.left = `${(a.x * .5 + .5) * this.width}px`;
                view.bubble.style.top = `${(-a.y * .5 + .5) * this.height - 8 * scale}px`;
            }
        }
        this.lastScreen = options.screen;
        this.ocean.update(this.time, this.camera);
    }
    private placeMenuCamera() { const portrait = this.width < 600 && this.height > this.width; const previewY = portrait ? .30 : this.height <= 520 && this.width > this.height ? .42 : .5; const target = new THREE.Vector3(0, 1.6, 0), eye = new THREE.Vector3(15.5, 13, 21).normalize().multiplyScalar(8.5); this.camera.fov = 42; this.camera.position.copy(target).add(eye); this.camera.lookAt(target); this.camera.updateProjectionMatrix(); this.camera.updateMatrixWorld(); const focal = this.height / (2 * Math.tan(THREE.MathUtils.degToRad(42) * .5)), right = new THREE.Vector3(1, 0, 0).applyQuaternion(this.camera.quaternion), up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.camera.quaternion); this.camera.position.addScaledVector(right, (.5 - (portrait ? .5 : .2984)) * this.width * eye.length() / focal); this.camera.position.addScaledVector(up, (previewY - .5) * this.height * eye.length() / focal); }
    private placeMatchCamera() {
        const p = this.settings.match;
        const yaw = THREE.MathUtils.degToRad(p.yaw);
        this.camera.fov = p.fov;
        this.camera.position.set(Math.sin(yaw) * p.distance, p.height, Math.cos(yaw) * p.distance);
        this.camera.lookAt(0, 0, 0);
        this.camera.updateProjectionMatrix();
        this.camera.updateMatrixWorld(true);
        // Match the native projected stage-centre correction without changing viewing direction.
        const right = new THREE.Vector3(1, 0, 0).applyQuaternion(this.camera.quaternion), up = new THREE.Vector3(0, 1, 0).applyQuaternion(this.camera.quaternion);
        const distance = this.camera.position.length(), focal = this.height / (2 * Math.tan(THREE.MathUtils.degToRad(p.fov) / 2));
        for (let i = 0; i < 5 && this.outline.length; i++) {
            let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
            for (const edge of this.outline) {
                const v = new THREE.Vector3(edge[0], 0, edge[1]).project(this.camera);
                const x = (v.x * .5 + .5) * this.width, y = (-v.y * .5 + .5) * this.height;
                minX = Math.min(minX, x);
                maxX = Math.max(maxX, x);
                minY = Math.min(minY, y);
                maxY = Math.max(maxY, y);
            }
            const dx = (minX + maxX) / 2 - this.width * .5, dy = (minY + maxY) / 2 - this.height * (385 / 800);
            this.camera.position.addScaledVector(right, dx * distance / focal).addScaledVector(up, -dy * distance / focal);
            this.camera.updateMatrixWorld(true);
        }
    }
    private placeFocusCamera(view?: AnimalView) {
        const p = this.settings.victory;
        const target = view ? view.victoryCenter() : new THREE.Vector3(0, 1.5, 0);
        const yaw = THREE.MathUtils.degToRad(p.yaw);
        const offset = new THREE.Vector3(Math.sin(yaw) * p.distance, p.height, Math.cos(yaw) * p.distance);
        if (view) {
            // Raise the framing from the ball to the animal while preserving the previous
            // camera-to-animal distance, including when gifts change the ball's size.
            const previousHeight = view.root.position.y + 1.2 + p.height - target.y;
            offset.setLength(Math.hypot(p.distance, previousHeight));
        }
        this.camera.fov = p.fov;
        this.camera.position.copy(target).add(offset);
        this.camera.lookAt(view ? view.victoryCenter(true) : target);
        this.camera.updateProjectionMatrix();
    }
    setCameraSettings(scope: CameraScope, params: Partial<CameraSettings>) { const s = this.settings[scope]; Object.assign(s, params); if (params.azimuth !== undefined)
        s.yaw = params.azimuth; s.height = clamp(s.height, .5, 40); s.distance = clamp(s.distance, 1, 60); s.fov = clamp(s.fov, 20, 85); s.yaw = clamp(s.yaw, -180, 180); }
    getCameraSettings(scope: CameraScope) { return { ...this.settings[scope], azimuth: this.settings[scope].yaw }; }
    setCameraPreview(scope: CameraScope | null) { this.previewScope = scope; }
    rotatePreview(deltaRadians: number) { this.previewYaw += deltaRadians; }
    isFocusDone() { return this.focusWinner !== null && this.focusTime >= 2; }
    inputToWorld(x: number, y: number, at: {
        x: number;
        y?: number;
        z: number;
    } = { x: 0, y: .7, z: 0 }) { if (Math.hypot(x, y) < .0001)
        return { x: 0, z: 0 }; const strength = Math.min(1, Math.hypot(x, y)), a = new THREE.Vector3(at.x, at.y ?? .7, at.z), projected = a.clone().project(this.camera); const ndc = new THREE.Vector2(projected.x + x / Math.hypot(x, y) * 48 / this.width, projected.y - y / Math.hypot(x, y) * 48 / this.height); const ray = new THREE.Raycaster(); ray.setFromCamera(ndc, this.camera); const hit = new THREE.Vector3(); if (ray.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0, 1, 0), -a.y), hit)) {
        hit.sub(a);
        hit.y = 0;
        hit.normalize().multiplyScalar(strength);
        return { x: hit.x, z: hit.z };
    } return { x: 0, z: 0 }; }
    resize() { this.width = Math.max(1, this.canvas.clientWidth || innerWidth); this.height = Math.max(1, this.canvas.clientHeight || innerHeight); const dpr = Math.min(devicePixelRatio || 1, Math.sqrt(1920 * 1080 / (this.width * this.height)), 2); this.renderer.setPixelRatio(Math.max(.1, dpr)); this.renderer.setSize(this.width, this.height, false); this.camera.aspect = this.width / this.height; this.camera.updateProjectionMatrix(); }
    render() { if (!this.lost)
        this.renderer.render(this.scene, this.camera); }
    dispose() { for (const view of this.views.values())
        view.dispose(); this.views.clear(); this.warmColorMaterials.forEach(m => m.dispose()); this.labels.remove(); this.canvas.removeEventListener('webglcontextlost', this.contextLost); this.canvas.removeEventListener('webglcontextrestored', this.contextRestored); this.ocean.dispose(); this.collisionSparks.dispose(); this.renderer.dispose(); }
}
