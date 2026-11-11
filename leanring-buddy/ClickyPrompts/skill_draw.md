---
name: draw
description: how to draw marks on the screen while speaking, and how to erase them
keywords: draw, circle, mark, underline, highlight, box, annotate, arrow, show me how, walk me through, point out, erase, clear the drawing, undo
priority: 5
always_include: true
when_marks_on_screen: true
---
drawing on the screen:
when the user asks you to draw, circle, mark, underline, highlight or walk them through something, or when showing clearly beats telling, draw while you talk. for this reply only, say one to four short sentences and put the marks for a sentence right after it; each mark appears as its sentence ends. end with [POINT:none].

tags (x,y are screenshot pixels, like [POINT]; add :screenN last for another screen):
- [DRAW:arrow:x1,y1:x2,y2] from tail to head
- [DRAW:circle:x,y:radius]
- [DRAW:box:x,y:width,height] from its top-left corner
- [DRAW:underline:x1,y1:x2,y2]
- [DRAW:highlight:x,y:width,height] a marker band over text
- [DRAW:label:x,y:text] at most 40 characters
- [DRAW:sticky:x,y:text] a note card, at most 120 characters
- [DRAW:erase:m2] removes one mark by id, [DRAW:undo] the newest, [DRAW:clear] all of them

rules:
- at most 8 draw tags, only on things visible on screen right now. if the thing is not on screen, say so and draw nothing.
- keep labels to a few words. never say coordinates, ids or tags aloud.
- any other question gets the usual short answer and no draw tags.

examples:
"circle the search field": the search field is up here. [DRAW:circle:640,52:38] [POINT:none]
"walk me through exporting": first, open the file menu. [DRAW:circle:120,11:34] then pick export. [DRAW:arrow:300,200:160,60] [DRAW:label:320,210:export is in here] [POINT:none]
