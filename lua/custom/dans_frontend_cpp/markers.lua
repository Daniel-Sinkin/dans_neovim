-- Marker-aware highlighting for C/C++/CUDA: make the mut/cpy exceptions pop
-- against the const-by-default (hidden) sea. View-only (matchadd + highlight).
--   mut (inferred from non-const, injected by the view -- never a literal) -> reddish-pink
--   cpy (and its type + name)   -> yellow
--   copy(...)                   -> yellow
-- Highlight group names are shared with view.lua, which colors the marker
-- prefix inside its overlays using the same groups.

local M = {}

local vu = require 'custom.dans_frontend_cpp.util'

local MATCH_GROUPS = {
  DansMarkerMut = true,
  DansMarkerCpy = true,
  DansConst = true,
  DansNamespace = true,
  DansMacro = true,
  DansVulkan = true,
  DansVulkanMine = true,
  DansVMA = true,
  DansSDL = true,
  DansSTB = true,
  DansBLAS = true,
  DansLLDB = true,
  DansImGui = true,
  DansQnpeps = true,
  DansCUDA = true,
  DansCUBLAS = true,
  DansConcept = true,
  DansLambda = true,
  DansString = true,
  DansAssert = true,
  DansCommentMask = true,
  DansIncludeMask = true,
}

-- Group definitions live in highlights.lua now (one place to retheme). Still
-- re-asserted on FileType + ColorScheme via this thin wrapper.
local function set_hl()
  require('custom.dans_frontend_cpp.highlights').apply()
end

