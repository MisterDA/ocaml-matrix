open Server_utility
open Data
open Store
open Middleware
open Matrix_common
open Matrix_ctos

(** Notes:
  - In need of adding the support of the get route in order to advertise
  which authentication mechanism is supported: at the moment, only password v2
  with user name identifiers
  - Also, check out the difference between user_id and username
  - Timing attacks should also be taken into consideration
*)
let login request =
  let open Login.Post in
  let%lwt body = Dream.body request in
  let login =
    Json_encoding.destruct Request.encoding (Ezjsonm.value_from_string body)
  in
  (* Verify that the login mechanism is password v2*)
  match Request.get_auth login with
  | Password (V2 auth) -> (
    (* Verify that the identifier mechanism is username*)
    match Authentication.Password.V2.get_identifier auth with
    | User user -> (
      (* check the user data *)
      let username = Identifier.User.get_user user in
      let%lwt s_user = Store.find store (Store.Key.v ["users"; username]) in
      match s_user with
      | None -> Dream.json ~status:`Unauthorized {|{"errcode": "M_FORBIDDEN"}|}
      | Some s_user ->
        let s_user =
          Json_encoding.destruct User.encoding
            (Ezjsonm.value_from_string s_user) in
        (* Verify the username/password combination *)
        let password = Authentication.Password.V2.get_password auth in
        if password <> User.get_password s_user then
          Dream.json ~status:`Unauthorized {|{"errcode": "M_FORBIDDEN"}|}
        else
          let device =
            match Request.get_device_id login with
            | None -> Uuidm.(v `V4 |> to_string)
            | Some device -> Fmt.str "%s:%s" device username in
          let token = Uuidm.(v `V4 |> to_string) in
          let s_token =
            Token.make ~device ~expires_at:0. ()
            |> Json_encoding.construct Token.encoding
            |> Ezjsonm.value_to_string in
          let%lwt _ =
            Store.set ~info:Irmin.Info.none store
              (Store.Key.v ["tokens"; token])
              s_token in
          let s_device =
            Device.make ~user:username ~token ()
            |> Json_encoding.construct Device.encoding
            |> Ezjsonm.value_to_string in
          let%lwt _ =
            Store.set ~info:Irmin.Info.none store
              (Store.Key.v ["devices"; device])
              s_device in
          let s_user =
            User.set_devices s_user
              (List.sort_uniq String.compare
                 (device :: User.get_devices s_user)) in
          let s_user =
            Json_encoding.construct User.encoding s_user
            |> Ezjsonm.value_to_string in
          let%lwt _ =
            Store.set ~info:Irmin.Info.none store
              (Store.Key.v ["users"; username])
              s_user in
          (* There is an obvious problem with replacing existing devices, thus
             loosing all related informations *)
          let response =
            Response.make ~access_token:token ~device_id:device ()
            |> Json_encoding.construct Response.encoding
            |> Ezjsonm.value_to_string in
          Dream.json response)
    | _ ->
      Dream.json ~status:`Unauthorized
        {|{"errcode": "M_UNKNOWN", "error": "Bad identifier type"}|})
  | _ ->
    Dream.json ~status:`Unauthorized
      {|{"errcode": "M_UNKNOWN", "error": "Bad login type"}|}

(** Notes:
    - Error handling again
  *)
let logout request =
  let open Logout.Logout in
  let%lwt () =
    match
      Dream.local logged_user request, Dream.local logged_device request
    with
    | Some user, Some device -> (
      (* fetch the user *)
      let%lwt _ =
        let%lwt s_user = Store.find store (Store.Key.v ["users"; user]) in
        match s_user with
        | None -> Lwt.return_unit
        | Some s_user ->
          let s_user =
            Json_encoding.destruct User.encoding
              (Ezjsonm.value_from_string s_user) in
          (* remove the device from the user info *)
          let s_user =
            User.set_devices s_user
              (List.filter (fun s -> s = device) (User.get_devices s_user))
          in
          let s_user =
            Json_encoding.construct User.encoding s_user
            |> Ezjsonm.value_to_string in
          let%lwt _ =
            Store.set ~info:Irmin.Info.none store
              (Store.Key.v ["users"; user])
              s_user in
          Lwt.return_unit in
      (* fetch the device *)
      let%lwt s_device = Store.find store (Store.Key.v ["devices"; device]) in
      match s_device with
      | None -> Lwt.return_unit
      | Some s_device ->
        let s_device =
          Json_encoding.destruct Device.encoding
            (Ezjsonm.value_from_string s_device) in
        (* delete the device's token *)
        let token = Device.get_token s_device in
        let%lwt _ =
          Store.remove ~info:Irmin.Info.none store
            (Store.Key.v ["tokens"; token]) in
        (* delete the device *)
        let%lwt _ =
          Store.remove ~info:Irmin.Info.none store
            (Store.Key.v ["devices"; device]) in
        Lwt.return_unit)
    | _ -> Lwt.return_unit in
  let response =
    Response.make ()
    |> Json_encoding.construct Response.encoding
    |> Ezjsonm.value_to_string in
  Dream.json response

(** Notes:
    - Use the federation api ? We dont really want to do that however, as we
      want a minimalist server.
  *)
let resolve_alias request =
  let open Room.Resolve_alias in
  let alias = Dream.param "alias" request in
  let room_alias, _ = Identifiers.Room_alias.of_string_exn alias in
  let%lwt s_alias = Store.find store (Store.Key.v ["aliases"; room_alias]) in
  match s_alias with
  | None ->
    Dream.json ~status:`Unauthorized
      (Fmt.str
         {|{"errcode": "M_NOT_FOUND", "error": "Room alias %s not found."}|}
         room_alias)
  | Some s_alias ->
    let s_alias =
      Json_encoding.destruct Alias.encoding (Ezjsonm.value_from_string s_alias)
    in
    let room_id = Alias.get_room_id s_alias in
    let response =
      Response.make ~room_id ()
      |> Json_encoding.construct Response.encoding
      |> Ezjsonm.value_to_string in
    Dream.json response

(** Notes:
    - Properly use the ID
  *)
let send request =
  let open Room_event.Put.Message_event in
  let%lwt body = Dream.body request in
  let message =
    Json_encoding.destruct Request.encoding (Ezjsonm.value_from_string body)
  in
  match Dream.local logged_user request with
  | Some user ->
    let room_id = Dream.param "room_id" request in
    let%lwt b = Helper.is_room_user room_id user in
    if b then
      let id = "$" ^ Uuidm.(v `V4 |> to_string) in
      let message_content = Request.get_event message in
      let event =
        Events.Room_event.make
          ~event:
            (Events.Event.make
               ~event_content:(Events.Event_content.Message message_content) ())
          ~event_id:id ~sender:user
          ~origin_server_ts:((Unix.time () |> Float.to_int) * 1000)
          () in
      let json_event =
        Json_encoding.construct Events.Room_event.encoding event
        |> Ezjsonm.value_to_string in
      let%lwt _ =
        Store.set ~info:Irmin.Info.none store
          (Store.Key.v ["rooms"; room_id; "messages"; id])
          json_event in
      let%lwt prev_head =
        Store.find store (Store.Key.v ["rooms"; room_id; "messages_id"; "head"])
      in
      match prev_head with
      | None ->
        let error =
          Errors.Error.make ~errcode:"M_UNKNOWN"
            ~error:"Internal storage failure" ()
          |> Json_encoding.construct Errors.Error.encoding
          |> Ezjsonm.value_to_string in
        Dream.json ~status:`Internal_Server_Error error
      | Some prev_head ->
        let%lwt _ =
          Store.set ~info:Irmin.Info.none store
            (Store.Key.v ["rooms"; room_id; "messages_id"; id])
            prev_head in
        let%lwt _ =
          Store.set ~info:Irmin.Info.none store
            (Store.Key.v ["rooms"; room_id; "messages_id"; "head"])
            id in
        let response =
          Response.make ~event_id:id ()
          |> Json_encoding.construct Response.encoding
          |> Ezjsonm.value_to_string in
        Dream.json response
    else Dream.json ~status:`Unauthorized {|{"errcode": "M_FORBIDDEN"}|}
  | None -> assert false
(* Should obviously return a 401 instead: If this case
   was to happen, it would mean that the user of the matrix library has
   forgotten to use the authentication middleware. But we might prefer having
   a clean error than a simple raise. Or maybe a 5XX would be more appropriate *)

let router =
  Dream.router
    [
      Dream.scope "/_matrix" []
        [
          Dream.scope "/client" []
            [
              Dream.scope "/r0" []
                [
                  Dream.scope "" [Rate_limit.rate_limited]
                    [Dream.post "/login" login];
                  Dream.get "/directory/room/:alias" resolve_alias;
                  Dream.scope "" [is_logged]
                    [
                      Dream.put "/rooms/:room_id/send/:event_type/:txn_id" send;
                      Dream.post "/logout" logout;
                    ];
                ];
            ];
        ];
    ]
