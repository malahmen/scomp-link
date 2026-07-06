-- widen-tables.lua
-- Two fixes for how pandoc lays out tables in LaTeX/PDF:
--
--  1. Simple pipe tables (no explicit width markers) arrive with all column
--     widths at 0. LaTeX then renders them at natural width, so a wide table
--     overflows the right margin. We distribute equal widths that sum to 1.0,
--     forcing the table to \linewidth and wrapping long cells instead.
--
--  2. When column 1 is predominantly inline code (identifiers), pandoc's
--     source-character-count heuristic underestimates its monospace width, so
--     we widen it to 0.50 and redistribute the remainder proportionally.

function Table(tbl)
  local cols = tbl.colspecs
  local ncols = #cols
  if ncols < 1 then return nil end

  -- Fix 1: no width info at all → force an even fit-to-width layout.
  local width_sum = 0
  for _, spec in ipairs(cols) do
    width_sum = width_sum + (spec[2] or 0)
  end
  if width_sum == 0 then
    local even = 1.0 / ncols
    for i = 1, ncols do cols[i][2] = even end
    tbl.colspecs = cols
    -- fall through: a code-heavy col1 can still be widened below
  end

  if ncols < 2 then tbl.colspecs = cols; return tbl end

  -- Fix 2: check if column 1 body cells are predominantly inline code
  local code_rows = 0
  local total_rows = 0

  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      total_rows = total_rows + 1
      local cell = row.cells[1]
      if cell then
        for _, block in ipairs(cell.contents) do
          -- Table cells wrap their content in Plain (tight) blocks, not Para.
          -- Accept both so single-line code cells are detected.
          if block.t == "Para" or block.t == "Plain" then
            for _, inline in ipairs(block.content) do
              if inline.t == "Code" then
                code_rows = code_rows + 1
                break
              end
            end
          end
        end
      end
    end
  end

  -- If majority of col1 cells are code, widen col1 to 0.50
  if total_rows > 0 and code_rows / total_rows >= 0.5 then
    local total = 0
    for _, spec in ipairs(cols) do
      total = total + (spec[2] or 0)
    end
    -- Set col1 to 0.50, redistribute remainder proportionally to other cols
    local old_col1 = cols[1][2] or 0
    local new_col1 = 0.50
    local remainder = total - new_col1
    local old_remainder = total - old_col1

    cols[1][2] = new_col1
    for i = 2, #cols do
      local share = (cols[i][2] or 0) / old_remainder
      cols[i][2] = remainder * share
    end
    tbl.colspecs = cols
    return tbl
  end

  -- Not code-heavy: return tbl so any Fix 1 even-width layout is kept.
  return tbl
end