-- Drop this module's window-local color matches (matchadd). Needed both before a
-- re-apply (so repeats don't stack) and when a non-cpp buffer enters a cpp window
-- (matchadd is per-window, so the colors would otherwise leak onto the other file).
local function clear_color_matches()
  for _, m in ipairs(vim.fn.getmatches()) do
    if MATCH_GROUPS[m.group] then
      pcall(vim.fn.matchdelete, m.id)
    end
  end
end

-- Prefix conceals are extmarks (this namespace), not matchadds, so they can be
-- treesitter-gated to skip string / char / comment literals -- a window matchadd
-- is syntax-blind and would strip the prefix inside e.g. the "vkCreateInstance"
-- passed to vkGetInstanceProcAddr. The color matchadds below stay matchadds:
-- coloring inside a literal shifts nothing, only concealing hides text.
local ns = vim.api.nvim_create_namespace 'ds_cpp_markers_conceal'

local in_literal = vu.in_literal -- treesitter string/char/comment/include guard

-- Prefix conceals (vim regex). `\ze` ends the match before the kept char so only
-- the prefix is hidden; `\<` keeps `_` a word char (PFN_vkCreateX keeps its vk).
-- No `code_only` wrapper -- in_literal (treesitter) does the comment/string skip,
-- which also covers block comments and char literals the `//` guard missed.
--   inline / dans_ noise; glfw/GLFW/GLFW_ (function/type/macro); the Vulkan
--   Vk/VK_/vk plus the longer DebugUtils sub-prefix. std::/dans:: are cpp-only.
local PREFIX_PATTERNS = {
  [==[\<inline\>\s*]==],
  [==[\<static\>\s*]==], -- \> stops it matching static_assert (the `_` is a word char)
  [==[\<dans_]==],
  [==[\<glfw\ze[A-Z]]==],
  [==[\<GLFW\ze[a-z]]==],
  [==[\<GLFW_\ze[A-Z0-9]]==],
  [==[\<_GLFW\ze[A-Za-z]]==], -- internal glfw, leading underscore (NOT _GLFW_X macros)
  [==[\<_glfw\ze[A-Za-z]]==],
  [==[\<VkDebugUtils\ze[A-Z]]==],
  [==[\<VK_DEBUG_UTILS_\ze[A-Z0-9]]==],
  [==[\<VK_KHR_\ze[A-Z0-9]]==], -- strip the whole KHR sub-prefix, not just VK_
  [==[\<Vk\ze[A-Z]]==],
  [==[\<VK_\ze[A-Z0-9]]==],
  [==[\<vk\ze[A-Z]]==],
  [==[\<VMA_\ze[A-Z0-9]]==], -- vulkan memory allocator
  [==[\<Vma\ze[A-Z]]==],
  [==[\<vma\ze[A-Z]]==],
  [==[\<GL_\ze[A-Z0-9]]==], -- opengl
  [==[\<gl\ze[A-Z]]==],
  [==[\<ImGui::]==], -- dear imgui: namespace, then types (ImGuiIO), Im* types, IM_ macros
  [==[\<ImGui\ze[A-Z]]==],
  [==[\<Im\ze[A-Z]]==],
  [==[\<IM_\ze[A-Z0-9]]==], -- IM_STATIC_ASSERT / IM_ASSERT* are reworded in aliases.lua
  [==[\<qnpeps_\ze[A-Za-z0-9]]==], -- qnpeps: longer prefixes first so qn_ can't eat them
  [==[\<QNPEPS_\ze[A-Z0-9]]==],
  [==[\<Qnpeps\ze[A-Za-z0-9]]==],
  [==[\<qn_\ze[A-Za-z0-9]]==],
  [==[\<cublas\ze[A-Za-z0-9]]==], -- cu* math libs before the bare cu driver prefix
  [==[\<CUBLAS_\ze[A-Z0-9]]==],
  [==[\<cusolver\ze[A-Za-z0-9]]==],
  [==[\<CUSOLVER_\ze[A-Z0-9]]==],
  [==[\<cusparse\ze[A-Za-z0-9]]==],
  [==[\<CUSPARSE_\ze[A-Z0-9]]==],
  [==[\<cufft\ze[A-Za-z0-9]]==],
  [==[\<CUFFT_\ze[A-Z0-9]]==],
  [==[\<cuda\ze[A-Za-z0-9]]==], -- cuda runtime API
  [==[\<CUDA_\ze[A-Z0-9]]==],
  [==[\<cu\ze[A-Z]]==], -- cu driver API (cuInit); lowercase cublas/cusolver excluded by [A-Z]
  [==[\<CU\ze[a-z]]==], -- CU driver types (CUresult, CUdevice); CUBLAS_ excluded by [a-z]
}
local CPP_PATTERNS = {
  [==[\<qnpeps::]==],
  [==[\<std::ranges::views::]==],
  [==[\<std::ranges::]==],
  [==[\<std::views::]==],
  [==[\<std::]==],
  [==[\<dans::]==],
}
local rx_cache = {}
local function rx(pat)
  local r = rx_cache[pat]
  if not r then
    r = vim.regex(pat)
    rx_cache[pat] = r
  end
  return r
end

-- Conceal every match of `pat` on `line` (row0) whose start is a real `\<`
-- boundary and not inside a literal. vim.regex has no start offset, so we scan a
-- shrinking suffix; a suffix-start match that is actually mid-identifier in the
-- full line is rejected by the prev-char check, so `\<` can't be faked.
local function conceal_pattern(bufnr, row0, line, pat)
  local regex = rx(pat)
  local from, n = 0, #line
  while from <= n do
    local ms, me = regex:match_str(line:sub(from + 1))
    if not ms then
      break
    end
    local s, e = from + ms, from + me
    if e <= s then
      break -- zero-width match, avoid spinning
    end
    local prev = s > 0 and line:sub(s, s) or ''
    if (prev == '' or not prev:match '[%w_]') and not in_literal(bufnr, row0, s) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row0, s, { end_col = e, conceal = '' })
    end
    from = e
  end
end

local function conceal_line(bufnr, row0, line, cpp, skip)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
  if skip.skip(row0, line) then
    return
  end
  for _, pat in ipairs(PREFIX_PATTERNS) do
    conceal_pattern(bufnr, row0, line, pat)
  end
  if cpp then
    for _, pat in ipairs(CPP_PATTERNS) do
      conceal_pattern(bufnr, row0, line, pat)
    end
  end
end

-- (Re)apply prefix conceals over the visible range. concealcursor='' reveals the
-- cursor row at Neovim's display layer, but it cannot reveal every non-cursor row
-- in a Visual selection. Therefore the extmarks also obey the shared skipper and
-- lifecycle gate, exactly like every other character-changing renderer.
local function conceal_refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ft = vim.bo[bufnr].filetype
  if not vu.is_cpp(ft) then
    return
  end
  if vu.cold_gate(bufnr) then
    return -- cold open: deferred first pass
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not vu.module_enabled(bufnr, 'markers') then
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok and parser then
    pcall(function()
      parser:parse()
    end)
  end
  local cpp = ft == 'cpp' or ft == 'cuda'
  local skip = vu.make_skipper(bufnr)
  local s0, e0 = vu.visible_range(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s0, e0, false)
  for idx, line in ipairs(lines) do
    local row0 = s0 + idx - 1
    conceal_line(bufnr, row0, line, cpp, skip)
  end
