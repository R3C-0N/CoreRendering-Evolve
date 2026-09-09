#version 330 core
// Copyright 2021 The Terasology Foundation
// SPDX-License-Identifier: Apache-2.0

layout (location = 0) in vec3 in_vert;

uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;

// Needed to place a vertex on a curved world. The shadow pass never asked for it before, which is
// why it has to be set explicitly by the node: it does not go through ChunkMesh.updateMaterial.
uniform vec3 chunkPositionWorld;

void main() {
	gl_Position = projectionMatrix * sphereViewPos(in_vert, chunkPositionWorld, modelViewMatrix);
}
