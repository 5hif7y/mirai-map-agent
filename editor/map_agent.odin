package map_agent_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import agent "./agent"
import map_convert "../../map_convert/editor"
import formats "../../map_convert/editor/formats"
import mapfile "../../valve220/editor/mapfile"

// What an agent uses to write a map in two passes, as methods of the editor
// API (and so of its MCP server):
//
// 1. Structural: map_agent.layout turns rooms and corridors written as JSON
//    into the brushes of a closed shell (agent/layout.odin). The JSON is about
//    four times shorter to write than the brushes, and cannot leave a wall
//    open to the void.
// 2. Detail: the agent adds brushes in a func_detail entity, as Valve 220.
// 3. Between passes: map_agent.check walks a player from the spawns to the
//    objectives, finds leaks to the void, measures the walk of each team and,
//    given the structure, says whether every brush of it is still there.

@(storage)
Map_Agent_Api :: struct {provider:editor.Api_Provider}

MAP_AGENT_API_DEFAULT :: Map_Agent_Api{provider={register=map_agent_api_register}}

CHECK_REPORT :: ".mirai/tmp/map-agent-check.txt"

Layout_Params :: struct {
    layout:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The rooms, corridors and entities as JSON, relative to the project: unit, textures, rooms (name x y w d floor height), corridors (from to width), entities (classname room at keys)"`,
    out:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The Valve 220 .map to write, relative to the project"`,
}

Layout_Result :: struct {
    brushes:int `mirai:"label=Brushes of the shell"`,
    entities:int `mirai:"label=Entities, worldspawn included"`,
}

Check_Params :: struct {
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The map to check, relative to the project: Valve 220, a .map of Quake or Doom 3, a .vmf or a BSP map_convert reads"`,
    base:[editor.API_PATH_BYTES]u8 `mirai:"text,optional,label=The structure the map was detailed from, relative to the project: every brush of it must be in the map unchanged"`,
}

Check_Result :: struct {
    pass:bool `mirai:"label=Every spawn and objective is reached, there is no leak and the structure is kept"`,
    leak:bool `mirai:"label=The air around a spawn reaches past every brush: the map is open to the void"`,
    reached:int `mirai:"label=Cells of 16 units a player reaches from the spawns"`,
    report:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The full report under .mirai/tmp/ of the project: each spawn and objective, the walking distance of each team to each objective, the structure kept"`,
}

@(private)
map_agent_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="map_agent.layout",summary="Builds the structural pass of a map: rooms and corridors written as JSON become the brushes of a closed shell, as a Valve 220 .map in the project.",params=Layout_Params,params_info=type_info_of(Layout_Params),result=Layout_Result,result_info=type_info_of(Layout_Result),run=api_layout})
    editor.api_method_register(s,{name="map_agent.check",summary="Checks a map between passes: a player walks from the spawns to the objectives, the air must not reach the void, the walk of each team is measured and, given the structure, every brush of it must be kept.",params=Check_Params,params_info=type_info_of(Check_Params),result=Check_Result,result_info=type_info_of(Check_Result),run=api_check})
}

// A map of the project in the model: Valve 220 or standard Quake text, or
// any other format map_convert reads.
@(private)
read_map :: proc(path:string) -> (m:mapfile.Map,message:string,ok:bool) {
    bytes,error:=serial.file_read(path,context.temp_allocator)
    if error!=.None {return m,fmt.tprintf("%s could not be read",path),false}
    if formats.kind_of(bytes[:min(len(bytes),4096)])==.None {
        message,ok=formats.convert_quake_map(string(bytes),&m)
        return
    }
    r,converted:=formats.convert(bytes,{},context.temp_allocator)
    return r.m,r.message,converted
}

@(private)
api_layout :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Layout_Params)
    source,ok:=map_convert.project_file(s,call,base.text_get(p.layout[:]),"layout")
    if !ok {return}
    out,out_ok:=map_convert.project_file(s,call,base.text_get(p.out[:]),"out")
    if !out_ok {return}
    bytes,error:=serial.file_read(source,context.temp_allocator)
    if error!=.None {api.call_failf(call,api.INVALID_PARAMS,"layout %q could not be read",source);return}
    m:mapfile.Map
    if message,built:=agent.layout_build(string(bytes),&m);!built {api.call_failf(call,api.INVALID_PARAMS,"%s: %s",source,message);return}
    os.make_directory_all(filepath.dir(out))
    if os.write_entire_file(out,transmute([]u8)mapfile.map_write(&m,context.temp_allocator))!=nil {api.call_failf(call,api.SERVER_ERROR,"%s could not be written",out);return}
    result:=api.call_result(call,Layout_Result)
    for e in m.entities {result.brushes+=len(e.brushes)}
    result.entities=len(m.entities)
}

@(private)
api_check :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Check_Params)
    path,ok:=map_convert.project_file(s,call,base.text_get(p.path[:]),"path")
    if !ok {return}
    m,message,read:=read_map(path)
    if !read {api.call_failf(call,api.INVALID_PARAMS,"%s",message);return}
    report:agent.Check_Report
    if given:=base.text_get(p.base[:]);given!="" {
        base_path,base_ok:=map_convert.project_file(s,call,given,"base")
        if !base_ok {return}
        structure,base_message,base_read:=read_map(base_path)
        if !base_read {api.call_failf(call,api.INVALID_PARAMS,"%s",base_message);return}
        report=agent.map_check(&m,&structure)
    } else {
        report=agent.map_check(&m)
    }
    text,pass:=agent.check_text(&report,context.temp_allocator)
    file:=project.path(s.project_root,CHECK_REPORT,allocator=context.temp_allocator)
    os.make_directory_all(filepath.dir(file))
    if os.write_entire_file(file,transmute([]u8)text)!=nil {api.call_failf(call,api.SERVER_ERROR,"The report could not be written to %s",file);return}
    result:=api.call_result(call,Check_Result)
    result.pass,result.leak,result.reached=pass,report.leak,report.reachable
    base.text_set(result.report[:],CHECK_REPORT)
}
