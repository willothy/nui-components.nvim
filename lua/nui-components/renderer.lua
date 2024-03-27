local Layout = require("nui.layout")
local Subject = require("nui-components.rx.subject")

local fn = require("nui-components.utils.fn")

local Renderer = {}

Renderer.__index = Renderer
Renderer.__tostring = fn.always("Renderer")

function Renderer.create(options)
  options = options or {}

  local self = {
    _private = {
      lifecycle = {
        on_mount = fn.default_to(options.on_mount, fn.ignore),
        on_unmount = fn.default_to(options.on_unmount, fn.ignore),
      },
      layout_options = {
        position = fn.default_to(options.position, "50%"),
        relative = fn.default_to(options.relative, "editor"),
        size = {
          width = fn.default_to(options.width, 80),
          height = fn.default_to(options.height, 40),
        },
      },
      keymap = fn.merge({
        close = "<Esc>",
        focus_next = "<Tab>",
        focus_prev = "<S-Tab>",
      }, options.keymap),
      focusable_components = {},
      mappings = {},
      events = {},
      origin_winid = vim.api.nvim_get_current_win(),
      trigger_redraw_subject = Subject.create(),
      queue = {},
    },
  }

  return setmetatable(self, Renderer)
end

function Renderer:render(content)
  if type(content) == "function" then
    content = content()
  end

  self:_set_components_tree({ content })
  self:_flatten_components_tree()
  self:_determine_focusable_components()
  self:_set_layout()

  self._private.redraw_subscription = self._private.trigger_redraw_subject:debounce(60):subscribe(function()
    self:_determine_focusable_components()
    self.layout:update(self:get_layout_options(), self:_get_layout_box())

    while #self._private.queue > 0 do
      local func = table.remove(self._private.queue, 1)
      func()
    end
  end)

  vim.schedule(function()
    self.layout:mount()
    self._private.lifecycle.on_mount()
  end)
end

function Renderer:redraw()
  self._private.trigger_redraw_subject(1)
end

function Renderer:schedule(schedule_fn)
  table.insert(self._private.queue, schedule_fn)
end

function Renderer:focus()
  if self.layout then
    local last_focused_component = self:get_last_focused_component()

    if last_focused_component then
      last_focused_component:focus()
    else
      local first_focusable_component = fn.ifind(self._private.flatten_tree, function(component)
        return component:get_props().focus
      end)

      if first_focusable_component then
        first_focusable_component:focus()
      end
    end
  end
end

function Renderer:close()
  if self.layout then
    self._private.redraw_subscription:unsubscribe()
    self._private.lifecycle.on_unmount()
    self.layout:unmount()
  end
end

function Renderer:add_mappings(mappings)
  self._private.mappings = fn.concat(self._private.mappings, mappings)
end

function Renderer:set_size(size)
  self._private.layout_options.size = fn.merge(self._private.layout_options.size, size)
  self:redraw()
end

function Renderer:_flatten_components_tree()
  local function rec(components, initial_value)
    return fn.ireduce(components, function(acc, component)
      local children = component:get_children()

      if children then
        rec(children, acc)
      end

      table.insert(acc, component)

      return acc
    end, initial_value)
  end

  self._private.flatten_tree = rec(self._private.tree, {})
end

function Renderer:get_layout_options()
  return self._private.layout_options
end

function Renderer:_get_layout_box()
  local components = fn.ireduce(self._private.tree, function(acc, component)
    if not component:is_hidden() then
      table.insert(acc, component:render())
    end

    return acc
  end, {})

  return Layout.Box(components, { dir = "col" })
end

function Renderer:_set_layout()
  self.layout = Layout(self:get_layout_options(), self:_get_layout_box())
end

function Renderer:_determine_focusable_components()
  self._private.focusable_components = fn.ifilter(self._private.flatten_tree, function(component)
    return component:is_focusable() and not component:is_hidden()
  end)

  fn.ieach(self._private.focusable_components, function(component, index)
    component:set_focus_index(index)
  end)
end

function Renderer:_set_components_tree(root)
  local function rec(content, parent)
    return fn.ireduce(content, function(acc, component)
      local props = component:get_props()
      local children = props.children and rec(props.children, component) or nil

      component:on_renderer_initialization(self, parent, children)

      table.insert(acc, component)

      return acc
    end, {})
  end

  self._private.tree = rec(root)
end

function Renderer:set_last_focused_component(component)
  self._private.last_focused_component = component
