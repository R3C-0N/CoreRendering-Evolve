#version 330 core
// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

#ifdef BLOOM
uniform float bloomFactor;

uniform sampler2D texBloom;
#endif

uniform sampler2D texScene;
uniform vec3 inLiquidTint;

#ifdef LIGHT_SHAFTS
uniform sampler2D texLightShafts;
#endif

in vec2 v_uv0;

layout(location = 0) out vec4 outColor;

void main() {

    vec4 color = texture(texScene, v_uv0.xy);
#ifdef LIGHT_SHAFTS
    vec4 colorShafts = texture(texLightShafts, v_uv0.xy);
    color.rgb += colorShafts.rgb;
#endif

#ifdef BLOOM
    vec4 colorBloom = texture(texBloom, v_uv0.xy);
    color += colorBloom * bloomFactor;
#endif

    // Under a liquid, the light that reaches the eye has taken the liquid's colour. Only its hue: the exposure has
    // already been measured, so a raw tint of a tenth would black the view out rather than colour it.
    if (swimming) {
        float strongest = max(max(inLiquidTint.r, inLiquidTint.g), max(inLiquidTint.b, 0.0001));
        color.rgb *= inLiquidTint / strongest;
    }

    outColor.rgba = color.rgba;
}
