/** The same approved, Y-up stage geometry used by the native Godot arena. */
export interface StageGeometryData {
    outline_xz: number[][];
    surface_vertices_xyz: number[][];
    surface_triangles: number[][];
    max_outline_radius_m?: number;
    shoreline_radii?: number[];
    [key: string]: unknown;
}
export class StageGeometry {
    readonly outline: ReadonlyArray<readonly [
        number,
        number
    ]>;
    readonly vertices: Float32Array;
    readonly indices: Uint32Array;
    readonly maxRadius: number;
    constructor(readonly data: StageGeometryData) {
        if (!data || !Array.isArray(data.outline_xz) || data.outline_xz.length < 3 ||
            !Array.isArray(data.surface_vertices_xyz) || !Array.isArray(data.surface_triangles)) {
            throw new Error('海岛场地几何数据缺失或无效');
        }
        this.outline = data.outline_xz.map(p => {
            if (p.length < 2 || !p.slice(0, 2).every(Number.isFinite))
                throw new Error('无效的海岛边缘坐标');
            return [p[0], p[1]] as const;
        });
        for (const p of data.surface_vertices_xyz) {
            if (p.length !== 3 || !p.every(Number.isFinite))
                throw new Error('无效的海岛表面顶点');
        }
        for (const t of data.surface_triangles) {
            if (t.length !== 3 || !t.every(i => Number.isInteger(i) && i >= 0 && i < data.surface_vertices_xyz.length)) {
                throw new Error('无效的海岛表面三角形');
            }
        }
        this.vertices = new Float32Array(data.surface_vertices_xyz.flat());
        this.indices = new Uint32Array(data.surface_triangles.flat());
        this.maxRadius = Number(data.max_outline_radius_m) || Math.max(...this.outline.map(p => Math.hypot(...p)));
    }
    containsPoint(x: number, z: number): boolean {
        let inside = false;
        for (let i = 0, j = this.outline.length - 1; i < this.outline.length; j = i++) {
            const a = this.outline[j], b = this.outline[i];
            if (this.segmentDistanceSquared(x, z, a, b) <= 1e-10)
                return true;
            if ((a[1] > z) !== (b[1] > z) && x < (b[0] - a[0]) * (z - a[1]) / (b[1] - a[1]) + a[0])
                inside = !inside;
        }
        return inside;
    }
    signedEdgeDistance(x: number, z: number): number {
        let distanceSquared = Infinity;
        for (let i = 0; i < this.outline.length; i++) {
            distanceSquared = Math.min(distanceSquared, this.segmentDistanceSquared(x, z, this.outline[i], this.outline[(i + 1) % this.outline.length]));
        }
        return Math.sqrt(distanceSquared) * (this.containsPoint(x, z) ? 1 : -1);
    }
    boundaryDistance(x: number, z: number): number {
        const length = Math.hypot(x, z);
        if (length < 1e-5)
            return 0;
        const rx = x / length, rz = z / length;
        let distance = Infinity;
        for (let i = 0; i < this.outline.length; i++) {
            const a = this.outline[i], b = this.outline[(i + 1) % this.outline.length];
            const ex = b[0] - a[0], ez = b[1] - a[1];
            const denominator = rx * ez - rz * ex;
            if (Math.abs(denominator) < 1e-7)
                continue;
            const rayT = (a[0] * ez - a[1] * ex) / denominator;
            const segmentT = (a[0] * rz - a[1] * rx) / denominator;
            if (rayT >= 0 && segmentT >= -1e-5 && segmentT <= 1 + 1e-5)
                distance = Math.min(distance, rayT);
        }
        return Number.isFinite(distance) ? distance : 0;
    }
    private segmentDistanceSquared(x: number, z: number, a: readonly number[], b: readonly number[]): number {
        const dx = b[0] - a[0], dz = b[1] - a[1];
        const square = dx * dx + dz * dz;
        const t = square > 0 ? Math.min(1, Math.max(0, ((x - a[0]) * dx + (z - a[1]) * dz) / square)) : 0;
        return (x - a[0] - dx * t) ** 2 + (z - a[1] - dz * t) ** 2;
    }
}
