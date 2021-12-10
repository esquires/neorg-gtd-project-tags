require("neorg.modules.base")
require('neorg.events')

local module = neorg.modules.create("utilities.gtd_project_tags")
local log = require('neorg.external.log')

module.setup = function()
  return {
    success = true,
    requires = {
      "core.autocommands",
      "core.gtd.ui",
      "core.gtd.queries",
      "core.integrations.treesitter",
      "core.keybinds",
      "core.neorgcmd",
      "core.mode",
      "core.queries.native",
      "core.ui",
    }
  }
end

module.load = function()
  module.required["core.neorgcmd"].add_commands_from_table({
    definitions = { gtd_project_tags = {} },
    data = { gtd_project_tags = { args = 0, name = "utilities.gtd_project_tags.views" } }
  })
  module.required["core.keybinds"].register_keybind(module.name, "views")
  module.required["core.autocommands"].enable_autocommand("WinClosed")
  module.required["core.autocommands"].enable_autocommand("CursorMoved")
end

module.public = {
  version = '0.1',

  get_tag = function(tag_name, node, type, opts)
    -- This function is largely copied from
    -- core/gtd/queries/retrievers.lua
    -- but adds "project" to the validation call
    --
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy

    vim.validate({
      tag_name = {
        tag_name,
        function(t)
          return vim.tbl_contains({ "time.due", "time.start", "contexts", "waiting.for", "project" }, t)
        end,
        "time.due|time.start|contexts|waiting.for|project",
      },
      node = { node, "table" },
      type = {
        type,
        function(t)
          return vim.tbl_contains({ "project", "task" }, t)
        end,
        "task|project",
      },
      opts = { opts, "table", true },
    })

    opts = opts or {}

    -- Will fetch multiple parent tag sets if we did not explicitly add same_node.
    -- Else, it'll only get the first upper tag_set from the current node
    local fetch_multiple_sets = not opts.same_node

    local tags_node = module.required["core.queries.native"].find_parent_node(
      { node.node, node.bufnr },
      "carryover_tag_set",
      { multiple = fetch_multiple_sets }
    )

    if #tags_node == 0 then
      return nil
    end

    local tree = {
      {
        query = { "all", "carryover_tag" },
        where = { "child_content", "tag_name", tag_name },
        subtree = {
          {
            query = { "all", "tag_parameters" },
            subtree = {
              { query = { "all", "word" } },
            },
          },
        },
      },
    }

    local extract = function(_node, extracted)
      local tag_content_nodes = module.required["core.queries.native"].query_from_tree(_node[1], tree, _node[2])

      if #tag_content_nodes == 0 then
        return nil
      end

      if not opts.extract then
        -- Only keep the nodes and add them to the results
        tag_content_nodes = vim.tbl_map(function(node)
            return node[1]
        end, tag_content_nodes)
        vim.list_extend(extracted, tag_content_nodes)
      else
        local res = module.required["core.queries.native"].extract_nodes(tag_content_nodes)

        for _, res_tag in pairs(res) do
          if not vim.tbl_contains(extracted, res_tag) then
            table.insert(extracted, res_tag)
          end
        end
      end
    end

    local extracted = {}

    if not fetch_multiple_sets then
      -- If i don't fetch multiple sets, i only have one, so i cannot iterate
      extract(tags_node, extracted)
    else
      for _, _node in pairs(tags_node) do
        extract(_node, extracted)
      end
    end

    if #extracted == 0 then
      return nil
    end

    return extracted
  end,

  get_tasks = function()
    -- This function is taken from
    -- core/gtd/ui/selection_popups.lua:show_views_popup
    -- with the following changes
    -- 1. removes the get("projects") and display of projects.
    -- 2. adds a call to get_tag to add the project to the metadata
    -- 3. does not call displays
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy

    local configs = neorg.modules.get_module_config("core.gtd.base")
    local exclude_files = configs.exclude
    table.insert(exclude_files, configs.default_lists.inbox)

    -- Get tasks and projects
    local tasks = module.required["core.gtd.queries"].get("tasks", { exclude_files = exclude_files })

    local tasks = module.required["core.gtd.queries"].add_metadata(tasks, "task")
    for _, task in pairs(tasks) do
      task["project_node"] = module.public.get_tag("project", task, "task", {extract = true})
    end

    return tasks
  end,

  group_tasks_by_project = function(tasks)
    projects = {}
    for _, task in pairs(tasks) do
      task.project_node =
      module.public.insert(projects, (task.project_node or {'_'})[1], task)
    end
    return projects
  end,

  get_parent_projects = function(projects, project_name)
    local split_names = vim.split(project_name, '/')
    table.remove(split_names)

    if #split_names == 0 then
      return {}
    end

    local name = split_names[1]
    local parent_projects = {}
    parent_projects[name] = projects[name]

    for i = 2, #split_names, 1 do
      name = name .. '/' .. split_names[i]
      parent_projects[name] = projects[name]
    end

    return parent_projects
  end,

  get_subprojects = function(projects, project_name)
    local subprojects = {}
    for temp_project_name, project in pairs(projects) do
      if vim.startswith(temp_project_name, project_name) then
        subprojects[temp_project_name] = project
      end
    end
    return subprojects
  end,

  insert = function(tbl, key, value)
    -- copied from
    -- gtd/queries/retrievers.lua
    --
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy
    if not tbl[key] then
      tbl[key] = {}
    end
    table.insert(tbl[key], value)
  end,

  display_projects = function(projects)
    -- this function does a similar action to
    -- core/gtd/ui/displayers.lua:display_projects
    -- but uses the #project to generate project organization
    vim.validate({
      projects = { projects, "table" },
    })

    local name = "Projects"
    local buf_lines = {"*" .. name .. "*", ""}
    local line_to_task_data = {}
    local project_lines = {}

    module.private.add_unknown_projects(projects, buf_lines, line_to_task_data, project_lines)
    local completed_counts = module.private.get_completed_counts(projects)
    module.private.add_known_projects(projects, completed_counts, buf_lines, line_to_task_data, project_lines)

    module.public.generate_display(name, buf_lines, project_lines)
    module.public.add_folds(project_lines)
    module.private.line_to_task_data = line_to_task_data
  end,

  create_norg_buffer = function(name)
    -- in core/ui/module.lua
    -- there is a autocommand that closes the window whenever it has been left
    -- so this just pulls out the necessaries

    local buf = (function()
        name = "buffer/" .. name .. ".norg"
        return module.required["core.ui"].create_vsplit(name, {}, true)
    end)()

    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd(([[
        edit
        autocmd BufDelete <buffer=%s> silent! bd! %s
    ]]):format(buf, buf))

    return buf
  end,

  generate_display = function(name, buf_lines, project_lines)
    local bufnr = module.public.create_norg_buffer(name)
    module.private.bufnr = bufnr
    module.required["core.mode"].set_mode("gtd-displays")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)

    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    return buf
  end,

  add_folds = function(project_lines)
    vim.wo.foldmethod= 'manual'
    vim.wo.foldminlines= 0

    local max_level = 0
    for project_name, _ in pairs(project_lines) do
      max_level = math.max(max_level, module.public.get_project_level(project_name))
    end

    for level = max_level, 1, -1 do
      for project_name, lines in pairs(project_lines) do
        if module.public.get_project_level(project_name) == level then
          vim.api.nvim_exec("normal! " .. lines.beg_line .. "GV" .. lines.end_line .. "GzfzR", false)
        end
      end
    end
  end,

  get_project_level = function(project_name)
    return #vim.split(project_name, '/')
  end,

  percent_completed = function(num_completed, num_tasks)
    -- copied from 
    -- core/gtd/ui/displayers.lua:display_projects
    --
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy
    if num_tasks == 0 then
      return 0
    end
    return math.floor(num_completed * 100 / num_tasks)
  end,
}

