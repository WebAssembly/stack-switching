open Types

type event
type t = event

val alloc : event_type -> event
val type_of : event -> event_type
