local a      = require('packer/async')
local jobs   = require('packer/jobs')
local util   = require('packer/util')
local result = require('packer/result')
local log    = require('packer/log')

local slice = util.slice

local config = nil
local plugin_utils = {}
plugin_utils.cfg = function(_config)
  config = _config
end

plugin_utils.guess_type = function(plugin)
  if plugin.installer then
    plugin.type = 'custom'
  elseif vim.fn.isdirectory(plugin.path) ~= 0 then
    plugin.url = plugin.path
    plugin.type = 'local'
  elseif
    slice(plugin.path, 1, 6) == 'git://'
    or slice(plugin.path, 1, 4) == 'http'
    or string.match(plugin.path, '@')
  then
    plugin.url = plugin.path
    plugin.type = 'git'
  else
    plugin.url = 'https://github.com/' .. plugin.path
    plugin.type = 'git'
  end
end

plugin_utils.list_installed_plugins = function()
  local opt_plugins = {}
  local start_plugins = {}
  for _, path in ipairs(vim.fn.globpath(config.opt_dir, '*', true, true)) do
    opt_plugins[path] = true
  end

  for _, path in ipairs(vim.fn.globpath(config.start_dir, '*', true, true)) do
    start_plugins[path] = true
  end

  return opt_plugins, start_plugins
end

plugin_utils.helptags_stale = function(dir)
  -- Adapted directly from minpac.vim
  local txts = vim.fn.glob(util.join_paths(dir, '*.txt'), true, true)
  txts = vim.list_extend(txts, vim.fn.glob(util.join_paths(dir, '*.[a-z][a-z]x'), true, true))
  local tags = vim.fn.glob(util.join_paths(dir, 'tags'), true, true)
  tags = vim.list_extend(tags, vim.fn.glob(util.join_paths(dir, 'tags-[a-z][a-z]'), true, true))
  local txt_newest = math.max(unpack(util.map(vim.fn.getftime, txts)))
  local tag_oldest = math.min(unpack(util.map(vim.fn.getftime, tags)))
  return txt_newest > tag_oldest
end

plugin_utils.update_helptags = vim.schedule_wrap(function(...)
  for _, dir in ipairs(...) do
    local doc_dir = util.join_paths(dir, 'doc')
    if plugin_utils.helptags_stale(doc_dir) then
      log.info('Updating helptags for ' .. doc_dir)
      vim.api.nvim_command('silent! helptags ' .. vim.fn.fnameescape(doc_dir))
    end
  end
end)

plugin_utils.update_rplugins = vim.schedule_wrap(function()
  vim.api.nvim_command('UpdateRemotePlugins')
end)

plugin_utils.ensure_dirs = function()
  if vim.fn.isdirectory(config.opt_dir) == 0 then
    vim.fn.mkdir(config.opt_dir, 'p')
  end

  if vim.fn.isdirectory(config.start_dir) == 0 then
    vim.fn.mkdir(config.start_dir, 'p')
  end
end

plugin_utils.find_missing_plugins = function(plugins, opt_plugins, start_plugins)
  if opt_plugins == nil or  start_plugins == nil then
    opt_plugins, start_plugins = plugin_utils.list_installed_plugins()
  end

  local missing_plugins = {}
  for _, plugin_name in ipairs(vim.tbl_keys(plugins)) do
    local plugin = plugins[plugin_name]
    if
      (not plugin.opt
      and not start_plugins[util.join_paths(config.start_dir, plugin.short_name)])
      or (plugin.opt
      and not opt_plugins[util.join_paths(config.opt_dir, plugin.short_name)])
    then
      table.insert(missing_plugins, plugin_name)
    end
  end

  return missing_plugins
end

plugin_utils.load_plugin = function(plugin)
  if plugin.opt then
    vim.api.nvim_command('packadd ' .. plugin.short_name)
  else
    vim.o.runtimepath = vim.o.runtimepath .. ',' .. plugin.install_path
    for _, pat in ipairs({'plugin/**/*.vim', 'after/plugin/**/*.vim'}) do
      local path = util.join_paths(plugin.install_path, pat)
      if #vim.fn.glob(path) > 0 then
        vim.api.nvim_command('silent exe "source ' .. path .. '"')
      end
    end
  end
end

plugin_utils.post_update_hook = function(plugin, disp)
  local plugin_name = util.get_plugin_full_name(plugin)
  return a.sync(function()
    if plugin.run or not plugin.opt then
      a.wait(vim.schedule)
      plugin_utils.load_plugin(plugin)
    end
    if plugin.run then
      disp:task_update(plugin_name, 'running post update hook...')
      if type(plugin.run) == 'function' then
        if pcall(plugin.run(plugin)) then
          return result.ok(true)
        else
          return result.err({ msg = 'Error running post update hook' })
        end
      elseif type(plugin.run) == 'string' then
        if string.sub(plugin.run, 1, 1) == ':' then
          a.wait(vim.schedule)
          vim.api.nvim_command(string.sub(plugin.run, 2))
          return result.ok(true)
        else
          local hook_output = { err = {}, output = {} }
          local hook_callbacks = {
            stderr = jobs.logging_callback(hook_output.err, hook_output.output),
            stdout = jobs.logging_callback(hook_output.err, hook_output.output, nil, disp, plugin_name)
          }
          local cmd = {
            os.getenv('SHELL'),
            '-c',
            'cd ' .. plugin.install_path .. ' && ' .. plugin.run
          }
          return a.wait(jobs.run(cmd , { capture_output = hook_callbacks }))
        end
      else
        return a.wait(jobs.run(plugin.run))
      end
    else
      return result.ok(true)
    end
  end)
end

return plugin_utils
