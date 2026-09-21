#version 330 core
// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

#ifdef FEATURE_REFRACTIVE_PASS
out vec3 waterNormalViewSpace;
#endif

#if defined (ANIMATED_WATER) && defined (FEATURE_REFRACTIVE_PASS)
const vec3 normalDiffOffset = vec3(-1.0, 0.0, 1.0);
const vec2 normalDiffSize = vec2(2.0, 0.0);

uniform float waveIntensityFalloff;
uniform float waveSizeFalloff;
uniform float waveSpeedFalloff;
uniform float waveSize;
uniform float waveIntensity;
uniform float waveSpeed;
uniform float waterOffsetY;
uniform float waveOverallScale;

// -- Depth -------------------------------------------------------------------------------------
//
// The swell above is a function of the world position alone, so it travels the same eight tenths of a block in the
// open sea and in a hand of water over the sand. A wave carries the column of water beneath it: where the column
// runs out the wave has to run out with it, or the beach heaves like the ocean. Every water surface vertex therefore
// carries the depth under it, measured straight down by WaterDepthField, and the swell is faded out with it.
//
// Both the height and the normal are faded, and that matters: a surface that is flat but still lit as though it
// were rolling reads as rolling.
// Calm water is not the swell made small. The sixteen octaves all turn at about the same rate, so scaling them
// down leaves water that flickers quietly instead of water that is still; and the rate cannot be slowed with the
// depth either, since a speed that varies across the ground multiplies the time into the phase gradient and the
// surface tears. So the shallows get their own wave: two octaves, long and slow, crossfaded against the swell.
uniform float waterDepthRange;     // levels the depth byte spans; must match WaterDepthField.RANGE
uniform float swellFullLevel;      // level at which the swell is at its full, open sea strength
uniform float shallowSwellSpeed;   // pace of the calm water, against waveSpeed for the open sea
uniform float shallowSwellSize;    // its spatial frequency, so the inverse of its wavelength
uniform float shallowSwellScale;   // how far it travels, in blocks, crest to trough

const vec2[] waveDirections = vec2[](
    vec2(-0.613392, 0.617481),
    vec2(0.170019, -0.040254),
    vec2(-0.299417, 0.791925),
    vec2(0.645680, 0.493210),
    vec2(-0.651784, 0.717887),
    vec2(0.421003, 0.027070),
    vec2(-0.817194, -0.271096),
    vec2(-0.705374, -0.668203),
    vec2(0.977050, -0.108615),
    vec2(0.063326, 0.142369),
    vec2(0.203528, 0.214331),
    vec2(-0.667531, 0.326090),
    vec2(-0.098422, -0.295755),
    vec2(-0.885922, 0.215369),
    vec2(0.566637, 0.605213),
    vec2(0.039766, -0.396100)
);

float calcWaterHeightAtOffset(vec2 worldPos) {
    float height = 0.0;

    float size = waveSize;
    float intens = waveIntensity;
    float timeFactor = waveSpeed;
    for (int i=0; i<OCEAN_OCTAVES; ++i) {
        height += (smoothTriangleWave(timeToTick(time, timeFactor) + worldPos.x * waveDirections[i].x
            * size + worldPos.y * waveDirections[i].y * size) * 2.0 - 1.0) * intens;

        size *= waveSizeFalloff;
        intens *= waveIntensityFalloff;
        timeFactor *= waveSpeedFalloff;
    }

    return (height / float(OCEAN_OCTAVES)) * waveOverallScale;
}

// The calm of the shallows: two long slow octaves, crossing each other so the surface breathes rather than beats.
float calcShallowHeightAtOffset(vec2 worldPos) {
    float a = smoothTriangleWave(timeToTick(time, shallowSwellSpeed)
        + (worldPos.x * 0.62 + worldPos.y * 0.78) * shallowSwellSize);
    float b = smoothTriangleWave(timeToTick(time, shallowSwellSpeed * 0.63)
        + (worldPos.x * -0.81 + worldPos.y * 0.59) * shallowSwellSize);
    return (a + b) * 0.25 * shallowSwellScale;
}

// What the water actually does here: the swell out at sea, the calm in the shallows, and the crossfade between.
// The weight is taken as constant over the block-wide neighbourhood the normal is built from, which it very nearly
// is — the level climbs at most one per block, by construction.
float calcHeightAtOffset(vec2 worldPos, float swellWeight) {
    return mix(calcShallowHeightAtOffset(worldPos), calcWaterHeightAtOffset(worldPos), swellWeight);
}

