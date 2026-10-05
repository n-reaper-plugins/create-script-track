package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local C = require("CSTCore")

-- ids ---------------------------------------------------------------------------------------------------------------
local function id(text, prefix) local i, t = C.match_cue_text(text, prefix); return i, t end
local a, b = id("1 Intro")           T.eq(a, "1", "bare id");              T.eq(b, "Intro", "title after bare id")
a, b = id("1.2 Door slam")           T.eq(a, "1.2", "two segments");       T.eq(b, "Door slam", "title")
a, b = id("1.2.3: Door slam")        T.eq(a, "1.2.3", "three segments");   T.eq(b, "Door slam", "colon separator stripped")
a, b = id("4.1 - Reprise")           T.eq(a, "4.1", "dash form");          T.eq(b, "Reprise", "dash stripped")
a, b = id("4.1 \xE2\x80\x93 Reprise") T.eq(a, "4.1", "en dash form");      T.eq(b, "Reprise", "en dash stripped")
a, b = id("7")                       T.eq(a, "7", "id only");              T.eq(b, "", "empty title")
a, b = id("2. Second")               T.eq(a, "2", "trailing dot is a separator"); T.eq(b, "Second", "title after dot")
T.eq(id("1abc"), nil, "digits glued to a word are not an id")
T.eq(id("Intro"), nil, "no number, no cue")
T.eq(id("1.2.x"), "1.2", "dotted non-number: id stops at 1.2 (dot separator)")
T.eq(id("Q 1.2 Door", "Q"), "1.2", "prefix with space")
T.eq(id("Q1.2 Door", "Q"), "1.2", "prefix without space")
T.eq(id("q 1.2 Door", "Q"), "1.2", "prefix is case-insensitive")
T.eq(id("Cue 3 Fade", "Cue "), "3", "prefix with trailing space")
T.eq(id("1.2 Door", "Q"), nil, "prefix required when set")
T.eq(id("Quiet 1 x", "Q"), nil, "prefix must be followed by the number")
T.eq(id("1.2.3.4.5.6.7.8 x"), "1.2.3.4.5.6.7.8", "8 segments are fine"); T.eq(id("1.2.3.4.5.6.7.8.9 x"), nil, "9 segments is not an id")
T.eq(C.id_cmp("1.2", "1.10"), -1, "numeric order 1.2 < 1.10")
T.eq(C.id_cmp("2", "1.9"), 1, "2 > 1.9")
T.eq(C.id_cmp("1", "1.0"), -1, "1 sorts before 1.0")
T.eq(C.id_cmp("3.1", "3.1"), 0, "equal ids")
T.eq(C.marker_name("Q", { id = "1.2", title = "Door" }), "Q 1.2 Door", "marker name with prefix")
T.eq(C.marker_name("", { id = "1.2", title = "Door" }), "1.2 Door", "marker name without prefix")
T.eq(C.marker_name("Cue ", { id = "5", title = "" }), "Cue 5", "marker name without title")
-- a marker name we write must be recognised again
for _, p in ipairs({ "", "Q", "Cue ", "SC" }) do
  local n = C.marker_name(p, { id = "2.3.1", title = "Chase – start" })
  local i, t = id(n, p)
  T.eq(i, "2.3.1", "round trip id, prefix '" .. p .. "'"); T.eq(t, "Chase \xE2\x80\x93 start", "round trip title, prefix '" .. p .. "'")
end

