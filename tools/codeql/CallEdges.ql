/**
 * Ruby call edges CodeQL can resolve.
 *
 * Dynamic Ruby means this will be incomplete, but it is still useful as a
 * structural overlay for nil-kill/decomplex pressure.
 */

import codeql.ruby.AST

string methodLabel(AstNode n) {
  exists(Method m |
    m = n.getEnclosingMethod() and
    result = m.getName()
  )
  or
  not exists(n.getEnclosingMethod()) and result = "(top-level)"
}

string moduleLabel(AstNode n) {
  exists(Namespace ns |
    ns = n.getEnclosingModule() and
    result = ns.getName()
  )
  or
  not exists(n.getEnclosingModule()) and result = "(top-level)"
}

from MethodCall call, Callable target, string file, string callerModule, string caller, string callee
where
  target = call.getATarget() and
  file = call.getFile().getRelativePath() and
  callerModule = moduleLabel(call) and
  caller = methodLabel(call) and
  (
    exists(Method m | target = m and callee = m.getName())
    or
    not target instanceof Method and callee = call.getMethodName()
  )
select call, file, callerModule, caller, call.getMethodName(), callee, call.toString()
