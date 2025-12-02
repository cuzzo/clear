module OpCodes
  # Parameter Types
  T_REG_W = :reg_w  # Register Write (Target) - e.g. "R0"
  T_CONST = :const  # Constant Index          - e.g. "K0"

  DEFINITIONS = {
    # OPCODE      # PARAMS
    LOADK:        [T_REG_W, T_CONST],
  }
end