-- parser ------------------------------------------------------------------------------------------------------------
local md = [[
# Show notes
Some intro text.

## 1 Opening
Lights fade up.
- house to half
- preset 4

### 1.1 Walk-on
Actor enters left.

```
## 9 Not a cue (inside a code fence)
```

## Not a cue
Plain header.

## 1.2 Door slam
SFX: door

## 1 Opening again
dup text
]]
local doc = C.parse(md, {})
T.eq(#doc.cues, 4, "four cues found (code fence and plain headers ignored)")
T.eq(doc.cues[1].id, "1", "cue 1 id"); T.eq(doc.cues[1].title, "Opening", "cue 1 title")
T.eq(doc.cues[2].id, "1.1", "cue 1.1"); T.eq(doc.cues[3].id, "1.2", "cue 1.2")
T.eq(doc.dups, 1, "one duplicate id counted"); T.ok(doc.cues[4].dup and not doc.cues[1].dup, "second occurrence flagged")
T.eq(doc.cues[1].line, 4, "header line number")
T.eq(#doc.cues[1].body, 3, "body stops at the next cue header, trailing blanks trimmed")
T.eq(doc.cues[1].body[1], "Lights fade up.", "body first line")
T.ok(table.concat(doc.cues[2].body, "\n"):find("## 9 Not a cue", 1, true), "fenced fake header stays in the body")
T.ok(table.concat(doc.cues[3].body, "\n"):find("SFX: door", 1, true), "last real cue body")
T.eq(doc.cue_at_line[4], 1, "cue_at_line")

local doc2 = C.parse(md, { prefix = "Q" })
T.eq(#doc2.cues, 0, "prefix Q: nothing matches")
local doc3 = C.parse("# Q1 A\n## Q2 B\n### Q3 C\n#### 4 D\n", { prefix = "Q", min_level = 2, max_level = 3 })
T.eq(#doc3.cues, 2, "level range 2..3 with prefix"); T.eq(doc3.cues[1].id, "2", "first in range")
T.eq(#C.parse("", {}).cues, 0, "empty text"); T.eq(#C.parse("no headers\nat all", {}).cues, 0, "no headers")
local crlf = C.parse("## 1 A\r\nbody\r\n## 2 B\r\n", {})
T.eq(#crlf.cues, 2, "CRLF line endings"); T.eq(crlf.cues[1].body[1], "body", "CR stripped from body")
T.eq(#C.parse("\xEF\xBB\xBF## 1 A\n", {}).cues, 1, "UTF-8 BOM is ignored")
T.eq(#C.parse("## 1 A ##\n", {}).cues, 1, "closing hashes tolerated"); T.eq(C.parse("## 1 A ##\n", {}).cues[1].title, "A", "closing hashes stripped")
T.eq(#C.parse("##1 A\n", {}).cues, 0, "no space after # is not a header")
T.eq(#C.parse("~~~\n## 1 A\n~~~\n## 2 B\n", {}).cues, 1, "tilde fences too")

-- storage encoding ---------------------------------------------------------------------------------------------------
local nasty = "line1\nline2\r\nback\\slash \\n literal\n\n"
T.eq(C.unescape(C.escape(nasty)), nasty, "escape round trip")
T.ok(not C.escape(nasty):find("[\r\n]"), "escaped text is a single line")
local big = string.rep("abcdefghij\n", 1000)
local ch = C.chunks(C.escape(big), 4000)
T.ok(#ch > 1, "big text is chunked"); for _, c in ipairs(ch) do T.ok(#c <= 4000, "chunk size") end
T.eq(C.unescape(table.concat(ch)), big, "chunks join back")
T.eq(#C.chunks(""), 1, "empty text is one empty chunk")
T.eq(C.hash("abc"), C.hash("abc"), "hash stable"); T.ok(C.hash("abc") ~= C.hash("abd"), "hash differs")
T.eq(C.hash(""), "811c9dc5", "FNV-1a of the empty string")

-- blocks ------------------------------------------------------------------------------------------------------------
local bl = C.blocks(doc)
local kinds = {}
for _, x in ipairs(bl) do kinds[#kinds + 1] = x.kind end
local function count(k) local n = 0 for _, x in ipairs(bl) do if x.kind == k then n = n + 1 end end return n end
T.eq(count("li"), 2, "two bullets"); T.ok(count("code") == 1, "one code line (fence markers dropped)")
T.eq(bl[1].kind, "h", "first block is the title header"); T.eq(bl[1].cue, nil, "non-cue header has no cue"); T.eq(bl[1].owner, nil, "before any cue: no owner")
local first_cue_block
for _, x in ipairs(bl) do if x.cue == 1 then first_cue_block = x end end
T.ok(first_cue_block ~= nil and first_cue_block.owner == 1, "cue header block carries the cue index")
local para
for _, x in ipairs(bl) do if x.kind == "p" and x.text == "Lights fade up." then para = x end end
T.eq(para.owner, 1, "paragraph belongs to its cue")
local plain
for _, x in ipairs(bl) do if x.kind == "h" and x.text == "Not a cue" then plain = x end end
T.eq(plain.owner, 2, "plain header stays in the previous cue (1.1)")
local tb = C.blocks(C.parse("## 1 A\n- [ ] todo\n- [x] done\n1. first\n> quoted\n---\nline one\nline two\n", {}))
T.eq(tb[2].kind, "task", "task block"); T.eq(tb[2].checked, false, "unchecked"); T.eq(tb[3].checked, true, "checked")
T.eq(tb[4].kind, "li", "ordered item"); T.eq(tb[4].marker, "1.", "ordered marker kept")
T.eq(tb[5].kind, "quote", "quote"); T.eq(tb[5].text, "quoted", "quote text")
T.eq(tb[6].kind, "hr", "rule"); T.eq(tb[7].text, "line one line two", "paragraph lines merge")
T.eq(C.inline("a **b** `c` *d* [e](http://x)"), "a b c d e", "inline markers stripped"); T.eq(C.inline("*start* and (*paren*)"), "start and (paren)", "italics at start / after paren")
T.eq(C.inline("snake_case and 2*3*4"), "snake_case and 2*3*4", "no false italics inside 2*3*4")

-- current cue ---------------------------------------------------------------------------------------------------------
local timed = { { t = 5 }, { t = 10 }, { t = 20 } }
T.eq(C.current(timed, 0), nil, "before the first cue"); T.eq(C.current(timed, 5), 1, "exactly on a cue")
T.eq(C.current(timed, 9.99), 1, "just before the next"); T.eq(C.current(timed, 10), 2, "second")
T.eq(C.current(timed, 999), 3, "after the last"); T.eq(C.current({}, 3), nil, "no cues")
T.eq(C.current(timed, 4.9999999), 1, "tolerance for float noise")

-- comment text ---------------------------------------------------------------------------------------------------------
local cue = { id = "1", title = "Opening", body = { "", "Lights fade up.", "", "- house to half", "- preset 4", "### sub" } }
T.eq(C.comment_text(cue, 2, true, "Q"), "Q 1 Opening\nLights fade up.\n- house to half", "title + first 2 lines, blanks skipped")
T.eq(C.comment_text(cue, 1, false, "Q"), "Lights fade up.", "no title, 1 line")
T.eq(C.comment_text(cue, 0, true, ""), "1 Opening", "n = 0: title only")
T.eq(C.comment_text(cue, 9, false, ""), "Lights fade up.\n- house to half\n- preset 4\nsub", "fewer lines than n; sub-header marks stripped")
T.eq(C.fmt_clock(75.5), "1:15.500", "clock format")

T.done("test_core")
