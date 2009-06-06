open Printf

module D=Debug.Debugger(struct let name="dbsync" end)
open D

(* Update the database to reflect current state. Called for both start of day and after
   an agent restart. *)

let resync_dom0_config_files() =         
  try
    debug "resyncing dom0 config files if necessary";
    Config_file_sync.fetch_config_files_on_slave_startup ()
  with e -> warn "Did not sync dom0 config files: %s" (Printexc.to_string e)

let resync_loadavg_limit other_config = 
  try
    if List.mem_assoc Xapi_globs.loadavg_limit_key other_config
    then Xapi_globs.loadavg_limit := float_of_string (List.assoc Xapi_globs.loadavg_limit_key other_config)
  with e ->
    warn "Skipping exception resynchronising the loadavg_limit: %s" (ExnHelper.string_of_exn e)

let update_env () =
  Server_helpers.exec_with_new_task "dbsync (update_env)"
    (fun __context ->
      let other_config = 
	try
	  match Db.Pool.get_all ~__context with
	  | [ pool ] ->
	    Db.Pool.get_other_config ~__context ~self:pool 
	  | [] -> warn "no pool object"; assert false
	  | _  -> warn "multiple pool objects"; assert false
	with _ -> [] 
      in
      resync_loadavg_limit other_config;
       Dbsync_slave.update_env __context other_config;
       if Pool_role.is_master () then Dbsync_master.update_env __context;
       (* we sync dom0 config files on slaves; however, we don't want
	  to do this in dbsync_slave since we want the master to have
	  been set on the pool record before we run it [otherwise we
	  try and sync config files from the old master if someone's
	  done a pool.designate_new_master!] *)
       if not (Pool_role.is_master ()) then resync_dom0_config_files();
       (* after all resyncing has been done (on masters and slaves) we need to initialise our VDI refcounts *)
       Storage_access.VDI.initialise_refcounts_from_db()
    )

let setup () =
  try
    update_env ()
  with exn ->
    debug "dbsync caught an exception: %s"
      (ExnHelper.string_of_exn exn);
    log_backtrace();
    raise exn
