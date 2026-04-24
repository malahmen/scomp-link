-- widen-tables.lua
-- Redistributes longtable column widths so the first column is wider
-- when it contains only Code/Str spans (i.e. inline code identifiers).
-- Pandoc calculates widths from markdown source character counts which
-- underestimates monospace content width.

function Table(tbl)
  local cols = tbl.colspecs
  if #cols < 2 then return nil end

  -- Check if column 1 body cells are predominantly inline code
  local code_rows = 0
  local total_rows = 0

  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      total_rows = total_rows + 1
      local cell = row.cells[1]
      if cell then
        for _, block in ipairs(cell.contents) do
          if block.t == "Para" then
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
end