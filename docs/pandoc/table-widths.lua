local function block_text(block)
  if block.t ~= "Para" and block.t ~= "Plain" then
    return nil
  end
  return pandoc.utils.stringify(block)
end

local function parse_width_text(text)
  if not text or not text:match("^%s*{widths%s*=") then
    return nil, false
  end

  local specification = text:match("^%s*{widths%s*=%s*([^{}]+)%s*}%s*$")
  if not specification then
    error("invalid table width marker: " .. text)
  end

  local widths = {}
  for token in specification:gmatch("[^,]+") do
    local value = tonumber(token:match("^%s*(.-)%s*$"))
    if not value or value <= 0 or value == math.huge or value ~= value then
      error("table widths must be positive numbers: " .. text)
    end
    widths[#widths + 1] = value
  end

  if #widths == 0 then
    error("table width marker must contain at least one width: " .. text)
  end

  return widths, true
end

local function parse_width_marker(block)
  return parse_width_text(block_text(block))
end

local function table_caption(table_block)
  local caption = pandoc.utils.stringify(table_block.caption)
  if caption == "" then
    return "<untitled table>"
  end
  return caption
end

local function apply_widths(table_block, widths)
  if #widths ~= #table_block.colspecs then
    error(string.format(
      "table '%s' has %d columns, but its width marker contains %d values",
      table_caption(table_block),
      #table_block.colspecs,
      #widths
    ))
  end

  local total = 0
  for _, width in ipairs(widths) do
    total = total + width
  end

  for index, colspec in ipairs(table_block.colspecs) do
    table_block.colspecs[index] = { colspec[1], widths[index] / total }
  end
end

local function caption_widths(table_block)
  local caption_blocks = table_block.caption.long
  local last_block = caption_blocks[#caption_blocks]
  if not last_block or (last_block.t ~= "Plain" and last_block.t ~= "Para") then
    return nil
  end

  local inlines = last_block.content
  local separator_index = nil
  for index = #inlines, 1, -1 do
    if inlines[index].t == "SoftBreak" or inlines[index].t == "LineBreak" then
      separator_index = index
      break
    end
  end
  if not separator_index or separator_index == #inlines then
    return nil
  end

  local marker_inlines = pandoc.Inlines({})
  for index = separator_index + 1, #inlines do
    marker_inlines:insert(inlines[index])
  end
  local widths, is_marker = parse_width_text(pandoc.utils.stringify(marker_inlines))
  if not is_marker then
    return nil
  end

  while #inlines >= separator_index do
    inlines:remove(#inlines)
  end
  last_block.content = inlines
  caption_blocks[#caption_blocks] = last_block
  table_block.caption.long = caption_blocks
  return widths
end

function Table(table_block)
  local widths = caption_widths(table_block)
  if widths then
    apply_widths(table_block, widths)
  end
  return table_block
end

function Pandoc(document)
  local blocks = pandoc.List()
  local index = 1

  while index <= #document.blocks do
    local block = document.blocks[index]
    local next_block = document.blocks[index + 1]

    if block.t == "Table" and next_block then
      local widths, is_marker = parse_width_marker(next_block)
      if is_marker then
        apply_widths(block, widths)
        blocks:insert(block)
        index = index + 2
      else
        blocks:insert(block)
        index = index + 1
      end
    else
      local _, is_marker = parse_width_marker(block)
      if is_marker then
        error("table width marker must immediately follow a table")
      end
      blocks:insert(block)
      index = index + 1
    end
  end

  return pandoc.Pandoc(blocks, document.meta)
end