vec4 calcWaterNormalAndOffset(vec2 worldPosRaw, float swellWeight) {
    float s11 = calcHeightAtOffset(worldPosRaw.xy, swellWeight);
    float s01 = calcHeightAtOffset(worldPosRaw.xy + normalDiffOffset.xy, swellWeight);
    float s21 = calcHeightAtOffset(worldPosRaw.xy + normalDiffOffset.zy, swellWeight);
    float s10 = calcHeightAtOffset(worldPosRaw.xy + normalDiffOffset.yx, swellWeight);
    float s12 = calcHeightAtOffset(worldPosRaw.xy + normalDiffOffset.yz, swellWeight);

    vec3 va = normalize(vec3(normalDiffSize.x, s21-s01, normalDiffSize.y));
    vec3 vb = normalize(vec3(normalDiffSize.y, s10-s12, -normalDiffSize.x));

    return vec4(cross(va,vb), s11);
}
#endif

#if defined (FLICKERING_LIGHT)
out float flickeringLightOffset;
#endif

#if defined (NORMAL_MAPPING)
out vec3 worldSpaceNormal;
#endif

uniform float blockScale = 1.0;
uniform vec3 chunkPositionWorld;

// waving blocks
uniform bool animated;

uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;

out vec3 normal;

out vec3 vertexWorldPos;
out vec4 vertexViewPos;
out vec4 vertexProjPos;

out vec3 sunVecView;

out vec2 v_uv0;
out float v_sunlight;
out float v_blocklight;
out float v_ambientLight;
// The warm share of the block light, nought to one. Zero everywhere no lava shines, which is what keeps every
// torch lit surface bit identical to what it was before lava had a colour of its own.
out float v_warmth;
// The raw grid normal, which is not the one the sphere turns: the block a fragment belongs to is a fact about the
// grid, and vertexWorldPos below is deliberately kept flat for the same reason. worldSpaceNormal is no use here,
// it only exists under NORMAL_MAPPING and it has been through the surface frame. Flat because a face has one
// normal, so interpolating it would only cost and add noise at the edges.
flat out vec3 v_gridNormal;
flat out int isUpside;
flat out int v_blockHint;
out vec4 v_colorOffset;

layout (location = 0) in vec3 in_vert;
layout (location = 1) in vec3 in_normal;
layout (location = 2) in vec2 in_uv0;

layout (location = 3) in int in_flags;
layout (location = 4) in float in_frames;

layout (location = 5) in float in_sunlight;
layout (location = 6) in float in_blocklight;
layout (location = 7) in float in_ambientlight;

layout (location = 8) in vec4 colorOffset;

// The depth under a water surface vertex, nought to a hundred and twenty seven over waterDepthRange blocks, and
// nought on anything that is not a water surface.
layout (location = 9) in float in_waterDepth;

// How much of the block light at this vertex comes from lava, nought to a hundred and twenty seven.
layout (location = 10) in float in_warmth;

