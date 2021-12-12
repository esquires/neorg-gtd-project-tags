require("neorg.modules.base")
require('neorg.events')

local module = neorg.modules.create("utilities.gtd_project_tags")

module.setup = function()
  return {
    success = true,
    requires = {
      "core.autocommands",
      "core.gtd.ui",
      "core.gtd.ui.displayers",
      "core.gtd.queries",
      "core.integrations.treesitter",
      "core.keybinds",
      "core.neorgcmd",
      "core.mode",
      "core.queries.native",
      "core.ui",
      "core.norg.completion",
    }
  }
end

module.load = function()
  module.required["core.neorgcmd"].add_commands_from_table({
    definitions = { gtd_project_tags = {} },
    data = { gtd_project_tags = { args = 0, name = "utilities.gtd_project_tags.views" } }
  })
  module.required["core.keybinds"].register_keybind(module.name, "views")
  module.required["core.autocommands"].enable_autocommand("BufLeave")

  -- add project tag to completions
  for _, completion in pairs(module.required["core.norg.completion"].completions) do
    if vim.tbl_contains(completion.complete, "contexts") then
      table.insert(completion.complete, "project")

      local completion_table = {
        regex = "project%s+%w*",
        complete = function(context, prev, saved) return vim.tbl_keys(module.public.group_tasks_by_project(module.public.get_tasks())) end,
        options = {type = "GTDContext"},
        descend = {},
      }
      table.insert(completion.descend, completion_table)
    end
    
  end
end

module.public = {
  version = '0.1',

  get_tasks = function()
    local configs = neorg.modules.get_module_config("core.gtd.base")
    local exclude_files = configs.exclude
    table.insert(exclude_files, configs.default_lists.inbox)

    local tasks = module.required["core.gtd.queries"].get("tasks", { exclude_files = exclude_files })
    local tasks = module.required["core.gtd.queries"].add_metadata(tasks, "task")

    for _, task in pairs(tasks) do
      task["project_node"] = module.required["core.gtd.queries"].get_tag(
        "project", task, "task", {extract = true}, {"project"})
    end

    return tasks
  end,

  group_tasks_by_project = function(tasks)
    projects = {}
    for _, task in pairs(tasks) do
      task.project_node =
      module.required["core.gtd.queries"].insert(projects, (task.project_node or {'_'})[1], task)
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

  generate_display = function(name, buf_lines, project_lines)
    local bufnr = module.required["core.ui"].create_norg_buffer(name, "vsplitr", nil, false)
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
}

module.config.public = {
}

module.private = {
  line_to_task_data = {},
  bufnr = nil,

  add_unknown_projects = function(projects, buf_lines, line_to_task_data, project_lines)
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
    local num_indent = module.public.get_project_level(project_name)
    local whitespace = string.rep(" ", num_indent - 1)

    local header =
      whitespace .. string.rep("*", num_indent) .. " " .. project_name ..
      " (" .. summary.num_completed .. "/" .. summary.num_tasks .. " done)"
    table.insert(buf_lines, header)

    local pct = module.required["core.gtd.ui.displayers"].percent(
      summary.num_completed, summary.num_tasks)
    local pct_str = module.required["core.gtd.ui.displayers"].percent_string(pct)
    table.insert(buf_lines, whitespace .. "   " .. pct_str .. " " .. pct .. "% done")
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
    if module.required['core.mode'].get_mode() == 'gtd-displays' then
      module.required["core.mode"].set_mode(
        module.required["core.mode"].get_previous_mode())
    end

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
  ["core.autocommands"] = { bufleave = true, },
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
      if event.split_type[2] == "bufleave" then
        module.private.reset()
      end
  end
end

return module
