---@meta

---@class AmberPluginSpec
---@field [1] string GitHub owner/repository identity.
---@field opts? table Options passed to the plugin's setup function.
---@field enabled? boolean Defaults to true.
---@field path? string Absolute path to an externally managed checkout.
---@field main? string Lua module name; defaults to the repository name.
---@field version? string Git ref or supported semver constraint.

---@class AmberConfig
---@field root? string Absolute directory for managed checkouts.
---@field install? "manual" Installation is always manual.
---@field lockfile? string Absolute lockfile path; defaults to amber-lock.json in the Rex config directory.
---@field plugins? (string|AmberPluginSpec)[] Plugins in load order.

---@class AmberPlugin
---@field name string
---@field url string
---@field dir string
---@field parent string
---@field opts table
---@field main string
---@field local_path boolean
---@field enabled boolean
---@field version? string
---@field load_status? string
---@field load_error? string

---@class AmberModule
---@field version string
---@field setup fun(config?: AmberConfig)
