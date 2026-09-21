// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

package org.terasology.corerendering.rendering.utils;

import org.joml.RoundingMode;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.joml.Vector3i;
import org.terasology.corerendering.rendering.dag.nodes.RefractiveReflectiveBlocksNode;
import org.terasology.engine.config.RenderingConfig;
import org.terasology.engine.rendering.primitives.WaterDepthField;
import org.terasology.engine.world.WorldProvider;
import org.terasology.engine.world.block.Block;

/**
 * Whether the camera is under a liquid, decided against the surface as it is drawn.
 * <p>
 * The water surface is displaced in chunk_vert, and since the swell depends on the depth under the surface that
 * displacement is no longer a function of the position alone: out at sea it is the full swell, over the sand it is
 * a slow calm. A verdict taken against the full swell everywhere puts the camera under water up to two blocks above
 * the drawn surface of a shallow, and every underwater effect flickers with it. So the CPU redraws the same surface:
 * the same depth level, the same crossfade, and the same interpolation between the corners of a block.
 */
public final class UnderwaterHelper {

    // Parameters which are also defined on shader side
    private static final int OCEAN_OCTAVES = 16;
    private static final Vector2f[] OCEAN_WAVE_DIRECTIONS = {
            new Vector2f(-0.613392f, 0.617481f),
            new Vector2f(0.170019f, -0.040254f),
            new Vector2f(-0.299417f, 0.791925f),
            new Vector2f(0.645680f, 0.493210f),
            new Vector2f(-0.651784f, 0.717887f),
            new Vector2f(0.421003f, 0.027070f),
            new Vector2f(-0.817194f, -0.271096f),
            new Vector2f(-0.705374f, -0.668203f),
            new Vector2f(0.977050f, -0.108615f),
            new Vector2f(0.063326f, 0.142369f),
            new Vector2f(0.203528f, 0.214331f),
            new Vector2f(-0.667531f, 0.326090f),
            new Vector2f(-0.098422f, -0.295755f),
            new Vector2f(-0.885922f, 0.215369f),
            new Vector2f(0.566637f, 0.605213f),
            new Vector2f(0.039766f, -0.396100f)
    };

    private static final int RANGE = (int) WaterDepthField.RANGE;

