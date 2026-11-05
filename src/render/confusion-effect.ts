import * as THREE from 'three';
import { assetUrl } from '../asset-url';
/** Original soft four-point sparkles, tinted gently for bright grass. */
export class ConfusionEffect {
    readonly root = new THREE.Group();
    private time = 0;
    private texture: THREE.Texture;
    constructor(scene: THREE.Scene) {
        this.root.name = 'confusion-kenney-stars';
        // Keep the original confusion glow separate from the approved impact burst.
        this.texture = new THREE.TextureLoader().load(assetUrl('effects/confusion-glow.png'));
        this.texture.colorSpace = THREE.SRGBColorSpace;
        for (let i = 0; i < 4; i++) {
            const material = new THREE.SpriteMaterial({ map: this.texture, color: i % 2 ? '#e0a1ed' : '#ffd05c', transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false });
            const star = new THREE.Sprite(material);
            this.root.add(star);
        }
        this.root.visible = false;
        scene.add(this.root);
    }
    update(head: THREE.Vector3, scale: number, _camera: THREE.Camera, active: boolean, dt: number) {
        this.root.visible = active;
        if (!active)
            return;
        this.time += dt;
        this.root.position.copy(head);
        // Match the racing effect's angular speed and bobbing; fit the animal head.
        this.root.children.forEach((child, i) => { const star = child as THREE.Sprite, angle = this.time * 2 + i * Math.PI / 2; star.position.set(Math.cos(angle) * .75 * scale, (.4 + Math.sin(angle * 2) * .12) * scale, Math.sin(angle) * .75 * scale); star.scale.setScalar(.84 * scale); star.material.rotation = -angle; });
    }
    dispose() { this.root.removeFromParent(); this.root.children.forEach(s => (s as THREE.Sprite).material.dispose()); this.texture.dispose(); }
}
