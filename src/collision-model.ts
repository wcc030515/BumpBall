/** Horizontal collision calibration, ported from native collision_model.gd. */
export interface Vector3 {
    x: number;
    y: number;
    z: number;
}
export interface MotionChannel {
    driveVelocity: Vector3;
    responseVelocity: Vector3;
    normal: Vector3;
    preserveDrive: boolean;
    mode: string;
}
export const RESTITUTION = 1;
export const SLIDE_DECELERATION = 3.6;
export const MIN_DISTANCE = 1.3;
export const MAX_DISTANCE = 8;
const ZERO_SPEED = .0001;
const vec = (x: number, z: number): Vector3 => ({ x, y: 0, z });
const outwardDistance = (response: number, first: boolean) => (first ? response >= -ZERO_SPEED : response <= ZERO_SPEED) ? 0 : response * response / (2 * SLIDE_DECELERATION);
const scaleResponse = (response: number, first: boolean, scale: number) => scale < 1 || outwardDistance(response, first) > 0 ? response * scale : response;
export function solveCollision(velocityA: Vector3, velocityB: Vector3, massA: number, massB: number, normal: Vector3, physicsHz = 120) {
    const length = Math.hypot(normal.x, normal.z);
    const n = length > .0001 ? vec(normal.x / length, normal.z / length) : vec(1, 0);
    const ma = Math.max(massA, .01), mb = Math.max(massB, .01);
    const beforeA = velocityA.x * n.x + velocityA.z * n.z;
    const beforeB = velocityB.x * n.x + velocityB.z * n.z;
    const closingSpeed = Math.max(0, beforeA - beforeB);
    const impulse = (1 + RESTITUTION) * closingSpeed / (1 / ma + 1 / mb);
    const deltaA = impulse / ma, deltaB = impulse / mb;
    const rawAfterA = beforeA - deltaA, rawAfterB = beforeB + deltaB;
    let commonDrive = 0;
    if (beforeA > ZERO_SPEED && beforeB > ZERO_SPEED)
        commonDrive = Math.min(beforeA, beforeB);
    else if (beforeA < -ZERO_SPEED && beforeB < -ZERO_SPEED)
        commonDrive = Math.max(beforeA, beforeB);
    let responseA = rawAfterA - commonDrive, responseB = rawAfterB - commonDrive;
    if (Math.abs(responseA) <= ZERO_SPEED)
        responseA = 0;
    if (Math.abs(responseB) <= ZERO_SPEED)
        responseB = 0;
    const pairDistance = Math.max(outwardDistance(responseA, true), outwardDistance(responseB, false));
    const pairScale = pairDistance > 0 ? Math.sqrt(Math.min(MAX_DISTANCE, Math.max(MIN_DISTANCE, pairDistance)) / pairDistance) : 1;
    const nominalA = scaleResponse(responseA, true, pairScale), nominalB = scaleResponse(responseB, false, pairScale);
    const distanceA = outwardDistance(nominalA, true), distanceB = outwardDistance(nominalB, false);
    const nativeContactBudgetA = 2 * deltaA / (1 + RESTITUTION) / Math.max(1, physicsHz) + .02;
    const nativeContactBudgetB = 2 * deltaB / (1 + RESTITUTION) / Math.max(1, physicsHz) + .02;
    let contactScale = 1;
    if (distanceA > 0)
        contactScale = Math.min(contactScale, Math.sqrt(Math.max(MIN_DISTANCE, MAX_DISTANCE - nativeContactBudgetA) / distanceA));
    if (distanceB > 0)
        contactScale = Math.min(contactScale, Math.sqrt(Math.max(MIN_DISTANCE, MAX_DISTANCE - nativeContactBudgetB) / distanceB));
    const appliedA = nominalA * contactScale, appliedB = nominalB * contactScale;
    const afterA = commonDrive + appliedA, afterB = commonDrive + appliedB;
    const baselineA = vec(velocityA.x, velocityA.z), baselineB = vec(velocityB.x, velocityB.z);
    const driveA = vec(baselineA.x + n.x * (commonDrive - beforeA), baselineA.z + n.z * (commonDrive - beforeA));
    const driveB = vec(baselineB.x + n.x * (commonDrive - beforeB), baselineB.z + n.z * (commonDrive - beforeB));
    const preserveDrive = Math.abs(commonDrive) > ZERO_SPEED;
    const mode = preserveDrive ? 'shared_drive' : 'full_response';
    return {
        closingSpeed, impulse, distanceA, distanceB,
        appliedDistanceA: outwardDistance(appliedA, true), appliedDistanceB: outwardDistance(appliedB, false),
        nativeContactBudgetA, nativeContactBudgetB,
        normalBeforeA: beforeA, normalBeforeB: beforeB, normalAfterA: afterA, normalAfterB: afterB,
        rawNormalAfterA: rawAfterA, rawNormalAfterB: rawAfterB,
        outwardA: appliedA < -ZERO_SPEED, outwardB: appliedB > ZERO_SPEED,
        kickA: vec(n.x * (afterA - beforeA), n.z * (afterA - beforeA)),
        kickB: vec(n.x * (afterB - beforeB), n.z * (afterB - beforeB)),
        baselineA, baselineB, pairScale, sharedScale: pairScale * contactScale,
        nativeContactScale: contactScale, commonDrive, responseMode: mode,
        duration: Math.max(Math.abs(appliedA), Math.abs(appliedB)) / SLIDE_DECELERATION, normal: n,
        channelA: { driveVelocity: driveA, responseVelocity: vec(n.x * appliedA, n.z * appliedA), normal: n, preserveDrive, mode } as MotionChannel,
        channelB: { driveVelocity: driveB, responseVelocity: vec(n.x * appliedB, n.z * appliedB), normal: n, preserveDrive, mode } as MotionChannel,
    };
}
