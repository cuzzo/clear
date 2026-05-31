/**
 * CLEAR state-field pressure.
 *
 * This intentionally starts with syntactic reads/writes and method calls.
 * The Ruby CodeQL libraries provide the AST/call/control/dataflow substrate;
 * this query gives nil-kill/decomplex something concrete to join against.
 */

import codeql.ruby.AST

predicate discoveredField(string field) {
  exists(SetterMethodCall call |
    call.getTargetName() = field and
    field != "" and
    field != "[]" and
    call.getFile().getRelativePath().matches("src/%")
  )
  or
  exists(InstanceVariableWriteAccess ivar |
    ivar.getVariable().getName() = "@" + field and
    field != "" and
    ivar.getFile().getRelativePath().matches("src/%")
  )
}

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

from AstNode access, string field, string accessKind, string file, string moduleName, string methodName,
  int startLine, int startColumn, int endLine, int endColumn
where
  (
    exists(InstanceVariableAccess iv |
      access = iv and
      discoveredField(field) and
      iv.getVariable().getName() = "@" + field and
      (
        iv instanceof InstanceVariableWriteAccess and accessKind = "ivar_write"
        or
        iv instanceof InstanceVariableReadAccess and accessKind = "ivar_read"
      )
    )
    or
    exists(SetterMethodCall call |
      access = call and
      call.getTargetName() = field and
      discoveredField(field) and
      accessKind = "setter_call"
    )
    or
    exists(MethodCall call |
      access = call and
      call.getMethodName() = field and
      call.getNumberOfArguments() = 0 and
      exists(call.getReceiver()) and
      discoveredField(field) and
      accessKind = "reader_call"
    )
  ) and
  file = access.getFile().getRelativePath() and
  moduleName = moduleLabel(access) and
  methodName = methodLabel(access) and
  access.getLocation().hasLocationInfo(_, startLine, startColumn, endLine, endColumn)
select access, file, moduleName, methodName, field, accessKind, startLine, startColumn, endLine, endColumn, access.toString()
