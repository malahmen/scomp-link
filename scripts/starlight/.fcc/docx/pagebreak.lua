-- pagebreak.lua
-- Turns an explicit page-break marker into the correct construct per output
-- format, so the same marker works for both PDF (LaTeX) and DOCX.
--
-- Recognised markers (alone on a line):
--   \newpage     \pagebreak     \newpage{}     \pagebreak{}
--
-- Emits:
--   LaTeX / beamer → \newpage
--   DOCX (openxml) → a Word page break
--   any other      → the marker is left untouched
--
-- The marker is honoured whether it sits in its own paragraph (blank lines
-- around it) OR on its own line inside a paragraph (adjacent to text) — in the
-- latter case the paragraph is split around the break.

local function is_marker(s)
    s = (s or ""):gsub("%s+$", ""):gsub("^%s+", "")
    return s == "\\newpage" or s == "\\pagebreak"
        or s == "\\newpage{}" or s == "\\pagebreak{}"
end

local function supported_format()
    return FORMAT:match("latex") or FORMAT:match("beamer") or FORMAT:match("docx")
end

local function break_block()
    if FORMAT:match("latex") or FORMAT:match("beamer") then
        return pandoc.RawBlock("latex", "\\newpage")
    elseif FORMAT:match("docx") then
        -- Use pageBreakBefore rather than an inline <w:br w:type="page"/> run.
        -- An inline break lives in its own empty paragraph; when the preceding
        -- content ends near a page boundary that empty paragraph spills to the
        -- next page and its break then starts yet another → a blank page. Word
        -- suppresses pageBreakBefore when the paragraph is already at the top of
        -- a page, so it never produces that stray blank page.
        return pandoc.RawBlock(
            "openxml",
            '<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>'
        )
    end
    return nil
end

-- Is this inline a standalone page-break marker?
local function inline_is_marker(inl)
    return (inl.t == "RawInline" or inl.t == "Str") and is_marker(inl.text)
end

-- Drop leading/trailing whitespace inlines (Space / SoftBreak / LineBreak).
local function trim_inlines(inls)
    local function ws(i) return i.t == "Space" or i.t == "SoftBreak" or i.t == "LineBreak" end
    local a, b = 1, #inls
    while a <= b and ws(inls[a]) do a = a + 1 end
    while b >= a and ws(inls[b]) do b = b - 1 end
    local out = {}
    for i = a, b do out[#out + 1] = inls[i] end
    return out
end

function Para(el)
    if not supported_format() then return nil end

    -- Fast path: a paragraph that is exactly one marker.
    if #el.content == 1 and inline_is_marker(el.content[1]) then
        return break_block()
    end

    -- Does any inline look like a marker? If not, leave the paragraph alone.
    local has = false
    for _, inl in ipairs(el.content) do
        if inline_is_marker(inl) then has = true; break end
    end
    if not has then return nil end

    -- Split the paragraph at each marker, emitting a break between segments.
    local blocks = {}
    local segment = {}
    local function flush()
        local trimmed = trim_inlines(segment)
        if #trimmed > 0 then blocks[#blocks + 1] = pandoc.Para(trimmed) end
        segment = {}
    end
    for _, inl in ipairs(el.content) do
        if inline_is_marker(inl) then
            flush()
            blocks[#blocks + 1] = break_block()
        else
            segment[#segment + 1] = inl
        end
    end
    flush()
    return blocks
end

-- Marker pandoc already parsed as a raw LaTeX block (so DOCX gets a real
-- break instead of dropping the raw LaTeX).
function RawBlock(el)
    if (el.format == "tex" or el.format == "latex") and is_marker(el.text) then
        return break_block() or el
    end
    return nil
end

-- Is this block a page break — in any of the forms it can take: the raw marker
-- (\newpage as a RawBlock or a lone-marker paragraph) or the break this filter
-- emits (LaTeX \newpage, or the DOCX openxml page break)? Matching every form
-- keeps the adjacency cleanup below correct regardless of filter traversal order.
local function is_break_block(b)
    if not b then return false end
    if b.t == "RawBlock" then
        local f = (b.format or ""):lower()
        if f == "latex" or f == "tex" or f == "beamer" then return is_marker(b.text) end
        if f == "openxml" then
            return b.text:find('w:type="page"', 1, true) ~= nil
                or b.text:find("pageBreakBefore", 1, true) ~= nil
        end
        return false
    end
    if b.t == "Para" and #b.content == 1 then return inline_is_marker(b.content[1]) end
    return false
end

-- A paragraph with no visible content (only whitespace inlines) — the kind a
-- "quirky" Markdown formatter can leave behind next to a break.
local function is_empty_para(b)
    if not b or (b.t ~= "Para" and b.t ~= "Plain") then return false end
    for _, inl in ipairs(b.content) do
        local t = inl.t
        if t ~= "Space" and t ~= "SoftBreak" and t ~= "LineBreak" then return false end
    end
    return true
end

-- Drop a HorizontalRule (Markdown `---`) or empty paragraph sitting immediately
-- next to a page break. In DOCX both render as an extra empty paragraph, which
-- pushes a blank line onto the top of the new page — and occasionally spills to
-- a whole blank page. The break already provides the separation, so the rule /
-- blank is redundant. Leaves rules/blanks that are NOT next to a break alone.
function Blocks(blocks)
    if not supported_format() then return nil end
    local out = {}
    for i = 1, #blocks do
        local b = blocks[i]
        local drop = false
        if b.t == "HorizontalRule" or is_empty_para(b) then
            if is_break_block(out[#out]) or is_break_block(blocks[i + 1]) then
                drop = true
            end
        end
        if not drop then out[#out + 1] = b end
    end
    return out
end
