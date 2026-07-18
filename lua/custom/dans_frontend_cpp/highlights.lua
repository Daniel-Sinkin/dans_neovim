-- Every highlight group the dans-cpp-frontend defines, in one place. Today they
-- layer on top of tokyonight; centralizing them is the first step toward a
-- self-contained dans-cpp-dark / dans-cpp-light set that drops tokyonight
-- entirely. apply() is called on setup and re-asserted on ColorScheme (a
-- `:colorscheme` runs `:hi clear`, which would otherwise blank these).

local M = {}

function M.apply()
  local hi = function(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end
  -- mut / mut_unchecked -> reddish-pink. Not bold: mut is inferred everywhere
  -- now, so bold red was too aggressive.
  hi('DansMarkerMut', { fg = '#f7768e' })
  -- cpy (and its type + name) / copy(...) -> yellow.
  hi('DansMarkerCpy', { fg = '#e0af68', bold = true })
  -- `lambda` pseudo-keyword in the lambda rendering: green to read as a
  -- declaration keyword, distinct from the mut/cpy markers.
  hi('DansLambda', { fg = '#9ece6a', bold = true })
  -- Vulkan identifiers (Vk*, VK_*, vk*) -- the copy()/cpy yellow but not bold
  -- (bold was too heavy for how dense these are), distinct from the generic macro
  -- purple. The Vk/VK_ prefixes are concealed in markers.lua, so only the
  -- meaningful tail shows in this color.
  -- Vulkan + OpenGL (Vk/VK_/vk, GL_/gl) -- a muted orange. Same color: same
  -- graphics domain, never both in one project. The user's own vulkan-adjacent
  -- names (vk_ vars, VK* wrappers) get the brighter DansVulkanMine below; lib vs
  -- mine read as the same family, brightness telling them apart.
  hi('DansVulkan', { fg = '#d98248' })
  -- First-party vulkan: a raw-vk variable (vk_handle) or a thin wrapper type
  -- (VKBuffer) -- the brighter orange against the muted lib one.
  hi('DansVulkanMine', { fg = '#ff9540' })
  -- `.sType = VK_STRUCTURE_TYPE_*` rendered as the bare struct identity
  -- (InstanceCreateInfo): a bright bold orange so it reads as the struct's title.
  hi('DansVkStructName', { fg = '#ffb070', bold = true })
  -- Vulkan Memory Allocator (VMA_/Vma/vma) -- a darker shade of the Vulkan orange,
  -- so it reads as related but a separate library.
  hi('DansVMA', { fg = '#ad5f24' })
  -- Qnpeps (qn_/qnpeps_/Qnpeps/QNPEPS_) -- a bright orchid purple-pink, roughly
  -- as bright as the Vulkan orange and, like it, not bold. Distinct from the
  -- macro lavender below and the ImGui bordeaux, so it reads as its own library
  -- sitting next to dense macro purple. Prefixes are concealed in markers.lua.
  hi('DansQnpeps', { fg = '#e46fd9' })
  -- CUDA intrinsics (cuda*/cu[A-Z] driver API, CU[a-z] types, CUDA_ macros,
  -- __global__/__device__/... qualifiers, the <<<...>>> launch chevrons) -- a
  -- muted seafoam green, less saturated than the lambda green and clear of the
  -- BLAS olive, the sage string, and the STB teal. Never the cu* libraries
  -- (cublas/cusolver): those are matched separately.
  hi('DansCUDA', { fg = '#6fb08c' })
  -- cu* math libraries (cublas/cusolver/cusparse/cufft + CUBLAS_/... macros) --
  -- one group in the Vulkan orange. A CUDA-BLAS file and a Vulkan file never
  -- coexist, so sharing the hue costs nothing and keeps the palette small;
  -- grouped and prefix-concealed like the rest.
  hi('DansCUBLAS', { fg = '#d98248' })
  -- Other all-caps macros / preprocessor constants -- purple. The hue alone
  -- carries the category (no bold), since these are dense in API-heavy code.
  hi('DansMacro', { fg = '#bb9af7' })
  -- GLFW / SDL identifiers (GLFW*, SDL_*) -- a darker teal, so the brighter STB
  -- cyan below reads as a distinct, louder library.
  hi('DansSDL', { fg = '#1f93a8' })
  -- stb single-header libs (stb_*, stbi_*, stbtt_*, STB* macros) -- a teal-green,
  -- moved off the bright cyan so concepts can claim that (and distinct from SDL's
  -- darker blue-teal and the string green).
  hi('DansSTB', { fg = '#73daca' })
  -- BLAS / LAPACK family (cblas_*, CblasRowMajor, openblas_*, OPENBLAS_*,
  -- lapack_*, LAPACK_*, LAPACKE_*, blasint) -- a yellow-green, one color for the
  -- whole numeric-kernel group, clear of the string green and the cpy yellow.
  hi('DansBLAS', { fg = '#b8bb26' })
  -- concept / type-trait `~`-notation (~> ~= ~v ~& ~(...)) and the `concept` /
  -- `requires` keywords -- the bright cyan stb used to have. Common in this code,
  -- so it gets the loud color.
  hi('DansConcept', { fg = '#6ad7ff' })
  -- LLDB identifiers (LLDB_*, SB* API classes, the bare StateType enum) -- orange,
  -- clear of the purples/teal/greens so an LLDB-heavy file reads distinctly.
  hi('DansLLDB', { fg = '#ff9e64' })
  -- Dear ImGui (IM_*, Im*, ImGui*) -- a bordeaux / wine purple, distinct from the
  -- macro lavender and the mut red, so an ImGui-heavy UI file reads as its own lib.
  hi('DansImGui', { fg = '#c25a86' })
  -- String literals -- muted green. A calm color (strings are inert content);
  -- applied at high priority so no other coloring/conceal leaks inside them.
  hi('DansString', { fg = '#a3be8c' })
  -- runtime `assert(...)` -- grayed as auxiliary checks, not core logic
  -- (compile-time `static_assert` is spared; it reads as `$sa`).
  hi('DansAssert', { fg = '#6b7280' })
  -- Designated-init field-name hints (`.width = 800` -> `width=800`): a muted
  -- tier. Library-aware tinting (SDL / Vulkan / dearImgui) is a later refinement.
  hi('DansHint', { fg = '#8b8fa3' })
  -- Deduced-type inlay text inside the view overlays (clangd auto types) --
  -- clearly blue so it reads apart from the gray comments.
  hi('DansInlayType', { fg = '#7aa2f7' })
  -- Style-lab candidates for the semantic `?` / `∅` optional family. These
  -- stay distinct groups so buffer-local profiles can compare them in one
  -- process without mutating global renderer functions.
  hi('DansOptionalCyan', { fg = '#7dcfff', bold = true })
  hi('DansOptionalGold', { fg = '#e0af68', bold = true })
  hi('DansOptionalViolet', { fg = '#bb9af7', bold = true })
  -- `const` grayed wherever it stays visible (function args, trailing const, the
  -- leading const revealed on the cursor line) -- the de-emphasized default.
  hi('DansConst', { fg = '#6b7280' })
  -- Namespace/scope qualifiers (std::, dans::, Foo::) grayed as visual noise.
  hi('DansNamespace', { fg = '#6b7280' })
  -- Masks that re-neutralize text the syntax-blind matches would wrongly color:
  -- comments back to Comment, #include <...> paths back to Normal.
  hi('DansCommentMask', { link = 'Comment' })
  hi('DansIncludeMask', { link = 'Normal' })
  -- Dead preprocessor branch (a `#if` inactive on this platform): dimmer than the
  -- gray above so a whole inactive block recedes as one block of dead code.
  hi('DansInactive', { fg = '#4a5160' })
  -- Closed contract-block fold line -- gray on the normal background (drops
  -- tokyonight's banded Folded bg; the `+-- N lines:` foldtext reads as quiet).
  hi('Folded', { fg = '#6b7280' })
  -- Special-member collapse ($copy / $move / $constr / ...): a keyword-ish color
  -- so the generic name reads as structure, not a comment or a regular ident.
  hi('DansSpecialMember', { link = 'Special' })
end

return M
