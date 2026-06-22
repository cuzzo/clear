Worker = {}
function Worker:run(items) self.prepare(); if self.ready() then self.validate() end for item in items do self.helper(item) end end
function Worker:prepare() end
function Worker:ready() return true end
function Worker:validate() end
function Worker:helper(item) return item end
