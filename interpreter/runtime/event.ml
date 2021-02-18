open Types

type event = {ty : event_type}
type t = event

let alloc ty =
  {ty}

let type_of evt =
  evt.ty
