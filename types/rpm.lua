---@meta

---@class RpmPluginSpec
---@field [1] string GitHub owner/repository identity.
---@field opts? table Options passed to the plugin's setup function.
---@field enabled? boolean Defaults to true.
---@field path? string Absolute path to an externally managed checkout.
---@field main? string Lua module name; defaults to the repository name.
---@field version? string Git ref or supported semver constraint.

---@class RpmConfig
---@field root? string Absolute directory for managed checkouts.
---@field install? "auto"|"manual" Installation behavior; defaults to auto.
---@field plugins? (string|RpmPluginSpec)[] Plugins in load order.

---@class RpmPlugin
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

---@class RpmModule
---@field version string
---@field setup fun(config?: RpmConfig)
