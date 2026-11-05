import * as THREE from 'three';
// One spectrum is shared by the GPU surface and swimmer buoyancy. Coordinates
// are in metres and radians; CPU sampling inverts the horizontal displacement.
const WAVE_SPECTRUM = [
    [.94, .34, .22, 12.0, 1.40],
    [-.72, .68, .13, 7.3, 1.80],
    [.28, .96, .080, 4.2, 2.35],
    [.85, -.52, .045, 2.6, 2.80],
    [-.91, -.41, .025, 1.6, 3.60],
] as const;
const STEEPNESS = .62;
const glslFloat = (value: number) => Number.isInteger(value) ? `${value}.0` : String(value);
const waveCalls = WAVE_SPECTRUM.map(([x, z, a, l, v]) => `wave(p, tangent, binormal, normalize(vec2(${glslFloat(x)}, ${glslFloat(z)})), ${glslFloat(a)}, ${glslFloat(l)}, ${glslFloat(v)}, base);`).join('\n  ');
export function sampleOceanHeight(worldX: number, worldZ: number, time: number, waterY = -1.7): number {
    let baseX = worldX, baseZ = worldZ;
    for (let iteration = 0; iteration < 3; iteration++) {
        let displacementX = 0, displacementZ = 0;
        for (const [dx, dz, amplitude, wavelength, speed] of WAVE_SPECTRUM) {
            const length = Math.hypot(dx, dz), x = dx / length, z = dz / length;
            const phase = Math.PI * 2 / wavelength * (x * baseX + z * baseZ) - time * speed;
            const distance = amplitude * STEEPNESS * Math.cos(phase);
            displacementX += x * distance;
            displacementZ += z * distance;
        }
        baseX = worldX - displacementX;
        baseZ = worldZ - displacementZ;
    }
    let height = waterY;
    for (const [dx, dz, amplitude, wavelength, speed] of WAVE_SPECTRUM) {
        const length = Math.hypot(dx, dz);
        const phase = Math.PI * 2 / wavelength * (dx / length * baseX + dz / length * baseZ) - time * speed;
        height += amplitude * Math.sin(phase);
    }
    return height;
}
// Multi-directional Gerstner geometry provides real silhouettes; a second,
// shorter wave spectrum supplies surface normals without a large normal map.
const vertexShader = /* glsl */ `
uniform float uTime;
uniform mat4 uTextureMatrix;
varying vec3 vWorld;
varying vec3 vNormal;
varying vec4 vReflection;
varying float vCrest;

void wave(inout vec3 p, inout vec3 tangent, inout vec3 binormal, vec2 dir, float amplitude, float wavelength, float speed, vec2 base) {
  float k = 6.2831853 / wavelength;
  float f = k * dot(dir, base) - uTime * speed;
  float s = sin(f), c = cos(f);
  float steepness = ${STEEPNESS};
  p.xz += dir * amplitude * steepness * c;
  p.y += amplitude * s;
  tangent += vec3(-steepness * dir.x * dir.x * amplitude * k * s, dir.x * amplitude * k * c, -steepness * dir.x * dir.y * amplitude * k * s);
  binormal += vec3(-steepness * dir.x * dir.y * amplitude * k * s, dir.y * amplitude * k * c, -steepness * dir.y * dir.y * amplitude * k * s);
}
void main() {
  vec3 p = position;
  vec2 base = p.xz;
  vec3 tangent = vec3(1.0, 0.0, 0.0);
  vec3 binormal = vec3(0.0, 0.0, 1.0);
  ${waveCalls}
  vNormal = normalize(cross(binormal, tangent));
  vec4 world = modelMatrix * vec4(p, 1.0);
  vWorld = world.xyz;
  vCrest = p.y;
  vReflection = uTextureMatrix * world;
  gl_Position = projectionMatrix * viewMatrix * world;
}
`;
const fragmentShader = /* glsl */ `
uniform float uTime;
uniform float uWaterY;
uniform float uIslandRadius;
uniform float uReflectionReady;
uniform sampler2D uShoreProfile;
uniform float uHasShoreProfile;
uniform sampler2D uReflection;
uniform vec3 uSunDirection;
uniform vec3 uDeepColor;
uniform vec3 uShallowColor;
varying vec3 vWorld;
varying vec3 vNormal;
varying vec4 vReflection;
varying float vCrest;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
  return noise(p) * 0.56 + noise(p * 2.03 + 14.2) * 0.27 + noise(p * 4.09 + 3.7) * 0.17;
}
vec3 sky(vec3 direction) {
  float up = max(direction.y, 0.0);
  vec3 color = mix(vec3(0.68, 0.83, 0.89), vec3(0.19, 0.48, 0.72), pow(up, 0.55));
  float cloud = smoothstep(0.60, 0.79, fbm(direction.xz / (up + 0.13) * 1.9 + vec2(uTime * 0.006, 0)));
  color = mix(color, vec3(0.91, 0.94, 0.93), cloud * smoothstep(0.0, 0.22, up) * 0.32);
  float sun = max(dot(direction, uSunDirection), 0.0);
  color += vec3(1.0, 0.86, 0.61) * pow(sun, 280.0) * 2.4;
  color += vec3(0.65, 0.57, 0.36) * pow(sun, 18.0) * 0.08;
  return color;
}
vec2 microSlope(vec2 p) {
  vec2 n = vec2(0.0);
  n += vec2(0.93, 0.37) * cos(dot(p, vec2(9.1, 3.6)) - uTime * 3.3) * 0.055;
  n += vec2(-0.69, 0.72) * cos(dot(p, vec2(-7.4, 7.8)) - uTime * 4.1) * 0.042;
  n += vec2(0.31, 0.95) * cos(dot(p, vec2(7.2, 21.8)) - uTime * 5.4) * 0.024;
  n += vec2(0.97, -0.24) * cos(dot(p, vec2(32.0, -7.9)) - uTime * 7.5) * 0.016;
  n += vec2(-0.62, -0.78) * cos(dot(p, vec2(-36.7, -46.2)) - uTime * 9.8) * 0.010;
  return n;
}
void main() {
  vec3 V = normalize(cameraPosition - vWorld);
  float distanceToView = length(cameraPosition - vWorld);
  vec2 fine = microSlope(vWorld.xz);
  float detailFade = 1.0 - smoothstep(20.0, 75.0, distanceToView);
  vec3 N = normalize(vNormal + vec3(fine.x, 0, fine.y) * detailFade);
  vec3 R = reflect(-V, N);
  float fresnel = 0.025 + 0.975 * pow(1.0 - max(dot(N, V), 0.0), 5.0);

  // The land mesh uses a small irregular shoreline; keep water shallows broad
  // and soft, and let breaking swells reveal the coast in moving fragments.
  float angle = atan(vWorld.z, vWorld.x);
  float shoreRadius = uIslandRadius + sin(angle * 5.0 + 0.4) * 0.09 + sin(angle * 9.0) * 0.06;
  if(uHasShoreProfile>0.5)shoreRadius=texture2D(uShoreProfile,vec2(fract(angle/6.2831853+1.0+0.5/512.0),0.5)).r;
  float shoreDistance = length(vWorld.xz) - shoreRadius;
  float shallow = exp(-max(shoreDistance, 0.0) * 0.42);
  vec3 water = mix(uDeepColor, uShallowColor, shallow * 0.86);
  water *= 0.84 + 0.16 * max(dot(N, uSunDirection), 0.0);
  water += vec3(0.025, 0.075, 0.066) * max(vCrest + 0.1, 0.0);

  vec3 reflected = sky(R);
  vec2 reflectionUv = vReflection.xy / max(vReflection.w, 0.001);
  reflectionUv += N.xz * (0.013 + 0.015 * (1.0 - V.y));
  // Distortion can project outside the reflection capture at screen edges.
  // Fade over a broad margin instead of the old hard validity step, which
  // appeared as a jagged dark-blue frame following each tiny water normal.
  vec2 edgeDistance = min(reflectionUv, 1.0 - reflectionUv);
  float inBounds = smoothstep(0.0, 0.075, min(edgeDistance.x, edgeDistance.y));
  vec3 planar = texture2D(uReflection, clamp(reflectionUv, 0.002, 0.998)).rgb;
  // A planar capture contributes mainly island/character silhouettes; the sky
  // remains physically coherent even if a scene uses a solid background.
  reflected = mix(reflected, planar, inBounds * uReflectionReady * 0.30);
  vec3 color = mix(water, reflected, min(0.86, 0.075 + fresnel * 0.80));
  vec3 halfVector = normalize(V + uSunDirection);
  float spec = pow(max(dot(N, halfVector), 0.0), 360.0);
  float broadSpec = pow(max(dot(N, halfVector), 0.0), 55.0);
  color += vec3(1.0, 0.91, 0.72) * (spec * 2.05 + broadSpec * 0.10);

  // Moving, broken surf fronts. Each swell travels toward the island and
  // dissolves independently instead of drawing a permanent white outline.
  float breakerNoise = fbm(vWorld.xz * 1.65 + vec2(uTime * 0.18, -uTime * 0.11));
  float phase = shoreDistance * 3.5 + uTime * 2.2 + breakerNoise * 3.0;
  float breaker = pow(max(0.0, sin(phase)), 11.0);
  float surfZone = exp(-pow((shoreDistance - 0.7) / 1.10, 2.0));
  float broken = smoothstep(0.32, 0.62, breakerNoise);
  float wash = smoothstep(0.17, 0.42, sin(uTime * 1.55 + angle * 2.1 + breakerNoise * 5.0)) * exp(-max(shoreDistance, 0.0) * 3.6);
  float foam = max(breaker * surfZone * broken, wash * broken * 0.58);
  foam *= smoothstep(-0.3, 0.15, shoreDistance);
  float bubbles = smoothstep(0.43, 0.67, noise(vWorld.xz * 24.0 + uTime * 0.3));
  foam *= 0.50 + bubbles * 0.50;
  // A sparse amount of open-water crest froth, distinct from the near shore.
  float crestFoam = smoothstep(0.30, 0.38, vCrest) * smoothstep(0.68, 0.83, fbm(vWorld.xz * 2.2 - uTime * 0.1)) * 0.23;
  color = mix(color, vec3(0.88, 0.96, 0.95), clamp(foam * 0.82 + crestFoam, 0.0, 0.88));
  float haze = 1.0 - exp(-distanceToView * distanceToView * 0.000022);
  color = mix(color, vec3(0.36, 0.60, 0.71), haze * 0.52);
  // A small amount of near-shore transmission reveals the submerged rocks
  // and sand already present in the scene, while the deep ocean stays opaque.
  float opacity = mix(0.996, 0.76, shallow * (1.0 - fresnel));
  opacity = mix(opacity, 1.0, clamp(foam, 0.0, 1.0));
  gl_FragColor = vec4(color, opacity);
  #include <tonemapping_fragment>
  #include <colorspace_fragment>
}
`;
export class Ocean {
    mesh: THREE.Mesh<THREE.PlaneGeometry, THREE.ShaderMaterial>;
    private readonly scene: THREE.Scene;
    private readonly renderer: THREE.WebGLRenderer;
    private readonly reflectionCamera = new THREE.PerspectiveCamera();
    private readonly reflectionTarget = new THREE.WebGLRenderTarget(768, 512, { type: THREE.HalfFloatType, depthBuffer: true, stencilBuffer: false });
    private readonly textureMatrix = new THREE.Matrix4();
    private readonly rotationMatrix = new THREE.Matrix4();
    private readonly reflectorPlane = new THREE.Plane();
    private readonly planeNormal = new THREE.Vector3(0, 1, 0);
    private readonly mirrorPosition = new THREE.Vector3();
    private readonly viewPosition = new THREE.Vector3();
    private readonly view = new THREE.Vector3();
    private readonly look = new THREE.Vector3();
    private readonly target = new THREE.Vector3();
    private readonly clip = new THREE.Vector4();
    private readonly q = new THREE.Vector4();
    private readonly savedViewport = new THREE.Vector4();
    private readonly savedScissor = new THREE.Vector4();
    private lastReflectionTime = -Infinity;
    private waterY: number;
    private disposed = false;
    constructor(scene: THREE.Scene, renderer: THREE.WebGLRenderer, opts: {
        radius?: number;
        waterY?: number;
    } = {}) {
        this.scene = scene;
        this.renderer = renderer;
        this.waterY = opts.waterY ?? -1.7;
        this.reflectionTarget.texture.name = 'Ocean planar reflection';
        const geometry = new THREE.PlaneGeometry(280, 280, 280, 280);
        geometry.rotateX(-Math.PI / 2);
        const shader = new THREE.ShaderMaterial({
            uniforms: {
                uTime: { value: 0 }, uWaterY: { value: this.waterY },
                uIslandRadius: { value: opts.radius ?? 9.0 },
                uReflection: { value: this.reflectionTarget.texture },
                uReflectionReady: { value: 0 }, uShoreProfile: { value: null }, uHasShoreProfile: { value: 0 }, uTextureMatrix: { value: this.textureMatrix },
                uSunDirection: { value: new THREE.Vector3(-0.4, 0.8, 0.2).normalize() },
                uDeepColor: { value: new THREE.Color('#07577b') },
                uShallowColor: { value: new THREE.Color('#3fc3b0') },
            },
            vertexShader, fragmentShader, side: THREE.FrontSide, transparent: true, depthWrite: false,
        });
        this.mesh = new THREE.Mesh(geometry, shader);
        this.mesh.name = 'Ocean · moving swells and shoreline surf';
        this.mesh.position.y = this.waterY;
        this.mesh.frustumCulled = false;
        this.mesh.renderOrder = -1;
        scene.add(this.mesh);
    }
    sampleHeight(x: number, z: number, time: number): number { return sampleOceanHeight(x, z, time, this.waterY); }
    setShoreline(radii: number[]) { if (radii.length !== 512)
        return; const data = new Float32Array(radii); const texture = new THREE.DataTexture(data, 512, 1, THREE.RedFormat, THREE.FloatType); texture.wrapS = THREE.RepeatWrapping; texture.minFilter = THREE.LinearFilter; texture.magFilter = THREE.LinearFilter; texture.needsUpdate = true; this.mesh.material.uniforms.uShoreProfile.value = texture; this.mesh.material.uniforms.uHasShoreProfile.value = 1; }
    update(time: number, camera: THREE.PerspectiveCamera) {
        if (this.disposed)
            return;
        this.mesh.material.uniforms.uTime.value = time;
        // Reflection at ~12 fps; water itself stays at the full rendering rate.
        if ((time >= this.lastReflectionTime && time - this.lastReflectionTime < 0.08) || camera.position.y < this.waterY + 0.15)
            return;
        this.lastReflectionTime = time;
        const renderer = this.renderer;
        const mirrorCamera = this.reflectionCamera;
        camera.updateMatrixWorld();
        this.mirrorPosition.set(0, this.waterY, 0);
        this.viewPosition.setFromMatrixPosition(camera.matrixWorld);
        this.view.subVectors(this.mirrorPosition, this.viewPosition);
        this.view.reflect(this.planeNormal).negate().add(this.mirrorPosition);
        this.rotationMatrix.extractRotation(camera.matrixWorld);
        this.look.set(0, 0, -1).applyMatrix4(this.rotationMatrix).add(this.viewPosition);
        this.target.subVectors(this.mirrorPosition, this.look).reflect(this.planeNormal).negate().add(this.mirrorPosition);
        mirrorCamera.position.copy(this.view);
        mirrorCamera.up.set(0, 1, 0).applyMatrix4(this.rotationMatrix).reflect(this.planeNormal);
        mirrorCamera.lookAt(this.target);
        mirrorCamera.near = camera.near;
        mirrorCamera.far = camera.far;
        mirrorCamera.projectionMatrix.copy(camera.projectionMatrix);
        mirrorCamera.updateMatrixWorld();
        mirrorCamera.matrixWorldInverse.copy(mirrorCamera.matrixWorld).invert();
        this.textureMatrix.set(0.5, 0, 0, 0.5, 0, 0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0, 0, 0, 1);
        this.textureMatrix.multiply(mirrorCamera.projectionMatrix).multiply(mirrorCamera.matrixWorldInverse);
        // Lengyel oblique near-plane clipping: reflection must exclude everything
        // below the surface, particularly the undersea skirt of the island.
        this.reflectorPlane.setFromNormalAndCoplanarPoint(this.planeNormal, this.mirrorPosition);
        this.reflectorPlane.applyMatrix4(mirrorCamera.matrixWorldInverse);
        this.clip.set(this.reflectorPlane.normal.x, this.reflectorPlane.normal.y, this.reflectorPlane.normal.z, this.reflectorPlane.constant);
        const projection = mirrorCamera.projectionMatrix.elements;
        this.q.set((Math.sign(this.clip.x) + projection[8]) / projection[0], (Math.sign(this.clip.y) + projection[9]) / projection[5], -1, (1 + projection[10]) / projection[14]);
        this.clip.multiplyScalar(2 / this.clip.dot(this.q));
        projection[2] = this.clip.x;
        projection[6] = this.clip.y;
        projection[10] = this.clip.z + 1 - 0.003;
        projection[14] = this.clip.w;
        mirrorCamera.projectionMatrixInverse.copy(mirrorCamera.projectionMatrix).invert();
        const width = 768;
        const height = Math.max(256, Math.min(768, Math.round(width / camera.aspect)));
        if (this.reflectionTarget.height !== height)
            this.reflectionTarget.setSize(width, height);
        const previousTarget = renderer.getRenderTarget();
        const previousXr = renderer.xr.enabled;
        const previousShadow = renderer.shadowMap.autoUpdate;
        const previousScissorTest = renderer.getScissorTest();
        renderer.getViewport(this.savedViewport);
        renderer.getScissor(this.savedScissor);
        this.mesh.visible = false;
        renderer.xr.enabled = false;
        renderer.shadowMap.autoUpdate = false;
        renderer.setRenderTarget(this.reflectionTarget);
        renderer.setViewport(0, 0, width, height);
        renderer.setScissorTest(false);
        renderer.clear();
        renderer.render(this.scene, mirrorCamera);
        renderer.setRenderTarget(previousTarget);
        renderer.setViewport(this.savedViewport);
        renderer.setScissor(this.savedScissor);
        renderer.setScissorTest(previousScissorTest);
        renderer.xr.enabled = previousXr;
        renderer.shadowMap.autoUpdate = previousShadow;
        this.mesh.visible = true;
        this.mesh.material.uniforms.uReflectionReady.value = 1;
    }
    dispose() {
        if (this.disposed)
            return;
        this.disposed = true;
        this.scene.remove(this.mesh);
        this.mesh.geometry.dispose();
        this.mesh.material.uniforms.uShoreProfile.value?.dispose();
        this.mesh.material.dispose();
        this.reflectionTarget.dispose();
    }
}
