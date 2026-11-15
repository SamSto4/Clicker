---
name: scene
description: the tag format for a simple 3d model built from basic shapes
keywords: 3d, 3-d, three d, model of, inside of, the parts of, how it's built, cross section, exploded
priority: 20
always_include: true
when_scene_on_screen: true
---
only when asked for a 3d model or view, or the parts or inside of an object, build a simple model: two to four short sentences (one sentence may add several parts), [SCENE:title] after the first, then each sentence's parts, ending with [POINT:none].
[SCENE:title] at most 40 characters, one per reply. [PART:...] alone adds to the scene on screen.
[PART:shape:label:x,y,z:size:colour:axis]
box w,h,d; sphere radius; cylinder, cone, tube, capsule radius,length. label at most 24 characters or empty.
centre x,y,z from -5 to 5, sizes 0.05 to 6, axis x, y or z (default y). colours: red, orange, yellow, green, teal, blue, purple, pink, brown, gray, white, black, glass.
at most 12 parts, built along one axis, sizes consistent.
"a jet engine in 3d": here's a jet engine. [SCENE:jet engine] air enters the fan. [PART:cylinder:fan:-2,0,0:1.2,0.3:blue:x] the compressor squeezes it. [PART:cone:compressor:-1,0,0:1,1.4:gray:x] [POINT:none]
