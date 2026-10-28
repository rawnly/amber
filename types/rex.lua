---@meta

---@class RexExecOptions
---@field cwd? string
---@field env? table<string, string|boolean>
---@field timeout? number

---@class RexExecResult
---@field ok boolean
---@field code integer
---@field stdout string
---@field stderr string
---@field signal? string
---@field timed_out? boolean

---@class RexActionArgs
---@field plugin string

---@class RexAction
---@field name string
---@field title string
---@field category? string
---@field args? table<string, string>
---@field run fun(ctx: table, args: RexActionArgs): table

---@class RexApi
---@field exec fun(argv: string[], opts?: RexExecOptions): RexExecResult?, string?
---@field action fun(action: RexAction)
---@field log fun(level: string, message: string)

---@type RexApi
rex = {}
