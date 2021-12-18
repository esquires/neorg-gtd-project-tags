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
    data = { gtd_project_tags = { args = 3, name = "utilities.gtd_project_tags.views" } }
  })
  module.required["core.keybinds"].register_keybind(module.name, "views")
  module.required["core.keybinds"].register_keybind(module.name, "views_undone")
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
    local projects = {}
    for _, task in pairs(tasks) do
      task.project_node = module.required["core.gtd.queries"].insert(
        projects, (task.project_node or {'_'})[1], task)
    end

    -- add any parent project names that may be missing
    local project_names = vim.tbl_keys(projects)
    for project_name, _ in pairs(projects) do
      local parent_project_names = module.public.get_parent_project_names(project_name)
      for _, parent_project_name in pairs(parent_project_names) do
        if not vim.tbl_contains(project_names, parent_project_name) then
          projects[parent_project_name] = {}
        end
      end
    end

    return projects
  end,

  get_parent_project_names = function(project_name)
    local split_names = vim.split(project_name, '/')
    table.remove(split_names)

    if #split_names == 0 then
      return {}
    end

    local name = split_names[1]
    local parent_project_names = {}
    table.insert(parent_project_names, name)

    for i = 2, #split_names, 1 do
      name = name .. '/' .. split_names[i]
      table.insert(parent_project_names, name)
    end

    return parent_project_names
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

  display_projects = function(projects, show_completed, write_extra)
    -- this function does a similar action to
    -- core/gtd/ui/displayers.lua:display_projects
    -- but uses the #project to generate project organization
    vim.validate({
      projects = { projects, "table" },
    })

    local name = "ProjectsTags"
    local buf_lines = {"*" .. name .. "*", ""}
    local line_to_task_data = {}
    local project_lines = {}

    module.private.add_unknown_projects(
      projects, buf_lines, write_extra, line_to_task_data, project_lines)
    local completed_counts = module.private.get_completed_counts(projects)
    module.private.add_known_projects(
      projects, completed_counts, write_extra, buf_lines, line_to_task_data,
      project_lines, show_completed)

    module.public.generate_display(name, buf_lines, project_lines)
    module.public.add_folds(project_lines)
    module.private.line_to_task_data = line_to_task_data
  end,

  generate_display = function(name, buf_lines, project_lines)
    if module.private.bufnr ~= nil then
      vim.api.nvim_buf_delete(module.private.bufnr, {force = true})
    end
    local bufnr = module.required["core.ui"].create_norg_buffer(name, "vsplitr", nil, { del_on_autocommands = {} })
    vim.cmd(('autocmd BufEnter <buffer=%s> lua put(require("neorg.modules.utilities.gtd-project-tags.module").public.set_gtd_display_mode())'):format(bufnr))
    vim.cmd(('autocmd BufLeave <buffer=%s> lua require("neorg.modules.utilities.gtd-project-tags.module").public.reset_mode()'):format(bufnr))

    module.private.bufnr = bufnr
    module.required["core.mode"].set_mode("gtd-displays")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)

    vim.api.nvim_buf_set_option(buf, "modifiable", false)

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

  remove_completed_tasks = function(tasks)
    return vim.tbl_filter(function(task, _) return task.state ~= "done" end, tasks)
  end,

  remove_future_tasks = function(tasks)
    -- if waiting for something, remove if done date is before today
    -- otherwise remove if start date is before today
    local after_today = module.required['core.gtd.queries'].starting_after_today

    local filtered_tasks = {}

    for _, task in pairs(tasks) do
      local rm = false
      if task['waiting.for'] ~= nil then
        -- someone else's task
        rm = rm or (task['time.due'] ~= nil and after_today(task['time.due'][1]))
      else
        -- our own task
        if task['time.start'] ~= nil and task['time.due'] ~= nil then
          rm = rm or after_today(task['time.start'][1])
        elseif task['time.due'] ~= nil then
          rm = rm or after_today(task['time.due'][1])
        elseif task['time.start'] ~= nil then
          rm = rm or after_today(task['time.start'][1])
        end
      end

      if not rm then
        table.insert(filtered_tasks, task)
      end
    end
    return filtered_tasks
  end,

  str2bool = function(string)
    return string == "1" or string == "true"
  end,

  set_gtd_display_mode = function()
    module.required["core.mode"].set_mode("gtd-displays")
  end,

  reset_mode = function()
    if module.required['core.mode'].get_mode() == 'gtd-displays' then
      module.required["core.mode"].set_mode(
        module.required["core.mode"].get_previous_mode())
    end
  end,

}

module.config.public = {
}

