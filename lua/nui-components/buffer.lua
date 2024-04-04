local Component = require("nui-components.component")

local Line = require("nui.line")

local fn = require("nui-components.utils.fn")

---@class NuiBuffer: NuiComponent
---@field super NuiComponent
local Buffer = Component:extend("Buffer")

function Buffer:init(props, popup_options)
  Buffer.super.init(
    self,
    fn.merge({
      buf = nil,
    }, props),
    fn.deep_merge({
      buf_options = {
        filetype = props.filetype or "",
      },
    }, popup_options)
  )
end

function Buffer:prop_types()
  return {
    buf = "number",
  }
end

function Buffer:_buf_create()
  self.bufnr = self:get_props().buf or vim.api.nvim_create_buf(false, true)
end

return Buffer
