# Neovim configuration

Based on [Kickstart](https://github.com/nvim-lua/kickstart.nvim).

This personal Neovim configuration centers on a presentation-only frontend that
reads real C, C++, and CUDA as a compact Odin/Jai-like visual language while
compilers, clangd, formatters, git, debuggers, and every write see the original
bytes.

C# and Python deliberately take the opposite presentation path: their ordinary
source spelling remains visible, Tree-sitter syntax is fixed to monochrome, and
Roslyn/BasedPyright provide conventional language intelligence.

The current language is const-default and exception-forward: writable borrows are
`mut`, expensive copies are `cpy`, uninitialized members are `no_init`, pointers
use `^` in type positions, inferred and explicit declarations stay visibly
distinct, and common library noise may be hidden only when provenance survives in
color. Only folds may change vertical source-row identity.

Current CUDA/Qnpeps conventions include seafoam `cf32`/`cf64` for CUDA complex
types, hidden `qnpeps::` with orchid provenance retained, list-wide colon columns
for multiline function parameters, and semantic `defer` rendering for
lambda-backed `DEFER`/`DANS_DEFER` wrappers. The exact accepted rules live in
[DEC-005](knowledge/records/DEC-005.json),
[DEC-006](knowledge/records/DEC-006.json), and
[DEC-007](knowledge/records/DEC-007.json), with the Qnpeps prefix policy in
[DEC-008](knowledge/records/DEC-008.json).

## Start here

Authoritative project facts and decisions are typed records under `knowledge/`.
Read the generated [knowledge catalog](knowledge/CATALOG.md), the
[knowledge workflow](knowledge/README.md), or retrieve a task-specific context
package:

```sh
tools/knowledge query "why do selected rows show raw source?" --semantic
```

The behavioral authority is the isolated suite, including real cursor/Visual
transitions and an embedded-Neovim UI client:

```sh
python3 tools/run_tests.py
```

## Layout

- `init.lua` loads non-plugin configuration, lazy.nvim, and first-party modules.
- `lua/config/` contains options, keymaps, general autocmds, and plugin bootstrap.
- `lua/custom/plugins/` contains lazy.nvim plugin specifications.
- `lua/custom/dans_frontend_cpp/` contains parsing, rendering, lifecycle,
  highlighting, alignment, folding, and focused C/C++/CUDA transforms.
- `lua/custom/` contains the first-party C++ authoring engine, shared compiler
  context, assembly/probe/code-generation tools, doc markdown, diagnostics, macro
  discovery, profiling, navigation, protection, the DANS display controller and
  command palette, fixed-monochrome C#/Python language support, and Julia tools.
  `lua/custom/plugins/vimtex.lua` owns the LaTeX compiler/viewer integration.
- `tests/` contains deterministic Lua/Neovim and Python specs plus reviewed text
  goldens. Ordinary outputs are disposable.
- `style_lab/` and `tools/style_lab` provide real-render visual decision rounds.
- `knowledge/records/` is the canonical factbase; catalogs and caches are derived.

The detailed ownership map is [CMP-002](knowledge/records/CMP-002.json), with the
rest of the first-party system in [CMP-008](knowledge/records/CMP-008.json).

## DANS menu and display modes

`:Dans` is the owner-facing entry point for this configuration. The same palette
is available through `<leader>dan`; individual `:Dans...` commands remain useful
as stable automation APIs, but normal use does not require memorizing them. The
palette contains display mode and font controls, C++ templates and generation,
formatting, assembly and function probes, project/include inspection, and the
profiling, key-log, scope, macro-rescan, and development-marker utilities.
Font sizes from 8 through 32 points inclusive are accepted; values outside that
range are rejected without changing the current font.

Frontend presentation and monochrome highlighting are separate global choices.
While the frontend is on, monochrome is required and its menu row is locked. The
requested monochrome choice is still remembered: turning the frontend off shows
the exact C/C++/CUDA source spelling, then either keeps the source monochrome or
restores ordinary Tree-sitter colors according to that remembered choice. No
individual frontend-feature toggles are exposed in the palette.

The state contract and implementation ownership are recorded in
[DEC-012](knowledge/records/DEC-012.json),
[BHV-014](knowledge/records/BHV-014.json), and
[CMP-012](knowledge/records/CMP-012.json).

## C# and Python

`.cs`, `.py`, and `.pyi` buffers show their exact source with conceal disabled.
Their Tree-sitter parsers remain active for structural editing, but every syntax
capture is linked to `Normal`; comments and Python docstrings alone use the dim
comment style. LSP semantic tokens are disabled so a server cannot layer the
usual type/variable/function color palette back on top. This policy is fixed for
these languages and is independent of the C++ frontend/monochrome rows in
`:Dans`.

C# uses nvim-lspconfig's official `roslyn_ls` integration. It attaches inside a
`.sln`, `.slnx`, or `.csproj` workspace and supplies definitions, references,
implementations, completion, diagnostics, symbols, rename, code actions, and
optional inlay hints. Install a .NET SDK so `dotnet` is on `PATH`; Mason then
installs `roslyn-language-server` automatically on the next Neovim start. Until
then C# filetype, parsing, indentation, and monochrome presentation still work,
and an interactive C# buffer gives one clear prerequisite warning.

Python uses BasedPyright, installed through Mason. Its upstream project discovery
recognizes `pyproject.toml`, `pyrightconfig.json`, setup/requirements files,
Pipfiles, and Git roots; project-local configuration remains authoritative.
Default diagnostics are limited to open files.

The shared LSP controls include:

- `gd`: definition, or references when already on the only definition.
- `gr`, `gI`, `gD`: references, implementations, and declarations.
- `<leader>rn`, `<leader>ca`: rename and code actions.
- `<leader>ds`, `<leader>ws`: document and workspace symbols.
- `<leader>th`: toggle inlay hints when the server supports them.
- `<leader>tc`: toggle LSP-backed completion sources.

The contract and ownership are recorded in
[DEC-017](knowledge/records/DEC-017.json),
[BHV-016](knowledge/records/BHV-016.json), and
[CMP-014](knowledge/records/CMP-014.json).

## Markdown and LaTeX

Ordinary `.md`, `.markdown`, and `.mdx` buffers are literal source views. Code
fences, emphasis delimiters, link destinations, checkbox spelling, and other
markup remain visible; no Markdown renderer or save-time formatter rewrites or
conceals them. This policy applies to Markdown files, not the separate `///`
documentation presentation inside C++ headers.

LaTeX uses VimTeX for project structure, syntax, motions, table of contents,
continuous `latexmk` compilation, errors, cleanup, and PDF synchronization.
Texlab is installed through Mason for completion, navigation, symbols,
diagnostics, and explicit `latexindent` formatting. LaTeX commands and math
symbols also remain literal—syntax conceal is disabled—and saving alone neither
starts a build nor formats the document.

With `<localleader>` set to Space, the main discoverable controls are:

- `<Space>ll`: start/stop continuous compilation.
- `<Space>lv`: open the PDF or forward-search the current source position.
- `<Space>lk`: stop the compiler.
- `<Space>le`: show compilation errors.
- `<Space>lt`: open the document table of contents.
- `<Space>lc`: clean auxiliary output.
- `<leader>f`: explicitly format through texlab/`latexindent`.

On this Fedora host the viewer is Okular with SyncTeX forward-search arguments;
Zathura, Skim, MuPDF, and the system viewer are selected as platform fallbacks.
The contracts are [DEC-013](knowledge/records/DEC-013.json),
[BHV-015](knowledge/records/BHV-015.json), and
[CMP-013](knowledge/records/CMP-013.json).

## C++ authoring and tools

The configuration no longer uses LuaSnip. `cpp_authoring.lua` owns the structured
template catalog, `$` type language, live suggestions, include insertion, and
Tab navigation; Neovim's built-in `vim.snippet` primitive tracks fields and
mirrors. `$class5`, `$rule5`, `$forx`, `$println`, and `$cuda` are representative
templates, while the compositional type language retains forms such as `$?$T`,
`$um$K$V`, and `$[4][5]f32`. Unknown input is preserved rather than deleted. See
[DEC-009](knowledge/records/DEC-009.json) and
[CMP-009](knowledge/records/CMP-009.json).

The C++ tools available from `:Dans` share one compile-database, Tree-sitter
context, cancellable job, and scratch-window layer. Their underlying command
names are retained here as automation/API references:

- `:DansAsm[!] [O0|O1|O2|O3|Os|Oz|Og]` opens function-scoped assembly with
  persistent source/assembly color pairing. In the result, `n` toggles compiler
  noise, `o` selects optimization, and `r` recompiles.
- `:DansRunFunction[!] [invocation expression]` compiles a temporary harness and
  shows stdout/stderr. `e` edits the invocation, `i` supplies stdin, `h` shows the
  generated harness, and `r` reruns it.
- `:DansCppGenerate` chooses enum/struct string conversion, the
  Validity/validity/is_valid pattern, current-function declaration projection,
  or a sibling header draft. Every artifact is previewed through the actual C++
  frontend; `a` applies to a modified buffer and `y` copies it. Nothing is
  silently written.
- `:DansCppProjectIndex` shows the deterministic physical file/component,
  direct-include, compilation-profile, and CMake-target index for the current
  project. `:DansCppProjectWhy` explains the include under the cursor, including
  its resolved provider, search-root provenance, conditions, and inferred
  component edge; `:DansCppProjectJson` exposes the complete machine view.

The same project evidence is available without Neovim:

```sh
tools/cpp_project_index --root /path/to/project --pretty
```

The index reports observed structure only. It does not silently turn directory
or build-target heuristics into an authoritative project-module design.

Assembly and probes require saved source. Function probes are intentionally
constrained—not a debugger or a claim that arbitrary project/global/GPU state is
isolatable. The detailed contracts are [CMP-010](knowledge/records/CMP-010.json),
[BHV-010](knowledge/records/BHV-010.json),
[BHV-011](knowledge/records/BHV-011.json), and
[BHV-012](knowledge/records/BHV-012.json).

## Frontend interaction contract

The cursor row and every row in a characterwise, linewise, or blockwise Visual
selection show source-faithful text. Leaving or changing a selection restores all
affected renderers immediately. Comments, `static_assert` declarations,
`clang-format off` regions, unsupported syntax, macro-recording sessions, and a
large buffer's deferred first paint also prefer raw text. See
[BHV-001](knowledge/records/BHV-001.json) and
[BHV-008](knowledge/records/BHV-008.json).

## Visual style lab

Launch the browser lab with:

```sh
tools/style_lab serve
```

For an agent-driven decision round, `tools/style_lab serve --wait` opens an
isolated browser app window, waits until every open question has a selection,
writes `style_lab/selections.json`, acknowledges the final POST, and closes only
that app window. Captures are produced from Neovim's actual `ext_linegrid`; the
browser does not reimplement frontend spelling or colors. Slightly overflowing
panels shrink only as far as 80%; genuinely long rows stay full size and scroll.

The lab and its pinned ImGui/LLVM/CUDA/GCC/SDL/GLFW/Vulkan corpus are documented
in [CMP-004](knowledge/records/CMP-004.json).

## Requirements

- Neovim 0.12-era APIs and the configured Tree-sitter parsers (including C# and
  Python; nvim-treesitter installs missing parsers automatically).
- Git and a C compiler for lazy.nvim/Tree-sitter installation.
- A local C/C++ compiler for assembly and function probes; project flags are read
  from `compile_commands.json` when available.
- A .NET SDK with `dotnet` on `PATH` for the Roslyn C# language server. Mason
  manages Roslyn itself after that prerequisite is present.
- Python 3; Mason manages BasedPyright in its isolated package environment.
- A TeX distribution with `latexmk` for compilation and `latexindent` for manual
  formatting. VimTeX can fall back to the system PDF opener; Okular is preferred
  on this host, and texlab is managed by Mason.
- Python 3 with `msgpack` for the real UI capture and style lab.
- Optional semantic retrieval environment from `python3 tools/bootstrap_knowledge.py`.
- Monaspace Krypton is preferred; the browser has a Noto/monospace fallback.
