---
name: draw
description: the tag format for drawing on the screen: marks, labels, callouts, a spotlight, and walkthroughs one step at a time
keywords: draw, circle, mark, underline, highlight, box, annotate, label, point out, walk me through, walk through, walkthrough, talk me through, step by step, guide me through, show me how, spotlight, focus on, dim everything, erase, undo the mark, clear the marks, next step, go back a step
priority: 20
always_include: true
when_marks_on_screen: true
when_walkthrough_active: true
---
draw only when asked to draw, circle, mark, underline, highlight, box, annotate, label or walk through something. any other question gets the usual short answer and no draw tags. say one to four short sentences, each followed by its marks, and end with [POINT:none].
x,y are screenshot pixels as in [POINT]; add :screenN last for another screen.
[DRAW:arrow:x1,y1:x2,y2] tail to head
[DRAW:circle:x,y:radius]
[DRAW:box:x,y:width,height] from its top-left
[DRAW:underline:x1,y1:x2,y2]
[DRAW:highlight:x,y:width,height] over text
[DRAW:label:x,y:text] at most 40 characters
[DRAW:sticky:x,y:text] note card, at most 120 characters
[DRAW:callout:x,y:text] a numbered tag, at most 28 characters
[DRAW:erase:m2] removes that mark, [DRAW:undo] the newest, [DRAW:clear] all
at most 8 draw tags, only on things visible on screen right now. if the thing is not on screen, say so and draw nothing.
to label or name several parts, use callouts: at most three short sentences, several callouts after each.
keep labels to a few words.
"where is export?": open the file menu first. [DRAW:circle:120,11:34] export is in there. [DRAW:arrow:300,200:160,60] [DRAW:label:320,210:export is in here] [POINT:none]
[DRAW:spotlight:x,y:radius] darkens everything but a circle; one per reply, for "spotlight" or "focus on"
walking through several steps: when asked to walk through or guide step by step, give one step per reply. start the reply with [STEP:k of n], then one or two short sentences for this step and its marks, and end with [POINT:none]. in step one also write the plan after the words, one [PLAN:k:text] per step, at most 12 steps, each text at most 60 characters. the user then says next, back, repeat or stop. when the prompt says a walkthrough is in progress, give exactly the step it asks for, for the screen now; if the screen shows the user already did it, say so in one sentence and give the step anyway. never give two steps in one reply.
"walk me through committing": [STEP:1 of 3] first, stage the file. [DRAW:circle:120,400:30] [PLAN:1:stage the file] [PLAN:2:write the message] [PLAN:3:press commit] [POINT:none]
