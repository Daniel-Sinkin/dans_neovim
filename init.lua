-- Entry point. The real config lives under lua/config/ (non-plugin setup)
-- and lua/custom/plugins/ (one file per plugin spec). See the repository
-- AGENTS.md and generated knowledge catalog for the operating contract/map.

require 'config.options'
require 'config.keymaps'
require 'config.autocmds'
require 'config.lazy'

require('custom.language_support').setup()
require('custom.julia_scope').setup()
require('custom.julia_progress').setup()
require('custom.dans_frontend_cpp').setup()
require('custom.cpp_authoring').setup()
require('custom.cpp_doc_markdown').setup()
require('custom.dans_perf').setup()
require('custom.dans_diagmark').setup()
require('custom.dans_macros').setup()
require('custom.dans_asm').setup()
require('custom.cpp_runner').setup()
require('custom.cpp_codegen').setup()
require('custom.cpp_tools.project').setup()
require('custom.dans_keylog').setup()
require('custom.dans_protect').setup()
require('custom.dans_mode').setup()
require('custom.dans_menu').setup()
