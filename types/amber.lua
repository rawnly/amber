---@meta

---@class AmberPluginSpec
---@field [1] string GitHub owner/repository identity.
---@field subdir? string Repository subdirectory the plugin loads from; requires main.
---@field opts? table Options passed to the plugin's setup function.
---@field enabled? boolean Defaults to true.
---@field path? string Absolute path to an externally managed checkout.
---@field main? string Lua module name; defaults to the repository name.
---@field version? string Git ref or supported semver constraint.
---@field build? string|(string|fun(ctx: AmberBuildContext): any)[]|fun(ctx: AmberBuildContext): any|false Command, function, or list run after install or update; see the README.

---@class AmberPluginContext Second argument of a plugin's setup function.
---@field name string Plugin identity, `owner/repo` or `owner/repo@subdir`.
---@field dir string Checkout directory.
---@field module_dir string Directory the module tree resolves from; differs from dir for subdir plugins.
---@field commit? string Commit recorded in the lockfile, if any.
---@field data_dir? string Per-plugin state directory under `$XDG_STATE_HOME/rex/amber`; Amber does not create it.

---@class AmberBuildContext
---@field name string
---@field dir string
---@field module_dir string
---@field commit string Checked-out commit being built.
---@field exec fun(argv: string[], opts?: RexExecOptions): RexExecResult?, string? Runs a command in module_dir within the remaining action budget.

---@class AmberConfig
---@field root? string Absolute directory for managed checkouts.
---@field install? "manual" Installation is always manual.
---@field lockfile? string Absolute lockfile path; defaults to amber-lock.json in the Rex config directory.
---@field plugins? (string|AmberPluginSpec)[] Plugins in load order.

---@class AmberPlugin
---@field name string
---@field slug string Relative install path: `owner/repo`, plus `--subdir` for subdir plugins.
---@field url string
---@field dir string
---@field subdir? string
---@field module_dir string Directory the plugin's Lua module tree resolves from.
---@field parent string
---@field opts table
---@field main string
---@field local_path boolean
---@field enabled boolean
---@field version? string
---@field build? (string|fun(ctx: AmberBuildContext): any)[]
---@field load_status? string
---@field load_error? string

---@class AmberModule
---@field version string
---@field setup fun(config?: AmberConfig)
