#version 330 core
// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

layout (location = 0) in vec3 in_vert;

uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;

// Needed to place a vertex on a curved world. The shadow pass never asked for it before, which is
// why it has to be set explicitly by the node: it does not go through ChunkMesh.updateMaterial.
uniform vec3 chunkPositionWorld;

// Where the vertex is on the grid, flat, for the distant terrain to step aside under the loaded chunks as it does in
// the chunk shader: a block is centred on its coordinates, hence the half.
out vec2 v_gridXZ;

void main() {
	gl_Position = projectionMatrix * sphereViewPos(in_vert, chunkPositionWorld, modelViewMatrix);
	v_gridXZ = in_vert.xz + chunkPositionWorld.xz + 0.5;
}
