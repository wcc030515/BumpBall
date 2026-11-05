import * as THREE from 'three';
/** The mask identifies only the largest approved color region, not the whole
 * animal. Original atlas details, secondary colors, roughness and skin stay. */
export function primaryColorMaterial(source: THREE.MeshStandardMaterial, mask: THREE.Texture, original: string) {
    const material = source.clone();
    const color = { value: new THREE.Color(original) };
    const originalColor = { value: new THREE.Color(original) };
    material.onBeforeCompile = shader => {
        Object.assign(shader.uniforms, { uPrimaryMask: { value: mask }, uPrimaryColor: color, uOriginalPrimary: originalColor });
        shader.fragmentShader = 'uniform sampler2D uPrimaryMask;\nuniform vec3 uPrimaryColor;\nuniform vec3 uOriginalPrimary;\n' + shader.fragmentShader;
        shader.fragmentShader = shader.fragmentShader.replace('#include <map_fragment>', `#include <map_fragment>
      #ifdef USE_MAP
        float primaryRegion = texture2D(uPrimaryMask, vMapUv).r;
        vec3 shadedPrimary = uPrimaryColor * diffuseColor.rgb / max(uOriginalPrimary, vec3(0.001));
        diffuseColor.rgb = mix(diffuseColor.rgb, shadedPrimary, primaryRegion);
      #endif
    `);
    };
    material.customProgramCacheKey = () => 'animal-primary-color-v1';
    return { material, setColor: (hex: string) => color.value.set(hex) };
}
/** Clone only materials; all character instances keep sharing meshes and textures. */
export function applyPrimaryColorMaterials(model: THREE.Object3D, mask: THREE.Texture, original: string) {
    const parts = new Map<THREE.Material, ReturnType<typeof primaryColorMaterial>>();
    const recolor = (source: THREE.Material): THREE.Material => {
        if (!(source instanceof THREE.MeshStandardMaterial) || !source.map)
            return source;
        let part = parts.get(source);
        if (!part) {
            part = primaryColorMaterial(source, mask, original);
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