void main() {

    v_uv0 = in_uv0;
    v_sunlight = in_sunlight;
    v_blocklight = in_blocklight;
    v_ambientLight = in_ambientlight;
    v_warmth = in_warmth / 127.0;
    v_gridNormal = in_normal;
    v_blockHint = in_flags;
    v_colorOffset = colorOffset;
    // On a flat world this is exactly modelViewMatrix * vec4(in_vert, 1.0); on a curved one the
    // vertex is placed where the world actually is. vertexWorldPos stays flat on purpose: the
    // waving grass, the water waves and the noise downstream all want grid coordinates.
    vertexViewPos = sphereViewPos(in_vert, chunkPositionWorld.xyz, modelViewMatrix);
    vertexWorldPos = in_vert + chunkPositionWorld.xyz;

    if (in_frames > 0) {
        float globalFrameIndex = floor(time * 6 *60*60*24/48); // 6Hz at default world time scale
        float frameIndex = mod(globalFrameIndex, in_frames);
        float frame_x = in_uv0.x + (frameIndex * TEXTURE_OFFSET);
        v_uv0.y = in_uv0.y + floor(frame_x) * TEXTURE_OFFSET;
        v_uv0.x = mod(frame_x, 1);
    }

    sunVecView = (modelViewMatrix * vec4(sunVec.x, sunVec.y, sunVec.z, 0.0)).xyz;

    isUpside = in_normal.y > 0.9 ? 1 : 0;

    // The local frame turns with distance on a curved world, by d over R: eleven degrees at a
    // thousand blocks. Left alone, the far ground would be lit as though it were flat.
    mat3 surfaceFrame = sphereEnabled == 0 ? mat3(1.0) : sphereFrame(in_vert + chunkPositionWorld.xyz);
#if defined (NORMAL_MAPPING)
    worldSpaceNormal = surfaceFrame * in_normal;
#endif
    normal = normalMatrix * surfaceFrame * in_normal;


#ifdef FLICKERING_LIGHT
    flickeringLightOffset = smoothTriangleWave(timeToTick(time, 0.5)) / 16.0;
    flickeringLightOffset += smoothTriangleWave(timeToTick(time, 0.25) + 0.3762618) / 8.0;
    flickeringLightOffset += smoothTriangleWave(timeToTick(time, 0.1) + 0.872917) / 4.0;
#endif

#ifdef ANIMATED_GRASS
    if (animated) {
        // GRASS ANIMATION
        if (v_blockHint == BLOCK_HINT_WAVING) {
           // Only animate the upper two vertices
           if (mod(v_uv0.y, TEXTURE_OFFSET) < TEXTURE_OFFSET / 2.0) {
               vertexViewPos.x += (smoothTriangleWave(timeToTick(time, 0.2) + vertexWorldPos.x * 0.1 + vertexWorldPos.z * 0.1) * 2.0 - 1.0) * 0.1 * blockScale;
               vertexViewPos.y += (smoothTriangleWave(timeToTick(time, 0.1) + vertexWorldPos.x * -0.5 + vertexWorldPos.z * -0.5) * 2.0 - 1.0) * 0.05 * blockScale;
           }
        } else if (v_blockHint == BLOCK_HINT_WAVING_BLOCK) {
            vertexViewPos.x += (smoothTriangleWave(timeToTick(time, 0.1) + vertexWorldPos.x * 0.01 + vertexWorldPos.z * 0.01) * 2.0 - 1.0) * 0.01 * blockScale;
            vertexViewPos.y += (smoothTriangleWave(timeToTick(time, 0.15) + vertexWorldPos.x * -0.01 + vertexWorldPos.z * -0.01) * 2.0 - 1.0) * 0.05 * blockScale;
            vertexViewPos.z += (smoothTriangleWave(timeToTick(time, 0.1) + vertexWorldPos.x * -0.01 + vertexWorldPos.z * -0.01) * 2.0 - 1.0) * 0.01 * blockScale;
        }
    }
#endif

#if defined (FEATURE_REFRACTIVE_PASS)
    #if defined (ANIMATED_WATER)
        if (v_blockHint == BLOCK_HINT_WATER_SURFACE && isUpside == 1) {
            // From the calm of the waterline to the whole swell out at sea, over the levels between. The level is
            // built so that it climbs one at a time, so this ramp is spread over the ground whatever the bottom does.
            float depthLevel = in_waterDepth / 127.0 * waterDepthRange;
            float swellWeight = smoothstep(1.0, max(swellFullLevel, 1.5), depthLevel);

            // The normal comes out of the same crossfade, so flat water is also lit as flat water. Lit as though it
            // were rolling, it reads as rolling however little it moves.
            vec4 normalAndOffset = calcWaterNormalAndOffset(vertexWorldPos.xz, swellWeight);

            // Through the same frame as the opaque normal, or flat water would be lit as though the
            // world were flat while the ground beside it is not.
            waterNormalViewSpace = normalMatrix * surfaceFrame * normalAndOffset.xyz;
            // Along the local up, which on a curved world is the radial direction and not the world
            // Y axis. surfaceFrame[1] is that up; the two agree under the camera and part company
            // with distance, which is why the far sea used to sink under its own bed.
            vertexViewPos.xyz += mat3(modelViewMatrix) * surfaceFrame[1] * (normalAndOffset.w + waterOffsetY);
        }
    #else
        waterNormalViewSpace = normalMatrix * surfaceFrame * vec3(0.0, 1.0, 0.0);
    #endif
#endif

    vertexProjPos = projectionMatrix * vertexViewPos;
    gl_Position = vertexProjPos;

#if defined (FEATURE_ALPHA_REJECT)
    //TODO: find the right methods to determine which vertices have normals facing away from the viewpoint, and only alter those
    //if (normal.x * vertexViewPos.x < 0 || normal.y * vertexViewPos.y < 0 || normal.z * vertexViewPos.z < 0) {
        gl_Position.z -= 0.001;
    //}
#endif
}
