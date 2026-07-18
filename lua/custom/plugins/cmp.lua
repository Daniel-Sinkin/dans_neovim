local quiet_source_names = { 'buffer', 'path' }
local language_source_names = { 'lazydev', 'nvim_lsp', 'path', 'buffer', 'nvim_lsp_signature_help' }
local completion_plugin = 'hrsh7th/nvim-cmp'

local function source_specs(names)
  local specs = {}
  for index, name in ipairs(names) do
    specs[index] = { name = name }
  end
  specs[1].group_index = names == language_source_names and 0 or nil
  return specs
end

return {
  {
    completion_plugin,
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/cmp-buffer' },
      { 'hrsh7th/cmp-nvim-lsp' },
      { 'hrsh7th/cmp-nvim-lsp-signature-help' },
      { 'hrsh7th/cmp-path' },
    },
    config = function()
      local completion = require('cmp')
      local authoring = require('custom.cpp_authoring')
      local language_completion = false

      local function expand_snippet(item)
        vim.snippet.expand(item.body)
      end

      local function selected_sources()
        return source_specs(language_completion and language_source_names or quiet_source_names)
      end

      local function move_or_author(direction, fallback)
        if completion.visible() then
          if direction > 0 then
            completion.select_next_item()
          else
            completion.select_prev_item()
          end
        elseif not authoring.tab(direction) then
          fallback()
        end
      end

      completion.setup({
        enabled = function()
          return vim.bo.buftype ~= 'prompt' and not authoring.completion_active()
        end,
        completion = { completeopt = table.concat({ 'menu', 'menuone', 'noinsert' }, ',') },
        snippet = { expand = expand_snippet },
        mapping = completion.mapping.preset.insert({
          ['<C-n>'] = completion.mapping.select_next_item(),
          ['<C-p>'] = completion.mapping.select_prev_item(),
          ['<C-b>'] = completion.mapping.scroll_docs(-4),
          ['<C-f>'] = completion.mapping.scroll_docs(4),
          ['<C-y>'] = completion.mapping.confirm({ select = false }),
          ['<CR>'] = completion.mapping.confirm({ select = false }),
          ['<Tab>'] = completion.mapping(function(fallback)
            move_or_author(1, fallback)
          end, { 'i', 's' }),
          ['<S-Tab>'] = completion.mapping(function(fallback)
            move_or_author(-1, fallback)
          end, { 'i', 's' }),
          ['<C-Space>'] = completion.mapping.complete(),
        }),
        sources = selected_sources(),
      })

      vim.keymap.set('n', '<leader>tc', function()
        language_completion = not language_completion
        completion.setup({ sources = selected_sources() })
        vim.notify(('LSP completion %s'):format(language_completion and 'on' or 'off'), vim.log.levels.INFO)
      end, { desc = '[T]oggle LSP [C]ompletion' })
    end,
  },
}
