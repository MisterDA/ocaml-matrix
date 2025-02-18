open Cmdliner
module Store = Irmin_unix.Git.FS.KV (Irmin.Contents.String)

let setup =
  let setup level =
    let style_renderer = `Ansi_tty in
    Fmt_tty.setup_std_outputs ~style_renderer ();
    Logs.set_level level;
    Logs.set_reporter (Logs_fmt.reporter ()) in
  let open Term in
  const setup $ Logs_cli.level ()

let root_cmd =
  let open Term in
  let info = info "server_utility" in
  let term = ret (const (fun () -> `Help (`Pager, None)) $ setup) in
  term, info

module User = struct
  let f store user_id password () =
    let config = Irmin_git.config store in
    let%lwt repo = Store.Repo.v config in
    let%lwt store = Store.master repo in
    (* Verify if the user already exists *)
    let%lwt s_user = Store.find_tree store (Store.Key.v ["users"; user_id]) in
    match s_user with
    | Some _ ->
      Logs.err (fun m -> m "user id %s already exists" user_id);
      Lwt.return 1
    | None -> (
      Mirage_crypto_rng_lwt.initialize ();
      let salt = Cstruct.to_string @@ Mirage_crypto_rng.generate 32 in
      let digest = Digestif.BLAKE2B.hmac_string ~key:salt password in
      let hashed = Digestif.BLAKE2B.to_hex digest in
      let%lwt tree = Store.tree store in
      let%lwt tree =
        Store.Tree.add tree (Store.Key.v ["users"; user_id; "username"]) user_id
      in
      let%lwt tree =
        Store.Tree.add tree (Store.Key.v ["users"; user_id; "salt"]) salt in
      let%lwt tree =
        Store.Tree.add tree (Store.Key.v ["users"; user_id; "password"]) hashed
      in
      let%lwt return =
        Store.set_tree
          ~info:(fun () ->
            Irmin.Info.v
              ~date:(Int64.of_float @@ Unix.gettimeofday ())
              ~author:"matrix-ci-server-setup" "add user")
          store (Store.Key.v []) tree in
      match return with
      | Ok () -> Lwt.return 0
      | Error write_error ->
        Logs.err (fun m ->
            m "Write error: %a" (Irmin.Type.pp Store.write_error_t) write_error);
        Lwt.return 1)

  let store =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"store" ~doc:"path to the store")

  let user_id =
    Arg.(
      required
      & pos 1 (some string) None
      & info [] ~docv:"user" ~doc:"user id to create")

  let pwd =
    Arg.(
      required
      & pos 2 (some string) None
      & info [] ~docv:"password" ~doc:"user password")

  let cmd =
    let info =
      let doc = "Creates a user." in
      Term.info "user" ~doc in
    let term =
      Term.(app (const Lwt_main.run) (const f $ store $ user_id $ pwd $ setup))
    in
    term, info
end

let () =
  let open Term in
  exit_status @@ eval_choice root_cmd [User.cmd]
