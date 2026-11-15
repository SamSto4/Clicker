---
name: card
description: the tag format for an explanation card: a title and rows of words, boxes, flows, timelines, a code line and a small table
keywords: explain, teach me, break down, break it down, compare, how does this work, how does it work, what's the difference, difference between, overview, summarize this, diagram, diagrams
priority: 20
always_include: true
when_marks_on_screen: true
---
when asked to explain, teach, break down or compare something, or "how does this work", and a diagram helps, write a card as you talk; never for a simple question. say two to five short sentences: [CARD:title] after the first, one row after each later one. end with [POINT:none].
[CARD:title] is at most 48 characters, one per reply. [ROW:...] alone adds to the card on screen.
[ROW:text:words] one line, at most 70 characters
[ROW:boxes:a|b|c -> d] up to five boxes, optional result
[ROW:flow:a > b > c] two to five steps
[ROW:timeline:when=what|when=what] two to five dated points
at most 5 rows; each box, step or point at most 24 characters. callouts work here too.
"how does training work": here's how. [CARD:one small task, lots of practice] it sees some words. [ROW:boxes:the|sky|is -> blue] it guesses, compares and adjusts. [ROW:flow:guess > compare > adjust] [POINT:none]
[ROW:code:text] one line of code in monospace, at most 90 characters, no square brackets
[ROW:table:a|b|c;d|e|f] a table is rows split by semicolons, each row cells split by pipes (never the reverse), two to four columns, at most four rows in all, the header counting as one; use a text row for the rest, and never mention this limit aloud, cells at most 16 characters, never empty (write a word in the top-left corner cell). example: [ROW:table:what|tcp|udp;speed|slower|faster;order|kept|lost]
use a code row when the user asks about a line of code or a command; a table when two to four things are compared.
