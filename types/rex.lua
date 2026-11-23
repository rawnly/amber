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
---@field plugin? string

---@class RexAction
---@field name string
---@field title string
---@field category? string
---@field args? table<string, string>
---@field run fun(ctx: table, args: RexActionArgs): table

---@class RexJson
---@field encode fun(value: any, opts?: table): string?, string?
---@field decode fun(text: string): any, string?

---@class RexLayer
---@field layer_id string?
---@field block_ids string[]?

---@class RexSession
---@field new_layer fun(args: table): RexLayer

---@class RexLayout
---@field block fun(args: table): table

---@class RexActionContext
---@field session_id? string
---@field block_id? string
---@field client_id? string
---@field origin? string
---@field server? table

---@class RexApi
---@field exec fun(argv: string[], opts?: RexExecOptions): RexExecResult?, string?
---@field action fun(action: RexAction)
---@field log fun(level: string, message: string)
---@field json RexJson
---@field session RexSession
---@field layout RexLayout

---@type RexApi
---@diagnostic disable-next-line: missing-fields
rex = {}
