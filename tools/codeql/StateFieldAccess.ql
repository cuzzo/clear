/**
 * CLEAR state-field pressure.
 *
 * This intentionally starts with syntactic reads/writes and method calls.
 * The Ruby CodeQL libraries provide the AST/call/control/dataflow substrate;
 * this query gives nil-kill/decomplex something concrete to join against.
 */

import codeql.ruby.AST

predicate trackedField(string field) {
  field = "full_type" or
  field = "storage" or
  field = "provenance" or
  field = "ownership" or
  field = "sync" or
  field = "layout" or
  field = "emit" or
  field = "target" or
  field = "value" or
  field = "symbol" or
  field = "name" or
  field = "type" or
  field = "left" or
  field = "right" or
  field = "expr" or
  field = "result_type"
}

predicate trackedSetter(string methodName, string field) {
  trackedField(field) and methodName = field + "="
}

predicate trackedReader(string methodName, string field) {
  trackedField(field) and methodName = field
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

from AstNode access, string field, string accessKind, string file, string moduleName, string methodName
where
  (
    exists(InstanceVariableAccess iv |
      access = iv and
      trackedField(field) and
      iv.getVariable().getName() = "@" + field and
      (
        iv instanceof InstanceVariableWriteAccess and accessKind = "ivar_write"
        or
        iv instanceof InstanceVariableReadAccess and accessKind = "ivar_read"
      )
    )
    or
    exists(MethodCall call |
      access = call and
      (
        trackedSetter(call.getMethodName(), field) and accessKind = "setter_call"
        or
        trackedReader(call.getMethodName(), field) and accessKind = "reader_call"
      )
    )
  ) and
  file = access.getFile().getRelativePath() and
  moduleName = moduleLabel(access) and
  methodName = methodLabel(access)
select access, file, moduleName, methodName, field, accessKind, access.toString()
