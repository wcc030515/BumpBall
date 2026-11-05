import * as THREE from 'three';
import { assetUrl } from '../asset-url';
import { IMPACT_SPARK_STYLES, type ImpactTier } from '../collision-feedback';
type Burst = {
    root: THREE.Group;
    parts: THREE.Sprite[];
    age: number;
    life: number;
    strength: number;
    flecks: number;
};
const MAX_BURSTS = 16;
/** Approved B: one short flash and flying stars at the shared contact point. */
export class CollisionSparks {
    private readonly texture: THREE.Texture;
    private readonly bursts: Burst[] = [];
    constructor(private readonly scene: THREE.Scene) {
        // CC0 Kenney star_06 used in the approved B preview.
        this.texture = new THREE.TextureLoader().load(assetUrl('effects/confusion-star.png'));
        this.texture.colorSpace = THREE.SRGBColorSpace;
    }
    emit(contact: THREE.Vector3, radius: number, tier: ImpactTier, strongerId: string | null, eventKey: string) {
        let burst = this.bursts.find(b => b.age < 0);
        if (!burst) {
            if (this.bursts.length < MAX_BURSTS) {
                burst = this.create();
                this.bursts.push(burst);
            }
            else
                burst = this.bursts.reduce((a, b) => a.age > b.age ? a : b);
        }
        const style = IMPACT_SPARK_STYLES[tier];
        burst.age = 0;
        burst.life = style.duration;
        burst.flecks = style.flecks;
        burst.strength = style.strength * THREE.MathUtils.clamp(Math.sqrt(Math.max(.1, radius) / .7), .7, 1.3);
        burst.root.position.copy(contact);
        burst.root.visible = true;
        burst.root.userData = { tier, strongerId, eventKey, contact: contact.toArray(), style: 'B-starflash' };
        burst.parts.forEach((part, i) => {
            part.visible = i <= style.flecks;
            part.material.color.set(tier === 0 ? '#f3f5f5' : i === 0 ? '#ffd24a' : i % 2 ? '#ffb400' : '#fff4d2');
            (part.material.userData.edgeColor.value as THREE.Color).set(tier === 0 ? '#516472' : '#8e592c');
        });
        this.animate(burst);
    }
    update(dt: number, camera: THREE.Camera) {
        for (const burst of this.bursts) {
            if (burst.age < 0)
                continue;
            burst.age += Math.max(0, dt);
            if (burst.age >= burst.life) {
                burst.age = -1;
                burst.root.visible = false;
                continue;
            }
            // Keep the burst circular and its flying stars readable at every camera angle.
            burst.root.quaternion.copy(camera.quaternion);
            this.animate(burst);
        }
    }
    clear() { for (const burst of this.bursts) {
        burst.age = -1;
        burst.root.visible = false;
    } }
    dispose() { for (const burst of this.bursts) {
        burst.root.removeFromParent();
        for (const part of burst.parts)
            part.material.dispose();
    } this.bursts.length = 0; this.texture.dispose(); }
    private create(): Burst {
        const root = new THREE.Group();
        root.name = 'collision-sparks';
        root.visible = false;
        const parts = Array.from({ length: 8 }, () => {
            const material = new THREE.SpriteMaterial({ map: this.texture, transparent: true, depthWrite: false, depthTest: false, toneMapped: false, blending: THREE.NormalBlending });
            const edgeColor = { value: new THREE.Color('#8e592c') };
            material.userData.edgeColor = edgeColor;
            material.onBeforeCompile = shader => {
                shader.uniforms.edgeColor = edgeColor;
                shader.fragmentShader = 'uniform vec3 edgeColor;\n' + shader.fragmentShader;
                shader.fragmentShader = shader.fragmentShader.replace('#include <map_fragment>', `
     vec4 texel=texture2D(map,vMapUv);
     float mask=texel.r*texel.a;
     diffuseColor.rgb=mix(edgeColor,diffuse,smoothstep(.10,.22,mask));
     diffuseColor.a*=smoothstep(.035,.075,mask);
    `);
            };
            material.customProgramCacheKey = () => 'collision-B-starflash-v1';
            const sprite = new THREE.Sprite(material);
            sprite.renderOrder = 4;
            root.add(sprite);
            return sprite;
        });
        this.scene.add(root);
        return { root, parts, age: -1, life: .3, strength: 1, flecks: 7 };
    }
    private animate(burst: Burst) {
        const q = THREE.MathUtils.clamp(burst.age / burst.life, 0, 1), strength = burst.strength;
        burst.parts.forEach((part, i) => {
            if (!part.visible)
                return;
            part.material.opacity = (1 - q) ** .7;
            if (i === 0) {
                part.position.set(0, 0, .04);
                part.scale.setScalar(strength * (.28 + Math.sin(Math.PI * q) * .95));
                part.material.rotation = .2 + q * .5;
            }
            else {
                const angle = (i - 1) / burst.flecks * Math.PI * 2 + .2, r = (.1 + q * .65) * strength;
                part.position.set(Math.cos(angle) * r, Math.sin(angle) * r, .06);
                part.scale.setScalar((.25 - .13 * q) * strength);
                part.material.rotation = angle + q;
            }
        });
    }
}
