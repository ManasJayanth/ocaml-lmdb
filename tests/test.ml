open Alcotest
open Lmdb

let filename =
  let rec tmp_filename base suffix n =
    let name = Printf.sprintf "%s.%u%s" base n suffix in
    if Sys.file_exists name;
    then tmp_filename base suffix (n+1)
    else name
  in
  tmp_filename "/tmp/lmdb_test" ".db" 0

let env =
  Env.create rw
    ~flags:Env.Flags.(no_subdir + no_sync + no_lock + no_mem_init)
    ~map_size:104857600
    ~max_dbs:10
    filename
let () =
  at_exit @@ fun () ->
  Env.close env;
  Sys.remove filename

let[@warning "-26-27"] capabilities () =
  let map =
    Db.(create ~dup:false
           ~key:Conv.int32_be_as_int
           ~value:Conv.int32_be_as_int
           ~name:"Capabilities" env)
  in
  let env_rw = (env :> [ `Read | `Write ] Env.t) in
  let env_ro = (env :> [ `Read ] Env.t) in
  (* let env_rw = (env_ro :> [ `Read | `Write ] Env.t) in <- FAILS *)
  (* ignore @@ (rw :> [ `Read ] Cap.t); <- FAILS *)
  (* ignore @@ (ro :> [ `Read | `Write ] cap); <- FAILS *)
  ignore @@ Txn.go rw env_rw ?txn:None @@ fun txn_rw ->
  let txn_ro = (txn_rw :> [ `Read ] Txn.t) in
  Db.put ~txn:txn_rw map 4 4;
  (* Db.put ~txn:txn_ro map 4 4; <- FAILS *)
  assert (Db.get ~txn:txn_rw map 4 = 4);
  assert (Db.get ~txn:txn_ro map 4 = 4);
  Cursor.go ro
    ~txn:(txn_rw :> [ `Read ] Txn.t)
    (map :> (_,_,[ `Read ]) Db.t) @@ fun cursor ->
  assert (Cursor.get cursor 4 = 4);
  (* Cursor.first_dup cursor; <- FAILS *)
;;


let test_map =
  "Db",
  let open Db in
  let map =
    Db.(create ~dup:false
           ~key:Conv.int32_be_as_int
           ~value:Conv.int32_be_as_int
           ~name:"Db" env)
  in
    [ "append(_dup)", `Quick, begin fun () ->
      Db.drop map;
      let rec loop n =
        if n <= 536870912 then begin
          let rec loop_dup m =
            if m <= 536870912 then begin
              put map ~flags:Flags.append_dup n m;
              loop_dup (m * 2);
            end
          in loop_dup n;
          loop (n * 2);
        end
      in loop 12;
    end
  ; "put", `Quick,
    ( fun () -> put map 4285 42 )
  ; "put overwrite", `Quick,
    ( fun () -> put map 4285 2 )
  ; "put no_overwrite", `Quick, begin fun () ->
      check_raises "Exists" Exists  @@ fun () ->
      put map ~flags:Flags.no_overwrite 4285 0
    end
  ; "put no_dup_data", `Quick, begin fun () ->
      ignore @@ Txn.go rw env @@ fun txn ->
      let map =
        Db.(create ~dup:true ~txn
               ~key:Conv.int32_be_as_int
               ~value:Conv.int32_be_as_int
               ~name:"Db.dup" env)
      in
      put ~txn map ~flags:Flags.no_dup_data 4285 0;
      check_raises "Exists" Exists
        (fun () -> put ~txn map ~flags:Flags.no_dup_data 4285 0);
      Txn.abort txn
    end
  ; "get", `Quick,
    ( fun () -> check int "blub" 2 (get map 4285) )
  ; "remove", `Quick,
    ( fun () -> remove map 4285 )
  ; "Not_found", `Quick, begin fun () ->
      check_raises "Not_found" Not_found (fun () -> get map 4285 |> ignore)
    end
  ; "stress", `Slow, begin fun () ->
      let buf = String.make 1024 'X' in
      let n = 10000 in
      let map =
        create ~dup:false
          ~key:Conv.int32_be_as_int
          ~value:Conv.string
          ~name:"map2" env
      in
      for _i=1 to 100 do
        for i=0 to n do
          put map i buf;
        done;
        for i=0 to n do
          let v =
            try
            get map i
            with Not_found ->
              failwith ("got Not_found for " ^ string_of_int i)
          in
          if (v <> buf)
          then fail "memory corrupted ?"
        done;
        drop ~delete:false map
      done;
    end
  ]

let test_cursor =
  "Cursor",
  let open Cursor in
  let map =
    Db.(create ~dup:true
           ~key:Conv.int32_be_as_int
           ~value:Conv.int32_be_as_int
           ~name:"Cursor" env)
  in
  let check_kv = check (pair int int) in
  [ "wrong map", `Quick,
    begin fun () ->
      let env2 =
        Env.create rw
          ~flags:Env.Flags.(no_subdir + no_sync + no_lock + no_mem_init)
          ~map_size:104857600
          ~max_dbs:10
          (filename ^ "2")
      in
      check_raises "wrong txn" (Invalid_argument "Lmdb") begin fun () ->
        ignore @@ Txn.go ro (env2 :> [ `Read ] Env.t)
          (fun txn -> Db.get ~txn map 0 |> ignore);
      end;
    end
  ; "append(_dup)", `Quick,
    begin fun () ->
      Db.drop map;
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      let rec loop n =
        if n <= 536870912 then begin
          let rec loop_dup m =
            if m <= 536870912 then begin
              put cursor ~flags:Flags.append_dup n m;
              loop_dup (m * 2);
            end
          in loop_dup n;
          loop (n * 2);
        end
      in loop 12;
    end
  ; "first", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      first cursor |> check_kv "first 12" (12, 12)
    end
  ; "put first", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      for i=0 to 9 do put cursor i i done
    end
  ; "walk", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      first cursor              |> check_kv "first" (0,0);
      check_raises "walk before first" Not_found
        (fun () -> prev cursor |> ignore);
      seek cursor 5             |> check_kv  "seek 5"    (5,5);
      prev cursor               |> check_kv  "prev"      (4,4);
      current cursor            |> check_kv  "current"   (4,4);
      remove cursor;
      current cursor            |> check_kv  "shift after remove" (5,5);
      replace cursor 4; (* delete (5,5), add (5,4) *)
      current cursor            |> check_kv  "shift after replace" (5,4);
      check_raises "deleted by replace" Not_found
        (fun () -> seek_dup cursor 5 5);
      seek_dup cursor 5 4;
      current cursor            |> check_kv  "replace added" (5,4);
      last cursor |> ignore;
      check_raises "walking beyond last key" Not_found
        (fun () -> next cursor |> ignore);
    end
  ; "walk dup", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      for i=0 to 9 do put cursor 10 i done;
      next cursor               |> check_kv  "next"      (12,12);
      prev cursor               |> check_kv  "prev"      (10,9);
      first_dup cursor          |> check int "first_dup" 0;
      next_dup cursor           |> check int "next_dup"  1;
      seek_dup cursor 10 5;
        current cursor          |> check_kv  "seek 5"    (10,5);
      prev cursor               |> check_kv  "prev"      (10,4);
      current cursor            |> check_kv  "current"   (10,4);
      remove cursor;
      current cursor            |> check_kv  "cursor moved forward after remove" (10,5);
      first_dup cursor          |> check int "first"     0;
      check_raises "fail when walking before first dup" Not_found
        (fun () -> prev_dup cursor |> ignore);
      last_dup cursor           |> check int "last"      9;
      check_raises "fail when walking beyond last dup" Not_found
        (fun () -> next_dup cursor |> ignore);
      seek_dup cursor 10 7;
      current cursor            |> check_kv  "seek_dup"  (10,7);
    end
  ; "put", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor 4285 42
    end
  ; "put no_overwrite", `Quick, begin fun () ->
      check_raises "failure when adding existing key" Exists @@ fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor ~flags:Flags.no_overwrite 4285 0
    end
  ; "put dup", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor 4285 42
    end
  ; "put dup no_dup_data", `Quick, begin fun () ->
      check_raises "failure when adding existing key-value" Exists @@ fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor ~flags:Flags.no_dup_data 4285 42
    end
  ; "get", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      check int "retrieve correct value for key" 42 (get cursor 4285)
    end
  ; "Not_found", `Quick, begin fun () ->
      check_raises "failure on non-existing key" Not_found @@ fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      get cursor 4287 |> ignore
    end
  ; "first gets first dup", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor ~flags:Flags.(none)       0 0;
      put cursor ~flags:Flags.(append_dup) 0 1;
      put cursor ~flags:Flags.(append_dup) 0 2;
      last cursor |> ignore;
      first cursor |> check_kv "first dup" (0,0)
    end
  ; "last gets last dup", `Quick, begin fun () ->
      ignore @@ go rw map ?txn:None @@ fun cursor ->
      put cursor ~flags:Flags.(append + append_dup) 536870913 5;
      put cursor ~flags:Flags.(append_dup) 536870913 6;
      put cursor ~flags:Flags.(append_dup) 536870913 7;
      first cursor |> ignore;
      last cursor |> check_kv "last dup" (536870913,7)
    end
  ]

let test_int =
  let open Db in
  let make_test name conv =
    name, `Quick,
    begin fun () ->
      let map =
        (create ~dup:true
           ~key:conv
           ~value:conv
           ~name env)
      in
      let rec loop n =
        if n < 1073741823 then begin
          (try put ~flags:Flags.append     map n n
           with Exists -> fail "Ordering on keys");
          (try put ~flags:Flags.append_dup map 1 n
           with Exists -> fail "Ordering on values");
          loop (n / 3 * 4);
        end
      in loop 12;
      drop ~delete:true map;
    end
  in
  "Int",
  [ make_test "int32_be" Conv.int32_be_as_int
  ; make_test "int32_le" Conv.int32_le_as_int
  ; make_test "int64_be" Conv.int64_be_as_int
  ; make_test "int64_le" Conv.int64_le_as_int
  ]

let () =
  run "Lmdb"
    [ "capabilities", [ "capabilities", `Quick, capabilities ]
    ; test_map
    ; test_cursor
    ; test_int
    ]
