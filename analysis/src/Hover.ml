open SharedTypes

let codeBlock code = Printf.sprintf "```rescript\n%s\n```" code

let showModuleTopLevel ~docstring ~name (topLevel : Module.item list) =
  let contents =
    topLevel
    |> List.map (fun item ->
           match item.Module.kind with
           (* TODO pretty print module contents *)
           | Type ({decl}, recStatus) ->
             "  " ^ (decl |> Shared.declToString ~recStatus item.name)
           | Module _ -> "  module " ^ item.name
           | Value typ ->
             "  let " ^ item.name ^ ": " ^ (typ |> Shared.typeToString))
    (* TODO indent *)
    |> String.concat "\n"
  in
  let full = codeBlock ("module " ^ name ^ " = {" ^ "\n" ^ contents ^ "\n}") in
  let doc =
    match docstring with
    | [] -> ""
    | _ :: _ -> "\n" ^ (docstring |> String.concat "\n") ^ "\n"
  in
  Some (doc ^ full)

let rec showModule ~docstring ~(file : File.t) ~name
    (declared : Module.t Declared.t option) =
  match declared with
  | None -> showModuleTopLevel ~docstring ~name file.structure.items
  | Some {item = Structure {items}} -> showModuleTopLevel ~docstring ~name items
  | Some ({item = Constraint (_moduleItem, moduleTypeItem)} as declared) ->
    (* show the interface *)
    showModule ~docstring ~file ~name
      (Some {declared with item = moduleTypeItem})
  | Some {item = Ident path} ->
    Some ("Unable to resolve module reference " ^ Path.name path)

let newHover ~full:{file; package} locItem =
  match locItem.locType with
  | TypeDefinition (name, decl, _stamp) ->
    let typeDef = Shared.declToString name decl in
    Some (codeBlock typeDef)
  | LModule (Definition (stamp, _tip)) | LModule (LocalReference (stamp, _tip))
    -> (
    match Stamps.findModule file.stamps stamp with
    | None -> None
    | Some md -> (
      match References.resolveModuleReference ~file ~package md with
      | None -> None
      | Some (file, declared) ->
        let name, docstring =
          match declared with
          | Some d -> (d.name.txt, d.docstring)
          | None -> (file.moduleName, file.structure.docstring)
        in
        showModule ~docstring ~name ~file declared))
  | LModule (GlobalReference (moduleName, path, tip)) -> (
    match ProcessCmt.fileForModule ~package moduleName with
    | None -> None
    | Some file -> (
      let env = QueryEnv.fromFile file in
      match ResolvePath.resolvePath ~env ~path ~package with
      | None -> None
      | Some (env, name) -> (
        match References.exportedForTip ~env name tip with
        | None -> None
        | Some stamp -> (
          match Stamps.findModule file.stamps stamp with
          | None -> None
          | Some md -> (
            match References.resolveModuleReference ~file ~package md with
            | None -> None
            | Some (file, declared) ->
              let name, docstring =
                match declared with
                | Some d -> (d.name.txt, d.docstring)
                | None -> (file.moduleName, file.structure.docstring)
              in
              showModule ~docstring ~name ~file declared)))))
  | LModule NotFound -> None
  | TopLevelModule name -> (
    match ProcessCmt.fileForModule ~package name with
    | None -> None
    | Some file ->
      showModule ~docstring:file.structure.docstring ~name:file.moduleName ~file
        None)
  | Typed (_, _, Definition (_, (Field _ | Constructor _))) -> None
  | Constant t ->
    Some
      (codeBlock
         (match t with
         | Const_int _ -> "int"
         | Const_char _ -> "char"
         | Const_string _ -> "string"
         | Const_float _ -> "float"
         | Const_int32 _ -> "int32"
         | Const_int64 _ -> "int64"
         | Const_nativeint _ -> "int"))
  | Typed (_, t, locKind) ->
    let fromType ~docstring typ =
      let typeString = codeBlock (typ |> Shared.typeToString) in
      let extraTypeInfo =
        let env = QueryEnv.fromFile file in
        match typ |> Shared.digConstructor with
        | None -> None
        | Some path -> (
          match References.digConstructor ~env ~package path with
          | None -> None
          | Some (_env, {docstring; name = {txt}; item = {decl}}) ->
            if Utils.isUncurriedInternal path then None
            else Some (decl |> Shared.declToString txt, docstring))
      in
      let typeString, docstring =
        match extraTypeInfo with
        | None -> (typeString, docstring)
        | Some (extra, extraDocstring) ->
          (typeString ^ "\n\n" ^ codeBlock extra, extraDocstring)
      in
      (typeString, docstring)
    in
    let parts =
      match References.definedForLoc ~file ~package locKind with
      | None ->
        let typeString, docstring = t |> fromType ~docstring:[] in
        typeString :: docstring
      | Some (docstring, res) -> (
        match res with
        | `Declared ->
          let typeString, docstring = t |> fromType ~docstring in
          typeString :: docstring
        | `Constructor {cname = {txt}; args} ->
          let typeString, docstring = t |> fromType ~docstring in
          let argsString =
            match args with
            | [] -> ""
            | _ ->
              args
              |> List.map (fun (t, _) -> Shared.typeToString t)
              |> String.concat ", " |> Printf.sprintf "(%s)"
          in
          typeString :: codeBlock (txt ^ argsString) :: docstring
        | `Field ->
          let typeString, docstring = t |> fromType ~docstring in
          typeString :: docstring)
    in
    Some (String.concat "\n\n" parts)
