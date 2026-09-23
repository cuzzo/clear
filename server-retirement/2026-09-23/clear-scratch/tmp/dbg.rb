require_relative 'ruby/mir/mir_lowering'
m = MIRLowering.instance_method(:ownership_operands_for_sink_value)
MIRLowering.class_eval do
  define_method(:ownership_operands_for_sink_value) do |value_mir, ast_value, ti, source, target_alloc, require_visible_owned:|
    r = m.bind(self).call(value_mir, ast_value, ti, source, target_alloc, require_visible_owned: require_visible_owned)
    if r.any? { |o| o.name.to_s == 'default' || o.name.to_s == 'd' }
      warn "SINK d: mir=#{value_mir.class} ast=#{ast_value.class} ti=#{ti.resolved rescue ti} tracked=#{ownership_tracked_transfer_type?(ti)} mat=#{materialized_owned_binding_visible?('d')} own=#{owned_binding_visible?('d')} => #{r.map { |o| [o.name, o.borrowed] }.inspect}"
    end
    r
  end
end