    private static final int[][] GROUP = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};

    // The depth levels of the four columns around the camera, kept while it stays over the same columns and the
    // same surface: the levels do not move with time, only the waves on them do.
    private static final float[] LEVELS = new float[4];
    private static int levelsX = Integer.MIN_VALUE;
    private static int levelsZ = Integer.MIN_VALUE;
    private static int levelsSurface = Integer.MIN_VALUE;

    private UnderwaterHelper() {
    }

    // Various functions that are also available on the shader side but need to be
    // evaluated on the CPU
    public static float smoothCurve(float x) {
        return x * x * (3.f - 2.0f * x);
    }

    public static float triangleWave(float x) {
        float normX = x + 0.5f;
        float fract = normX - (float) Math.floor(normX);
        return Math.abs(fract * 2.0f - 1.0f);
    }

    public static float smoothTriangleWave(float x) {
        return smoothCurve(triangleWave(x)) * 2.0f - 1.0f;
    }

    public static float timeToTick(float time, float speed) {
        return time * 4000.0f * speed;
    }

    /** The open sea swell, offset included, as chunk_vert draws it at full strength. */
    public static float evaluateOceanHeightAtPosition(Vector3fc position, float days) {
        return swellHeight(position.x(), position.z(), days) + RefractiveReflectiveBlocksNode.waterOffsetY;
    }

    public static boolean isUnderwater(Vector3fc pos, WorldProvider worldProvider, RenderingConfig config) {
        return liquidAtCamera(pos, worldProvider, config) != null;
    }

    /**
     * The liquid block the camera is in once the drawn surface has been taken into account, or null.
     */
    public static Block liquidAtCamera(Vector3fc pos, WorldProvider worldProvider, RenderingConfig config) {
        Vector3i at = new Vector3i(pos, RoundingMode.HALF_UP);
        if (!config.isAnimateWater()) {
            return liquidAt(worldProvider, at);
        }

        // The surface only ever moves within a known band: when that band is all liquid or all dry, nothing needs
        // to be drawn to answer.
        float offset = RefractiveReflectiveBlocksNode.waterOffsetY;
        float swellReach = swellReach();
        float shallowReach = 0.5f * RefractiveReflectiveBlocksNode.shallowSwellScale;
        float lowest = Math.min(-3.0f * swellReach, -shallowReach) + offset;
        float highest = Math.max(swellReach, shallowReach) + offset;
        int bottom = Math.round(pos.y() - highest);
        int top = Math.round(pos.y() - lowest);

        Vector3i probe = new Vector3i();
        Block first = liquidAt(worldProvider, probe.set(at.x, top, at.z));
        boolean mixed = false;
        int surface = Integer.MIN_VALUE;
        boolean aboveIsLiquid = liquidAt(worldProvider, probe.set(at.x, top + 1, at.z)) != null;
        for (int y = top; y >= bottom; y--) {
            boolean isLiquid = liquidAt(worldProvider, probe.set(at.x, y, at.z)) != null;
            mixed |= isLiquid != (first != null);
            if (isLiquid && !aboveIsLiquid && surface == Integer.MIN_VALUE) {
                surface = y;
            }
            aboveIsLiquid = isLiquid;
        }
        if (!mixed) {
            return first;
        }
        if (surface == Integer.MIN_VALUE) {
            // Liquid above and dry below: the underside of the water, which the swell does not move.
            return liquidAt(worldProvider, at);
        }

        float height = drawnHeight(worldProvider, pos.x(), pos.z(), at.x, at.z, surface,
                worldProvider.getTime().getDays()) + offset;
        return liquidAt(worldProvider, new Vector3i(new Vector3f(pos.x(), pos.y() - height, pos.z()),
                RoundingMode.HALF_UP));
    }

    private static Block liquidAt(WorldProvider worldProvider, Vector3i pos) {
        if (!worldProvider.isBlockRelevant(pos)) {
            return null;
        }
        Block block = worldProvider.getBlock(pos);
        return block.isLiquid() ? block : null;
    }

    /**
     * The height of the drawn surface over the camera, offset excluded. A surface vertex sits on a block corner and
     * takes the level of the column half a block before it (see BlockMeshPart), so the corner at x + 0.5 takes
     * column x exactly; between the corners the top face is interpolated.
     */
    private static float drawnHeight(WorldProvider worldProvider, float x, float z, int blockX, int blockZ,
                                     int surface, float days) {
        float[] levels = levelsAround(worldProvider, blockX - 1, blockZ - 1, surface);
        float fx = x - (blockX - 0.5f);
        float fz = z - (blockZ - 0.5f);
        float h00 = cornerHeight(blockX - 0.5f, blockZ - 0.5f, levels[0], days);
        float h10 = cornerHeight(blockX + 0.5f, blockZ - 0.5f, levels[1], days);
        float h01 = cornerHeight(blockX - 0.5f, blockZ + 0.5f, levels[2], days);
        float h11 = cornerHeight(blockX + 0.5f, blockZ + 0.5f, levels[3], days);
        float near = h00 + (h10 - h00) * fx;
        float far = h01 + (h11 - h01) * fx;
        return near + (far - near) * fz;
    }

    /**
     * What chunk_vert does at one vertex: the calm, the swell, and the crossfade between them by depth.
     *
     * TODO: this ignores the slope the mesher now gives a flowing surface. It already reads nought where the drawn
     *   surface stands at 0.4, so it has always been a tenth of a block optimistic; a flowing column lowers the
     *   drawn top by up to three quarters of a block and widens that to the same degree. Adding
     *   {@code LiquidSurfaceField.cornerHeight} here would close both at once - the arithmetic was deliberately
     *   left as a static function of plain arrays so this side could call it. Not yet done because every generated
     *   sea block is a source and so is drawn exactly where this expects it: the gap needs water a player has made
     *   run, and an eye right on its waterline.
     */
    private static float cornerHeight(float x, float z, float level, float days) {
        // The level reaches the vertex as a byte, so it is quantised the same way here.
        float quantised = Math.round(Math.min(1.0f, level / WaterDepthField.RANGE) * 127.0f) / 127.0f
                * WaterDepthField.RANGE;
        float weight = smoothstep(1.0f, Math.max(RefractiveReflectiveBlocksNode.swellFullLevel, 1.5f), quantised);
        float shallow = shallowHeight(x, z, days);
        return shallow + (swellHeight(x, z, days) - shallow) * weight;
    }

    private static float swellHeight(float x, float z, float days) {
        float height = 0.0f;

        float waveSize = RefractiveReflectiveBlocksNode.waveSize;
        float waveIntensity = RefractiveReflectiveBlocksNode.waveIntensity;
        float timeFactor = RefractiveReflectiveBlocksNode.waveSpeed;

        for (int i = 0; i < OCEAN_OCTAVES; ++i) {
            height += (smoothTriangleWave(timeToTick(days, timeFactor)
                    + x * OCEAN_WAVE_DIRECTIONS[i].x * waveSize
                    + z * OCEAN_WAVE_DIRECTIONS[i].y * waveSize) * 2.0f - 1.0f) * waveIntensity;

            waveSize *= RefractiveReflectiveBlocksNode.waveSizeFalloff;
            waveIntensity *= RefractiveReflectiveBlocksNode.waveIntensityFalloff;
            timeFactor *= RefractiveReflectiveBlocksNode.waveSpeedFalloff;
        }

        return height / OCEAN_OCTAVES * RefractiveReflectiveBlocksNode.waveOverallScale;
    }

    /** How far above nought the swell can rise. Each octave spans [-3, 1], so it can sink three times as far. */
    private static float swellReach() {
        float sum = 0.0f;
        float waveIntensity = RefractiveReflectiveBlocksNode.waveIntensity;
        for (int i = 0; i < OCEAN_OCTAVES; ++i) {
            sum += waveIntensity;
            waveIntensity *= RefractiveReflectiveBlocksNode.waveIntensityFalloff;
        }
        return Math.abs(sum / OCEAN_OCTAVES * RefractiveReflectiveBlocksNode.waveOverallScale);
    }

    private static float shallowHeight(float x, float z, float days) {
        float speed = RefractiveReflectiveBlocksNode.shallowSwellSpeed;
        float size = RefractiveReflectiveBlocksNode.shallowSwellSize;
        float a = smoothTriangleWave(timeToTick(days, speed) + (x * 0.62f + z * 0.78f) * size);
        float b = smoothTriangleWave(timeToTick(days, speed * 0.63f) + (x * -0.81f + z * 0.59f) * size);
        return (a + b) * 0.25f * RefractiveReflectiveBlocksNode.shallowSwellScale;
    }

    private static float smoothstep(float edge0, float edge1, float x) {
        float t = Math.min(Math.max((x - edge0) / (edge1 - edge0), 0.0f), 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    /**
     * The depth levels of columns (x0, z0), (x0 + 1, z0), (x0, z0 + 1) and (x0 + 1, z0 + 1) under a surface, as
     * WaterDepthField computes them for a whole chunk: the smallest, over every column in range, of its depth plus
     * how far away it is. Walked ring by ring around the four columns: a ring k blocks out can only contribute k or
     * more, so the walk stops once that can no longer lower any of them.
     */
    private static float[] levelsAround(WorldProvider worldProvider, int x0, int z0, int surface) {
        if (x0 == levelsX && z0 == levelsZ && surface == levelsSurface) {
            return LEVELS;
        }
        int[] best = {RANGE, RANGE, RANGE, RANGE};
        int[] distances = new int[4];
        Vector3i probe = new Vector3i();
        for (int ring = 0; ring < max(best); ring++) {
            for (int dz = -ring; dz <= 1 + ring; dz++) {
                for (int dx = -ring; dx <= 1 + ring; dx++) {
                    if (dx != -ring && dx != 1 + ring && dz != -ring && dz != 1 + ring) {
                        continue;
                    }
                    int limit = 0;
                    for (int m = 0; m < 4; m++) {
                        distances[m] = Math.max(Math.abs(dx - GROUP[m][0]), Math.abs(dz - GROUP[m][1]));
                        limit = Math.max(limit, best[m] - distances[m]);
                    }
                    if (limit <= 0) {
                        continue;
                    }
                    int depth = depth(worldProvider, x0 + dx, surface, z0 + dz, limit, probe);
                    for (int m = 0; m < 4; m++) {
                        best[m] = Math.min(best[m], depth + distances[m]);
                    }
                }
            }
        }
        for (int m = 0; m < 4; m++) {
            LEVELS[m] = best[m];
        }
        levelsX = x0;
        levelsZ = z0;
        levelsSurface = surface;
        return LEVELS;
    }

    private static int depth(WorldProvider worldProvider, int x, int top, int z, int limit, Vector3i probe) {
        int count = 0;
        while (count < limit && liquidAt(worldProvider, probe.set(x, top - count, z)) != null) {
            count++;
        }
        return count;
    }

    private static int max(int[] values) {
        int result = values[0];
        for (int value : values) {
            result = Math.max(result, value);
        }
        return result;
    }
}
