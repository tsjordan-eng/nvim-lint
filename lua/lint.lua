local uv = vim.loop
local api = vim.api
local M = {}
local CLIENT_ID_OFFSET = 1000  -- arbitrary value that is large enough to not conflict with real clients


M.linters = setmetatable({}, {
  __index = function(tbl, key)
    local ok, linter = pcall(require, 'lint.linters.' .. key)
    if ok then
      rawset(tbl, key, linter)
    end
    return linter
  end,
})


M.linters_by_ft = {
  text = {'vale',},
  markdown = {'vale',},
  rst = {'vale',},
  ruby = {'ruby',},
  inko = {'inko',},
  clojure = {'clj-kondo',},
  dockerfile = {'hadolint',},
}


local function resolve_linters()
  local ft = vim.api.nvim_buf_get_option(0, 'filetype')
  local linter_names = M.linters_by_ft[ft]
  return vim.tbl_map(
    function(name)
      return assert(M.linters[name], 'Linter with name `' .. name .. '` not available')
    end,
    linter_names or {}
  )
end


local function mk_publish_diagnostics(client_id)
  local method = 'textDocument/publishDiagnostics'
  return function(diagnostics, bufnr)
    local result = {
      uri = vim.uri_from_bufnr(bufnr),
      diagnostics = assert(
        diagnostics,
        'Linter parser is supposed to return a list of diagnostics, got: ' .. vim.inspect(diagnostics)
      ),
    }
    vim.lsp.handlers[method](nil, method, result, client_id, bufnr)
  end
end


local function read_output(bufnr, parser, publish_fn)
  return function(err, chunk)
    assert(not err, err)
    if chunk then
      parser.on_chunk(chunk, bufnr)
    else
      parser.on_done(publish_fn, bufnr)
    end
  end
end


local function start_read(stream, stdout, stderr, bufnr, parser, client_id)
  local publish = mk_publish_diagnostics(client_id)

  if not stream or stream == 'stdout' then
    stdout:read_start(read_output(bufnr, parser, publish))
  elseif stream == 'stderr' then
    stderr:read_start(read_output(bufnr, parser, publish))
  elseif stream == 'both' then
    local parser1, parser2 = require('lint.parser').split(parser)
    stdout:read_start(read_output(bufnr, parser1, publish))
    stderr:read_start(read_output(bufnr, parser2, publish))
  else
    error('Invalid `stream` setting: ' .. stream)
  end
end


function M.try_lint(names)
  if type(names) == "string" then
    names = { names }
  end
  local linters
  if names then
    linters = vim.tbl_map(
      function(name)
        return assert(M.linters[name], 'Linter with name `' .. name .. '` not available')
      end,
      names
    )
  else
    linters = resolve_linters()
  end
  for i, linter in pairs(linters) do
    local ok, err = pcall(M.lint, linter, CLIENT_ID_OFFSET + i)
    if not ok then
      vim.notify(err)
    end
  end
end


local function eval_fn_or_id(x)
  if type(x) == 'function' then
    return x()
  else
    return x
  end
end


function M.lint(linter, client_id)
  assert(linter, 'lint must be called with a linter')
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle
  local env
  local pid_or_err
  local args = {}
  local bufnr = api.nvim_get_current_buf()
  if type(linter) == "function" then
    linter = linter()
  end
  if linter.args then
    vim.list_extend(args, vim.tbl_map(eval_fn_or_id, linter.args))
  end
  if not linter.stdin and linter.append_fname ~= false then
    table.insert(args, api.nvim_buf_get_name(bufnr))
  end
  if linter.env then
    if not linter.env["PATH"] then
      -- Always include PATH as we need it to execute the linter command
      env = {"PATH=" .. os.getenv("PATH")}
    end
    for k, v in pairs(linter.env) do
      table.insert(env, k .. "=" .. v)
    end
  end
  local opts = {
    args = args,
    stdio = {stdin, stdout, stderr},
    env = env,
    cwd = vim.fn.getcwd(),
    detached = true
  }
  assert(linter.cmd, 'Linter definition must have a `cmd` set: ' .. vim.inspect(linter))
  handle, pid_or_err = uv.spawn(linter.cmd, opts, function(code)
    stdout:close()
    stderr:close()
    handle:close()
    if code ~= 0 and not linter.ignore_exitcode then
      print('Linter command', linter.cmd, 'exited with code', code)
    end
  end)
  assert(handle, 'Error running ' .. linter.cmd .. ': ' .. pid_or_err)
  local parser = linter.parser
  if type(parser) == 'function' then
    parser = require('lint.parser').accumulate_chunks(parser)
  end
  assert(
    parser.on_chunk and type(parser.on_chunk == 'function'),
    'Parser requires a `on_chunk` function'
  )
  assert(
    parser.on_done and type(parser.on_done == 'function'),
    'Parser requires a `on_done` function'
  )
  start_read(linter.stream, stdout, stderr, bufnr, parser, client_id)
  if linter.stdin then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
    for _, line in ipairs(lines) do
      stdin:write(line .. '\n')
    end
    stdin:write('', function()
      stdin:shutdown()
      stdin:close()
    end)
  else
    stdin:close()
  end
end


return M