end

function Renderer:get_last_focused_component()
  return self._private.last_focused_component
end

function Renderer:get_focusable_components()
  return self._private.focusable_components
end

local direction_matchers = {
  left = function(other, focused)
    return other.x + other.width < focused.x
  end,
  right = function(other, focused)
    return other.x > focused.x + focused.width
  end,
  up = function(other, focused)
    return other.y + other.height < focused.y
  end,
  down = function(other, focused)
    return other.y > focused.y + focused.height
  end,
}

---Get the component in the specified direction from the given component or the currently
---focused one.
---@param dir "left" | "right" | "up" | "down" Direction to query
---@param from table | nil Component to query from, or nil for the focused component
function Renderer:get_component_by_direction(dir, from)
  local focused
  if from then
    focused = from
  else
    focused = self:get_last_focused_component()
  end
  local focused_pos = vim.api.nvim_win_get_position(focused.winid)
  local focused_dims = {
    width = vim.api.nvim_win_get_width(focused.winid),
    height = vim.api.nvim_win_get_height(focused.winid),
    x = focused_pos[2],
    y = focused_pos[1],
  }

  local focusable = vim
    .iter(self:get_focusable_components())
    :filter(function(component)
      return component ~= focused
    end)
    :map(function(component)
      local winid = component.winid
      local pos = vim.api.nvim_win_get_position(winid)
      return {
        component = component,
        width = vim.api.nvim_win_get_width(winid),
        height = vim.api.nvim_win_get_height(winid),
        x = pos[2],
        y = pos[1],
      }
    end)
    :filter(function(component)
      return direction_matchers[dir](component, focused_dims)
    end)
    :totable()

  if #focusable > 1 then
    table.sort(focusable, function(a, b)
      if dir == "left" or dir == "right" then
        return math.abs(a.x - focused_dims.x) < math.abs(b.x - focused_dims.x)
      else
        return math.abs(a.y - focused_dims.y) < math.abs(b.y - focused_dims.y)
      end
    end)
  end

  if focusable[1] then
    return focusable[1].component
  end
end

function Renderer:get_mappings(component)
  local default_mappings = {
    {
      mode = { "n" },
      key = self._private.keymap.close,
      handler = function()
        self:close()
      end,
    },
  }

  local focus_mappings = {
    focus_next = {
      mode = { "i", "n" },
      handler = function()
        local focusable_components = self:get_focusable_components()
        local index = component:get_focus_index()
        local next = focusable_components[index + 1] or focusable_components[1]

        vim.api.nvim_set_current_win(next.winid)
      end,
    },
    focus_prev = {
      mode = { "i", "n" },
      handler = function()
        local focusable_components = self:get_focusable_components()
        local index = component:get_focus_index()
        local prev = focusable_components[index - 1] or focusable_components[#focusable_components]

        vim.api.nvim_set_current_win(prev.winid)
      end,
    },
    focus_right = {
      mode = { "i", "n" },
      handler = function()
        local c = self:get_component_by_direction("right")
        if c then
          c:focus()
        end
      end,
    },
    focus_left = {
      mode = { "i", "n" },
      handler = function()
        local c = self:get_component_by_direction("left")
        if c then
          c:focus()
        end
      end,
    },
    focus_down = {
      mode = { "i", "n" },
      handler = function()
        local c = self:get_component_by_direction("down")
        if c then
          c:focus()
        end
      end,
    },
    focus_up = {
      mode = { "i", "n" },
      handler = function()
        local c = self:get_component_by_direction("up")
        if c then
          c:focus()
        end
      end,
    },
  }

  for key, mapping in pairs(focus_mappings) do
    if self._private.keymap[key] then
      mapping.key = self._private.keymap[key]
      table.insert(default_mappings, mapping)
    end
  end

  return fn.concat(default_mappings, self._private.mappings)
end

function Renderer:get_component_by_id(id)
  return fn.ifind(self._private.flatten_tree, function(component)
    return component:get_id() == id
  end)
end

function Renderer:get_component_tree()
  return self._private.tree
end

function Renderer:get_origin_winid()
  return self._private.origin_winid
end

function Renderer:get_size()
  return self:get_layout_options().size
end

function Renderer:on_mount(mount_fn)
  self._private.lifecycle.on_mount = mount_fn
end

function Renderer:on_unmount(unmount_fn)
  self._private.lifecycle.on_unmount = unmount_fn
end

return Renderer
