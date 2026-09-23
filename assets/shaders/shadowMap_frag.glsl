#version 330 core
// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

// The distant terrain casts its shadow through this pass too, and nowhere the game already draws the terrain: a
// column summarised from the generator may stand a block above the real ground and would shadow it. Zero for the
// chunks, which never set it.
uniform int distantTerrain;
uniform sampler2D distantHole;

in vec2 v_gridXZ;

void main() {
    if (distantTerrain == 1 && texelFetch(distantHole, ivec2(floor(v_gridXZ / 32.0)), 0).r > 0.5) {
        discard;
    }
}
