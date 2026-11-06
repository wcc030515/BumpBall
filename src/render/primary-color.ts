import * as THREE from 'three';
/** These tightly packed animal atlases need the approved non-mipmapped
 * sampler. Coarser atlas levels mix neighboring light UV islands into fur. */
export function configureAnimalTextureSampling(texture: THREE.Texture) {
    texture.minFilter = THREE.LinearFilter;
    texture.magFilter = THREE.LinearFilter;
    texture.generateMipmaps = false;
    texture.anisotropy = 1;
    texture.needsUpdate = true;
}
/** The approved preview layer stores the primary fur's color contribution.
 * Subtract it before recoloring, preserving edge coverage, secondary fur,
 * facial details and the original material's lighting. */
export function primaryColorMaterial(source: THREE.MeshStandardMaterial, layer: THREE.Texture, original: string, sourceLuminance: number) {
    const material = source.clone();
    const uniforms = {
        uMainLayer: { value: layer }, uMainTarget: { value: new THREE.Color(original) },
        uMainSourceLuma: { value: sourceLuminance }, uMainEnabled: { value: 0 },
    };
    const map = source.map!;
    layer.flipY = map.flipY;
    layer.wrapS = map.wrapS;
    layer.wrapT = map.wrapT;
    layer.minFilter = map.minFilter;
    layer.magFilter = map.magFilter;
    layer.channel = map.channel;
    layer.generateMipmaps = map.generateMipmaps;
    layer.anisotropy = map.anisotropy;
    layer.offset.copy(map.offset);
    layer.repeat.copy(map.repeat);
    layer.center.copy(map.center);
    layer.rotation = map.rotation;
    material.onBeforeCompile = shader => {
        Object.assign(shader.uniforms, uniforms);
        shader.fragmentShader = 'uniform sampler2D uMainLayer;\nuniform vec3 uMainTarget;\nuniform float uMainSourceLuma;\nuniform float uMainEnabled;\n' + shader.fragmentShader;
        shader.fragmentShader = shader.fragmentShader.replace('#include <map_fragment>', `#include <map_fragment>
      #ifdef USE_MAP
        vec4 mainLayer=texture2D(uMainLayer,vMapUv);
        float mainWeightedDetail=dot(mainLayer.rgb,vec3(0.2126,0.7152,0.0722))/max(uMainSourceLuma,0.00001);
        diffuseColor.rgb=max(vec3(0.0),diffuseColor.rgb+uMainEnabled*(uMainTarget*mainWeightedDetail-mainLayer.rgb));
      #endif
    `);
    };
    material.customProgramCacheKey = () => 'animal-primary-premult-layer-v2';
    return { material, setColor: (hex: string) => {
            uniforms.uMainTarget.value.set(hex);
            uniforms.uMainEnabled.value = hex.toLowerCase() === original.toLowerCase() ? 0 : 1;
        } };
}
/** Clone only materials; all character instances keep sharing meshes and textures. */
export function applyPrimaryColorMaterials(model: THREE.Object3D, layer: THREE.Texture, original: string, sourceLuminance: number) {
    const parts = new Map<THREE.Material, ReturnType<typeof primaryColorMaterial>>();
    const recolor = (source: THREE.Material): THREE.Material => {
        if (!(source instanceof THREE.MeshStandardMaterial) || !source.map)
            return source;
        let part = parts.get(source);
        if (!part) {
            part = primaryColorMaterial(source, layer, original, sourceLuminance);
            parts.set(source, part);
        }
        return part.material;
    };
    model.traverse(object => {
        if (object instanceof THREE.Mesh)
            object.material = Array.isArray(object.material)
                ? object.material.map(recolor) : recolor(object.material);
    });
    return { materials: [...parts.values()].map(p => p.material), setColor: (hex: string) => parts.forEach(p => p.setColor(hex)) };
}
