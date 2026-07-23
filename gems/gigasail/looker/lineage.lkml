explore: logical_units {
  join: events {
    relationship: one_to_many
    sql_on: ${logical_units.id} = ${events.unit_id} ;;
  }
  join: test_exposure_events {
    relationship: one_to_many
    sql_on: ${logical_units.id} = ${test_exposure_events.unit_id} ;;
  }
}
