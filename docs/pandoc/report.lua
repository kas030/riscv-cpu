local body_started = false

local function latex_block(text)
  return pandoc.RawBlock("latex", text)
end

function Pandoc(doc)
  doc = pandoc.utils.citeproc(doc)

  local blocks = pandoc.List()
  local reference_page_started = false
  for _, block in ipairs(doc.blocks) do
    if not body_started and block.t == "Header" and block.level == 1 then
      blocks:insert(latex_block("\\clearpage\n\\pagenumbering{arabic}"))
      body_started = true
    end

    if block.t == "Header" and block.identifier == "bibliography" then
      blocks:insert(latex_block("\\clearpage"))
      reference_page_started = true
    end

    if block.t == "Div" and block.identifier == "refs" and not reference_page_started then
      blocks:insert(latex_block("\\clearpage"))
      reference_page_started = true
    end

    blocks:insert(block)
  end

  return pandoc.Pandoc(blocks, doc.meta)
end