module.config.public = {
}

module.private = {
  line_to_task_data = {},
  bufnr = nil,

  add_unknown_projects = function(projects, buf_lines, line_to_task_data, project_lines)
    -- adapted from 
    -- core/gtd/ui/displayers.lua:display_projects
    --
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy
    local unknown_project = projects["_"]
    if unknown_project and #unknown_project > 0 then
      local undone = vim.tbl_filter(function(a, _)
        return a.state ~= "done"
      end, unknown_project)
      table.insert(buf_lines, "- /" .. #undone .. " tasks don't have a project assigned/")


      if #undone > 0 then
        table.insert(buf_lines, "")
        project_lines['_'] = {beg_line = #buf_lines}
        for _, task in pairs(undone) do
          table.insert(buf_lines, "-- " .. task.content)
          line_to_task_data[#buf_lines] = task
        end
        project_lines['_'].end_line = #buf_lines
      end
      table.insert(buf_lines, "")
    end
  end,

  add_known_projects = function(projects, completed_counts, buf_lines, line_to_task_data, project_lines)
    -- adapted from 
    -- core/gtd/ui/displayers.lua:display_projects
    local added_projects = {}

    local project_names = vim.tbl_keys(projects)
    table.sort(project_names)

    for _, project_name in pairs(project_names) do
      local tasks = projects[project_name]
      if project_name ~= '_' and not vim.tbl_contains(added_projects, project_name) then

        -- get how many are completed/total for all subprojects (including this project)
        local subprojects = module.public.get_subprojects(projects, project_name)
        local summary = module.private.get_subproject_summary(subprojects, completed_counts)

        if summary.num_tasks - summary.num_completed > 0 then
          project_lines[project_name] = {beg_line = #buf_lines + 3}
          module.private.write_project(project_name, tasks, summary, buf_lines, line_to_task_data)

          project_lines[project_name].end_line = #buf_lines - 1
          for name, _ in pairs(module.public.get_parent_projects(projects, project_name)) do
            project_lines[name].end_line = #buf_lines - 1
          end
        end
      end
    end
    put(project_lines)
  end,

  get_completed_counts = function(projects)
    local completed_counts = {}
    for project_name, project in pairs(projects) do
      local completed = vim.tbl_filter(function(t)
        return t.state == "done"
      end, project)

      completed_counts[project_name] = #completed
    end

    return completed_counts
  end,

  get_subproject_summary = function(subprojects, completed_counts)
    local num_completed = 0
    local num_tasks = 0
    for subproject_name, subproject in pairs(subprojects) do
      num_completed = num_completed + completed_counts[subproject_name]
      num_tasks = num_tasks + #subproject
    end

    return {num_completed = num_completed, num_tasks = num_tasks}
  end,

  write_project = function(project_name, tasks, summary, buf_lines, line_to_task_data)
    -- adapted from 
    -- core/gtd/ui/displayers.lua:display_projects
    --
    -- todo: add merge request to neorg to refactor that function so there is
    -- less to copy
    local num_indent = module.public.get_project_level(project_name)
    local whitespace = string.rep(" ", num_indent - 1)

    local header =
      whitespace .. string.rep("*", num_indent) .. " " .. project_name ..
      " (" .. summary.num_completed .. "/" .. summary.num_tasks .. " done)"
    table.insert(buf_lines, header)

    local pct = module.public.percent_completed(summary.num_completed, summary.num_tasks)
    local completed_over_10 = math.floor(pct / 10)
    local percent_completed_visual = "["
      .. string.rep("=", completed_over_10)
      .. string.rep(" ", 10 - completed_over_10)
      .. "]"
    table.insert(buf_lines, whitespace .. "   " .. percent_completed_visual .. " " .. pct .. "% done")
    table.insert(buf_lines, "")

    for _, task in pairs(tasks) do
      table.insert(buf_lines, whitespace .. "   - " .. task.content)
      line_to_task_data[#buf_lines] = task
    end
    table.insert(buf_lines, '')
  end,

  buffer_open = function()
    return module.private.bufnr == vim.api.nvim_get_current_buf()
  end,

  reset = function()
    module.required["core.mode"].set_mode(
      module.required["core.mode"].get_previous_mode())

    module.private.line_to_task_data = {}
    module.private.bufnr = {}

    if module.private.buffer_open() then
      vim.cmd(":bd")
    end
  end,

  goto_task = function()
    if not module.private.buffer_open() then
      return
    end

    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local task = module.private.line_to_task_data[current_line]

    if not task then
      return
    end

    module.private.reset()

    local ts_utils = module.required["core.integrations.treesitter"].get_ts_utils()
    vim.api.nvim_win_set_buf(0, task.bufnr)
    ts_utils.goto_node(task.node)

  end,
}

module.events.defined = {
}

module.events.subscribed = {
  ["core.neorgcmd"] = { ["utilities.gtd_project_tags.views"] = true},
  ["core.keybinds"] = {
    ["core.gtd.ui.goto_task"] = true,
    ["utilities.gtd_project_tags.views"] = true,
  },
  ["core.autocommands"] = {
    winclosed = true,
    cursormoved = true,
  },
}

module.on_event = function(event)

  if vim.tbl_contains({"core.neorgcmd", "core.keybinds"}, event.split_type[1]) and
      event.split_type[2] == "utilities.gtd_project_tags.views" then
    local tasks = module.public.get_tasks()
    local projects = module.public.group_tasks_by_project(tasks)
    module.public.display_projects(projects)
  elseif event.split_type[1] == "core.keybinds" then
    if event.split_type[2] == "core.gtd.ui.goto_task" then
      module.private.goto_task()
    end
  elseif event.split_type[1] == "core.autocommands" then
      if event.split_type[2] == "winclosed" then
        module.private.reset()
      elseif event.split_type[2] == "cursormoved" then
        module.private.goto_task()
      end
  end
end

return module