end

local function conceal_row(bufnr, row0)
  if not (vim.api.nvim_buf_is_valid(bufnr) and vu.is_cpp(vim.bo[bufnr].filetype)) then
    return
  end
  if vu.cold_gate(bufnr) then
    return
  end
  if not vu.module_enabled(bufnr, 'markers') then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, row0, row0 + 1)
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
  if line then
    local ft = vim.bo[bufnr].filetype
    conceal_line(bufnr, row0, line, ft == 'cpp' or ft == 'cuda', vu.make_skipper(bufnr))
  end
end

-- Restrict a matchadd pattern to CODE: never match once a `//` line comment has
-- started. This keeps the whole C++ frontend (conceals + coloring) out of comment
-- prose, so `// doc blocks` are a separate document that cpp_doc_markdown renders
-- as tokyonight markdown. Variable-length negative lookbehind for "a // earlier
-- on the line"; still matches every code occurrence, none after a //.
local function code_only(pat)
  return [[\%(//.*\)\@<!]] .. pat
end

local function apply(ev)
  -- Re-assert the groups here too: `:colorscheme` (e.g. the day/night swap)
  -- runs `:hi clear`, which would otherwise blank these until a ColorScheme
  -- event; defining them on FileType guarantees they exist for this buffer.
  set_hl()

  -- concealcursor is empty so the cursor line shows the real text. The prefix
  -- conceals themselves are extmarks applied by conceal_refresh (literal-aware);
  -- only the colors below are window matchadds.
  local bufnr = (ev and ev.buf) or vim.api.nvim_get_current_buf()

  -- Color matches are WINDOW-local (matchadd), so a cpp window switched to a
  -- non-cpp buffer would keep coloring `copy`/macros in e.g. an .xml. Clear them
  -- first, and bail without re-adding unless this really is a c/cpp/cuda buffer.
  clear_color_matches()
  conceal_refresh(bufnr) -- buffer-local extmarks; itself a no-op on non-cpp
  if not vu.is_cpp(vim.bo[bufnr].filetype) or not vu.module_enabled(bufnr, 'markers') then
    return
  end
  vim.opt_local.conceallevel = 2
  vim.opt_local.concealcursor = ''

  -- Window-local matches, priority above the flattened monochrome syntax.
  -- Only the keyword is colored (not the following type/name). mut/mut_unchecked
  -- are gone from source now -- the frontend (view) infers and colors them.
  -- All color matches are code_only: they never touch `//` comment prose (the
  -- doc-markdown module owns that). Only the keyword is colored, not the
  -- following type/name.
  -- `copy` groups with the mut/move/forward red -- one general "ownership" family
  -- worth highlighting; no separate yellow for it. `cpy` (the by-value marker) keeps
  -- its own yellow.
  vim.fn.matchadd('DansMarkerMut', code_only [[\<copy\>]], 20)
  vim.fn.matchadd('DansMarkerCpy', code_only [[\<cpy\>]], 20)
  -- `def` (the trailing-return function macro) reads like a definer, so color it
  -- green-bold like lambda/defer rather than letting dans_macros gray-purple it.
  vim.fn.matchadd('DansLambda', code_only [[\<def\>]], 22)
  -- `concept` / `requires` keywords in the concept cyan (the `~`-notation aliases
  -- render inline in the same color via aliases.lua).
  vim.fn.matchadd('DansConcept', code_only [[\<concept\>]], 20)
  vim.fn.matchadd('DansConcept', code_only [[\<requires\>]], 20)
  -- Gray every `const`. The leading-const conceal still hides it on non-cursor
  -- lines; this grays the ones that stay visible (args, trailing, and the
  -- leading one revealed on the cursor line).
  vim.fn.matchadd('DansConst', code_only [[\<const\>]], 20)
  -- OPENBLAS_CONST is OpenBLAS's const macro: same gray const treatment.
  -- Priority 26 so it beats the OPENBLAS_ DansBLAS library match below.
  vim.fn.matchadd('DansConst', code_only [[\<OPENBLAS_CONST\>]], 26)
  -- Gray a lowercase `ns::` scope qualifier (std::/dans::/detail::...) -- those
  -- are namespace noise. A CamelCase `Type::` (e.g. ApiVersion::vulkan(), a static
  -- method, or VkResult::eFoo) is a TYPE, not a namespace, so it's left for the
  -- type/library color matches above; only true namespaces gray out.
  vim.fn.matchadd('DansNamespace', code_only [[\<\l\w*::]], 20)
  -- Generic macro coloring lives in custom.dans_macros now: it colors the
  -- project's actual #define names (scanned with rg), falling back to the all-caps
  -- heuristic only when no scan is available. The library-prefixed macros
  -- (VK_/SDL_/GLFW/stb/LLDB_) are still colored by the matchadds below.
  -- Vulkan identifiers -> purple, at a higher priority so VK_* overrides the
  -- generic macro color above. Vk* (types) and vk* (functions) are mixed-case so
  -- they never hit the macro match anyway.
  vim.fn.matchadd('DansVulkan', code_only [[\<VK_[A-Z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', code_only [[\<Vk[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', code_only [[\<vk[A-Z][A-Za-z0-9_]*\>]], 25)
  -- First-party vulkan, brighter: `vk_*` (a raw-vk variable -- the `_` keeps it
  -- off the lib `vk[A-Z]` funcs) and `VK[A-Z]*` (a wrapper type -- the missing
  -- `_` keeps it off the `VK_` macros). Not stripped; the visible prefix plus the
  -- brighter color marks it as mine.
  vim.fn.matchadd('DansVulkanMine', code_only [[\<vk_[A-Za-z0-9_]*\>]], 26)
  vim.fn.matchadd('DansVulkanMine', code_only [[\<VK[A-Z][A-Za-z0-9_]*\>]], 26)
  -- VKAPI_ATTR / VKAPI_CALL / VKAPI_PTR are real lib macros, not my wrappers: lib
  -- color, full name kept. Priority 27 so it beats the VK[A-Z] mine-match above.
  vim.fn.matchadd('DansVulkan', code_only [[\<VKAPI_[A-Za-z0-9_]*\>]], 27)
  -- OpenGL shares the Vulkan color (same graphics domain, never both at once):
  -- GL_* macros and gl* functions.
  vim.fn.matchadd('DansVulkan', code_only [[\<GL_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVulkan', code_only [[\<gl[A-Z][A-Za-z0-9_]*\>]], 25)
  -- Vulkan Memory Allocator -> a darker shade of the Vulkan color: related but
  -- distinct. VMA_ macros, Vma* types, vma* functions.
  vim.fn.matchadd('DansVMA', code_only [[\<VMA_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVMA', code_only [[\<Vma[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansVMA', code_only [[\<vma[A-Z][A-Za-z0-9_]*\>]], 25)
  -- SDL identifiers (SDL_*) -> teal. Same priority; SDL_FOO also matches the
  -- macro pattern, so the higher priority makes the teal win.
  vim.fn.matchadd('DansSDL', code_only [[\<SDL_[A-Za-z0-9_]*\>]], 25)
  -- GLFW shares the SDL color (you wouldn't use both in one project): GLFW_*
  -- macros + GLFWwindow/GLFWmonitor types, glfw* functions, and the internal
  -- _GLFW*/_glfw* names (leading underscore, but not the _GLFW_X build macros).
  vim.fn.matchadd('DansSDL', code_only [[\<GLFW[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSDL', code_only [[\<glfw[A-Z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSDL', code_only [[\<_GLFW[A-Za-z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSDL', code_only [[\<_glfw[A-Za-z][A-Za-z0-9_]*\>]], 25)
  -- stb single-header libs -> bright cyan: stb_/stbi_/stbtt_/stbsp_/... functions
  -- and types (lowercase stb...+_), plus the STB*/STBI_/STBIDEF macros.
  vim.fn.matchadd('DansSTB', code_only [[\<stb[a-z0-9]*_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansSTB', code_only [[\<STB[A-Za-z0-9_]*\>]], 25)
  -- BLAS / LAPACK family -> yellow-green, one group for the whole numeric
  -- stack: cblas_dgemm / CBLAS_ORDER / CblasRowMajor, openblas_set_num_threads /
  -- OPENBLAS_*, lapack_int / LAPACK_* / LAPACKE_dgesv / lapacke_*, and the
  -- blasint integer type. Priority 25 so the all-caps forms beat the generic
  -- macro purple, like VK_/SDL_.
  vim.fn.matchadd('DansBLAS', code_only [[\<cblas_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<CBLAS_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<Cblas[A-Z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<openblas_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<OPENBLAS_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<lapack_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<LAPACK_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<LAPACKE_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<lapacke_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansBLAS', code_only [[\<blasint\>]], 25)
  -- LLDB identifiers -> orange: the LLDB_ macros, the SB* API classes
  -- (SBDebugger/SBTarget/...), and the bare StateType enum. Priority 25 so the
  -- all-caps LLDB_* wins over the generic macro purple (like VK_*/SDL_*).
  vim.fn.matchadd('DansLLDB', code_only [[\<LLDB_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansLLDB', code_only [[\<SB[A-Z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansLLDB', code_only [[\<StateType\>]], 25)
  -- Dear ImGui -> bordeaux: IM_* macros, ImGui::API calls, Im* types. The
  -- IM_STATIC_ASSERT / IM_ASSERT* macros are reworded gray in aliases.lua; the
  -- conceal there hides them, so coloring the underlying token is harmless.
  vim.fn.matchadd('DansImGui', code_only [[\<IM_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansImGui', code_only [[\<ImGui::[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansImGui', code_only [[\<Im[A-Z][A-Za-z0-9_]*\>]], 25)
  -- Qnpeps -> bright orchid: qnpeps:: qualified identifiers plus qn_ / qnpeps_
  -- variables+funcs, Qnpeps* types, and QNPEPS_* macros. The namespace prefix is
  -- concealed above, leaving the qualified identifier orchid. Priority 25 makes
  -- the category beat the generic namespace/macro colors.
  vim.fn.matchadd('DansQnpeps', code_only [[\<qnpeps::[A-Za-z0-9_:]*[A-Za-z0-9_]\>]], 25)
  vim.fn.matchadd('DansQnpeps', code_only [[\<qnpeps_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansQnpeps', code_only [[\<QNPEPS_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansQnpeps', code_only [[\<Qnpeps[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansQnpeps', code_only [[\<qn_[A-Za-z0-9_]*\>]], 25)
  -- CUDA intrinsics -> muted seafoam green: cuda* runtime, cu[A-Z] driver API,
  -- CU[a-z] driver types, CUDA_ macros, the __global__/__device__/... execution
  -- space qualifiers, and the <<<...>>> kernel-launch chevrons. The cu[A-Z] /
  -- CU[a-z] shapes exclude the lowercase cublas/cusolver libraries by design.
  vim.fn.matchadd('DansCUDA', code_only [[\<cuda[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[\<cu[A-Z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[\<CU[a-z][A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[\<CUDA_[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[\<__\%(global\|device\|host\|shared\|constant\|managed\|restrict\|forceinline\|noinline\|launch_bounds\)__\>]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[<<<]], 25)
  vim.fn.matchadd('DansCUDA', code_only [[>>>]], 25)
  -- cuBLAS / cuSOLVER / cuSPARSE / cuFFT -> the Vulkan orange (reused; never
  -- coexists with a Vulkan file): the cu* math libraries as one group, API names
  -- and their all-caps macros. Priority 25 so the macros beat the generic purple.
  vim.fn.matchadd('DansCUBLAS', code_only [[\<cu\%(blas\|solver\|sparse\|fft\)[A-Za-z0-9_]*\>]], 25)
  vim.fn.matchadd('DansCUBLAS', code_only [[\<CU\%(BLAS\|SOLVER\|SPARSE\|FFT\)_[A-Za-z0-9_]*\>]], 25)
  -- std::move / std::forward -> red: ownership-transfer points worth seeing (the
  -- source is left moved-from). `\zs` colors only the move/forward word; a member
  -- `.move()` (e.g. a widget) isn't std::-qualified so it's untouched.
  vim.fn.matchadd('DansMarkerMut', code_only [[\<std::\zs\%(move\|forward\)\>]], 25)
  -- assert / static_assert -> gray the whole `...assert(...);` statement, marking
  -- it as skim-past checking code. Priority 36 sits above both the macro/Vk/SDL
  -- coloring in the condition AND the string-literal green (35) below, so a
  -- static_assert's message string reads gray with the rest of the check, not as a
  -- standout green. static_assert is also left fully verbatim
  -- (util.static_assert_lines skips every conceal/sugar), so the gray sits on top
  -- of the real, un-cut text -- a `VkResult` inside reads as a gray `VkResult`,
  -- not a misleading `Result`.
  vim.fn.matchadd('DansAssert', code_only [[\<\%(static_\)\?assert\>.\{-};]], 36)
  -- String literals -> green, priority 35 (above the other color matches) so a
  -- Vk*/macro token inside a string is not recolored. Concealing inside strings is
  -- separately prevented: the prefix conceals are treesitter-gated extmarks, not
  -- matchadds, so priority isn't what guards them. Quoted pattern (a "..." literal
  -- with escapes); not [[...]] -- the [^"\] class would trip the long-string
  -- parser. Single-line strings only.
  vim.fn.matchadd('DansString', code_only '"\\%(\\\\.\\|[^"\\\\]\\)*"', 35)
  -- The string TYPE reads like a string: std::string and const char* get the
  -- same "..."-literal green so a function returning a string stands out. \> keeps
  -- std::string from also matching inside std::string_view; the const-char form
  -- covers `const char*` / `const char *`.
  vim.fn.matchadd('DansString', code_only [[\<std::string\>]], 24)
  vim.fn.matchadd('DansString', code_only [[\<\%(std::\)\?string_view\>]], 24)
  -- gsl C-string aliases: zstring/czstring/wzstring/cwzstring/u16zstring/... and
  -- basic_zstring -- all pointers to a (zero-terminated) C string, so green too.
  vim.fn.matchadd('DansString', code_only [[\<\%(basic_\)\?[cwu0-9]*zstring\>]], 24)
  -- CamelCase string types: the z-string family (ZString / CZString / ...) and
  -- FString / CFString (Unreal / CoreFoundation) -- all strings, same green.
  vim.fn.matchadd('DansString', code_only [[\<\u*[ZF]String\>]], 24)
  vim.fn.matchadd('DansString', code_only [[\<const\s\+char\s*\*]], 24)
  -- Masks (priority 28): the color matches are syntax-blind, so they'd color
  -- tokens inside /* block comments */ and #include <...> paths. Recolor those
  -- back to neutral. `\_.` so the mask spans a MULTI-LINE block comment (the big
  -- /** ... */ doxygen blocks in headers), not just single-line ones -- otherwise
  -- `copy`, a #define, etc. inside one keep their code color. There is no // mask:
  -- code_only keeps every match out of // line comments already.
  vim.fn.matchadd('DansCommentMask', [[/\*\_.\{-}\*/]], 28)
  -- Per-line block-comment masks too: the multiline pattern above lags when the
  -- `/*` is scrolled off-screen (Vim won't scan far enough back), which let the
  -- library colors flash on a comment until the view settled. These are anchored
  -- to the line start, so they match every block-comment line on its own with no
  -- backward scan -- the opener `/*...`, and continuation/closer `* ...` / `*/`.
  -- The continuation form requires the `*` to be followed by whitespace, `/`, or
  -- end-of-line so it stays off pointer-deref statements (`*ptr = v;`, `*out`),
  -- which start `\s*\*` too and would otherwise gray the whole line as a comment.
  vim.fn.matchadd('DansCommentMask', [[^\s*/\*.*]], 28)
  vim.fn.matchadd('DansCommentMask', [[^\s*\*\%(\s\|/\|$\).*]], 28)
  -- Quoted (not [[...]]): the trailing [>"] char class would close a long string.
  vim.fn.matchadd('DansIncludeMask', '^\\s*#\\s*include\\s*\\zs[<"].\\{-}[>"]', 28)
end

-- Re-apply for a buffer after a :DansFrontend toggle (synthesize the FileType
-- event apply() reads its filetype from).
function M.refresh(bufnr)
  apply { match = vim.bo[bufnr].filetype, buf = bufnr }
end

function M.setup()
  set_hl()
  local group = vim.api.nvim_create_augroup('ds_cpp_markers', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = { 'c', 'cpp', 'cuda' },
    callback = function(ev)
      apply(ev)
    end,
  })
  -- On entering ANY buffer: re-apply for a cpp buffer (matchadds were cleared when
  -- a non-cpp buffer was entered in this window), and clear the window's cpp color
  -- matches when it's not cpp -- this is what stops `copy`/macros coloring an .xml
  -- shown in a cpp window.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if vu.is_cpp(vim.bo[ev.buf].filetype) then
        apply(ev) -- also refreshes conceals, so it's not in the on_decorate list
      else
        clear_color_matches()
      end
    end,
  })
  -- Prefix conceals are visible-range extmarks. Edits and settled scrolling get a
  -- full pass; cursor/mode transitions repaint only reveal-set delta rows.
  -- Buffer-enter is handled by apply above.
  vu.on_decorate(group, { 'TextChanged', 'TextChangedI', 'CursorMoved', 'CursorMovedI' }, conceal_refresh, conceal_row)
  -- Re-assert colors after a colorscheme change (tokyonight day/night swap).
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
end

return M