module.private = {
  line_to_task_data = {},
  bufnr = nil,

  add_unknown_projects = function(projects, buf_lines, write_extra, line_to_task_data, project_lines)
    local unknown_project = projects["_"]
    if unknown_project and #unknown_project > 0 then
      local undone = module.public.remove_completed_tasks(unknown_project)
      table.insert(buf_lines, "- /" .. #undone .. " tasks don't have a project assigned/")

      if #undone > 0 then
        table.insert(buf_lines, "")
        project_lines['_'] = {beg_line = #buf_lines}
        for _, task in pairs(undone) do
          module.private.write_task(task, '', write_extra, buf_lines, line_to_task_data)
        end
        project_lines['_'].end_line = #buf_lines
      end
      table.insert(buf_lines, "")
    end
  end,

  add_known_projects = function(
      projects, completed_counts, write_extra, buf_lines, line_to_task_data,
      project_lines, show_completed)
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
          local offset = show_completed and 3 or 2
          project_lines[project_name] = {beg_line = #buf_lines + offset}
          module.private.write_project(
            project_name, tasks, summary, show_completed, write_extra,
            buf_lines, line_to_task_data)

          project_lines[project_name].end_line = #buf_lines - 1
          for _, name in pairs(module.public.get_parent_project_names(project_name)) do
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

  write_project = function(
      project_name, tasks, summary, show_completed, write_extra, buf_lines, line_to_task_data)
    -- adapted from 
    -- core/gtd/ui/displayers.lua:display_projects
    local num_indent = module.public.get_project_level(project_name)
    local whitespace = string.rep(" ", num_indent - 1)

    local header = whitespace .. string.rep("*", num_indent) .. " " .. project_name

    if show_completed then
      header = header .. 
        " (" .. summary.num_completed .. "/" .. summary.num_tasks .. " done)"
    else
      header = header .. " (" .. summary.num_tasks .. ")"
    end

    table.insert(buf_lines, header)

    local pct = module.required["core.gtd.ui.displayers"].percent(
      summary.num_completed, summary.num_tasks)
    if show_completed then
      local pct_str = module.required["core.gtd.ui.displayers"].percent_string(pct)
      table.insert(buf_lines, whitespace .. "   " .. pct_str .. " " .. pct .. "% done")
    end
    table.insert(buf_lines, "")

    if #tasks > 0 then
      for _, task in pairs(tasks) do
        module.private.write_task(task, whitespace, write_extra, buf_lines, line_to_task_data)
      end
      table.insert(buf_lines, '')
    end
  end,

  buffer_open = function()
    return module.private.bufnr == vim.api.nvim_get_current_buf()
  end,

  reset_data = function()
    module.private.line_to_task_data = {}
    module.private.bufnr = nil
  end,

  write_task = function(task, whitespace, write_extra, buf_lines, line_to_task_data)
    table.insert(buf_lines, whitespace .. "   - " .. task.content)
    line_to_task_data[#buf_lines] = task

    if write_extra then
        local extra_line = ''
        local add_comma = function()
          if #extra_line > 0 then
            extra_line = extra_line .. ', '
          end
        end

        local add_to_extra_line = function(key, abbr)
          if task[key] ~= nil then
            local diff = module.required['core.gtd.queries'].diff_with_today(task[key][1])
            add_comma()
            extra_line = extra_line .. abbr .. ': '
            if diff.weeks ~= 0 then
              extra_line = extra_line .. diff.weeks .. 'w' .. math.abs(diff.days) .. 'd'
            else
              extra_line = extra_line .. diff.days .. 'd'
            end
          end
        end

        add_to_extra_line('time.start', 'start')
        add_to_extra_line('time.due', 'due')

        if task['waiting.for'] ~= nil then
          add_comma()
          extra_line = extra_line .. 'waiting for: ' .. table.concat(task['waiting.for'], ', ')
        end

        if #extra_line > 0 then
          table.insert(buf_lines, whitespace .. '     (' .. extra_line .. ')')
          line_to_task_data[#buf_lines] = task
        end
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

    local ts_utils = module.required["core.integrations.treesitter"].get_ts_utils()
    if vim.tbl_contains(vim.fn.tabpagebuflist(), task.bufnr) then
      -- switch to that window
      local winnr = vim.api.nvim_eval("bufwinnr(" .. task.bufnr .. ")")
      vim.cmd("exe " .. winnr .. '" wincmd w"')
    else
      local window_numbers = vim.api.nvim_tabpage_list_wins(0)
      if #window_numbers > 1 then
        local curr_winnr = vim.api.nvim_get_current_win()
        local new_winnr = window_numbers[1] == curr_winnr and window_numbers[2] or window_numbers[1]
        vim.api.nvim_set_current_win(new_winnr)
        vim.api.nvim_set_current_buf(task.bufnr)
      end

    end

    module.public.reset_mode()
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

  display_helper = function(show_completed, show_future, write_extra)
    local tasks = module.public.get_tasks()
    if not show_completed then
      tasks = module.public.remove_completed_tasks(tasks)
    end

    if not show_future then
      tasks = module.public.remove_future_tasks(tasks)
    end

    local projects = module.public.group_tasks_by_project(tasks)
    module.public.display_projects(projects, show_completed, write_extra)
  end

  if event.split_type[1] == "core.keybinds" then
    if event.split_type[2] == "core.gtd.ui.goto_task" then
      module.private.goto_task()
    elseif event.split_type[2] == "utilities.gtd_project_tags.views" then
      display_helper(true, true, true)
    end
  elseif event.split_type[1] == "core.neorgcmd" and
      event.split_type[2] == "utilities.gtd_project_tags.views" then
    local str2bool = module.public.str2bool
    display_helper(str2bool(event.content[1]), str2bool(event.content[2]), str2bool(event.content[3]))
  end
end

return module
