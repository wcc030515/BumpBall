import * as THREE from 'three';
/** Lightweight temporary parachute; the existing animal/ball assets are reused. */
export class AirdropCanopy extends THREE.Group {
    private opacity = 0;
    private materials: THREE.Material[] = [];
    constructor(headHeight: number) {
        super();
        const height = .7 + headHeight + 1.05, radius = .9;
        for (let i = 0; i < 6; i++) {
            const material = new THREE.MeshStandardMaterial({ color: i % 2 ? '#fff1cc' : '#71c9b0', roughness: .72, side: THREE.DoubleSide, transparent: true, opacity: 0, depthWrite: false });
            this.materials.push(material);
            const canopy = new THREE.Mesh(new THREE.SphereGeometry(radius, 8, 8, i * Math.PI / 3, Math.PI / 3, 0, Math.PI / 2), material);
            canopy.position.y = height;
            canopy.scale.y = .42;
            this.add(canopy);
        }
        const ropeMat = new THREE.LineBasicMaterial({ color: '#fbf4d9', transparent: true, opacity: 0 });
        this.materials.push(ropeMat);
        for (let i = 0; i < 6; i++) {
            const angle = i * Math.PI / 3;
            const rope = new THREE.Line(new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(Math.cos(angle) * radius, height, Math.sin(angle) * radius), new THREE.Vector3(Math.cos(angle) * .28, .7 + headHeight * .45, Math.sin(angle) * .28)]), ropeMat);
            this.add(rope);
        }
        this.visible = false;
    }
    update(active: boolean, progress: number, dt: number, time: number) {
        const target = active ? Math.min(1, (1 - progress) * 8) : 0;
        this.opacity = THREE.MathUtils.lerp(this.opacity, target, Math.min(1, dt * 15));
        this.visible = this.opacity > .01;
        this.materials.forEach(m => { m.opacity = this.opacity; });
        this.rotation.z = Math.sin(time * 3) * .035;
        this.rotation.x = Math.cos(time * 2.3) * .025;
        if (active)
            this.position.y = 0;
        else
            this.position.y += dt * .5;
    }
    dispose() { this.traverse(o => { if (o instanceof THREE.Mesh || o instanceof THREE.Line)
        o.geometry.dispose(); }); this.materials.forEach(m => m.dispose()); this.removeFromParent(); }
}
