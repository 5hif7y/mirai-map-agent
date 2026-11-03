package map_agent_tools

import "core:encoding/endian"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import mapfile "project:plugins/valve220/editor/mapfile"
import valvemap "project:plugins/valve220/editor/loader"

// Each test makes the same cube, [0,64] in map units, in one format, converts
// it and imports the .map with the loader: 12 triangles between 0 and 2 m.

@(private="file")
Bytes :: struct {b:[dynamic]u8}


@(private="file")
put_i32 :: proc(w:^Bytes,v:int) {x:[4]u8;endian.put_i32(x[:],.Little,i32(v));append(&w.b,..x[:])}

@(private="file")
put_u16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_u16(x[:],.Little,u16(v));append(&w.b,..x[:])}

@(private="file")
put_i16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_i16(x[:],.Little,i16(v));append(&w.b,..x[:])}

@(private="file")
put_f32 :: proc(w:^Bytes,v:f64) {x:[4]u8;endian.put_f32(x[:],.Little,f32(v));append(&w.b,..x[:])}

@(private="file")
put_name :: proc(w:^Bytes,name:string,size:int) {
    x:=make([]u8,size,context.temp_allocator)
    copy(x,name)
    append(&w.b,..x)
}


// The six outward planes of the cube: +x -x +y -y +z -z.
@(private="file")
CUBE_PLANES :: [6]mapfile.Plane{{{1,0,0},64},{{-1,0,0},0},{{0,1,0},64},{{0,-1,0},0},{{0,0,1},64},{{0,0,-1},0}}


@(private="file")
import_converted :: proc(t:^testing.T,m:^mapfile.Map,name:string) -> (triangles:int,lo,hi:[3]f32,materials:[]string) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-mapconvert-%d-%s",directory,os.get_pid(),name)
    os.remove_all(folder)
    os.make_directory_all(folder)
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/%s.map",folder,name)
    text:=mapfile.map_write(m,context.temp_allocator)
    _=os.write_entire_file(path,transmute([]u8)text)
    formats:=[?]importer.Format{valvemap.FORMAT}
    model,error:=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%s: %v %s\n%s",name,error.code,error.message,text) {return}
    defer importer.model_destroy(&model)
    lo,hi={1e9,1e9,1e9},{-1e9,-1e9,-1e9}
    for mesh in model.meshes {
        triangles+=len(mesh.indices)/3
        lo=linalg.min(lo,mesh.bounds_min)
        hi=linalg.max(hi,mesh.bounds_max)
    }
    names:=make([dynamic]string,context.temp_allocator)
    for mat in model.materials {append(&names,strings.clone(mat.name,context.temp_allocator))}
    return triangles,lo,hi,names[:]
}


@(private="file")
expect_cube :: proc(t:^testing.T,m:^mapfile.Map,name:string,loc:=#caller_location) {
    triangles,lo,hi,_:=import_converted(t,m,name)
    testing.expectf(t,triangles==12,"%s: %d triangles",name,triangles,loc=loc)
    // 32 map units to the meter, Z up turned to Y up, +Y map is -Z.
    testing.expectf(t,linalg.length(lo-[3]f32{0,0,-2})<1e-4 && linalg.length(hi-[3]f32{2,2,0})<1e-4,
        "%s: bounds %v %v",name,lo,hi,loc=loc)
}


@(private="file")
TWO_ROOMS :: `{
  "rooms": [
    {"name": "a", "x": 0, "y": 0, "w": 12, "d": 12, "floor": 0, "height": 8},
    {"name": "b", "x": 24, "y": 0, "w": 12, "d": 12, "floor": 1, "height": 8}
  ],
  "corridors": [{"from": "a", "to": "b", "width": 4}],
  "entities": [
    {"classname": "info_player_start", "room": "a", "at": [4, 4]},
    {"classname": "info_bomb_target", "room": "b", "at": [6, 6]}
  ]
}`


@(private="file")
cube_entity :: proc(m:^mapfile.Map,lo,hi:[3]f64) {
    e:mapfile.Entity
    append(&e.keys,[2]string{"classname","func_detail"})
    brush:mapfile.Brush
    for k in 0..<3 {
        plus,minus:[3]f64
        plus[k],minus[k]=1,-1
        for p in ([2]mapfile.Plane{{plus,hi[k]},{minus,-lo[k]}}) {
            side:=mapfile.Side{plane=p,texture="crate",scale={1,1}}
            side.u,side.v=mapfile.default_axes(p.normal)
            append(&brush.sides,side)
        }
    }
    append(&e.brushes,brush)
    append(&m.entities,e)
}


@(test)
a_layout_builds_a_closed_map_a_player_walks :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    m:mapfile.Map
    message,ok:=layout_build(TWO_ROOMS,&m)
    if !testing.expectf(t,ok,"%s",message) {return}
    // the corridor enters b, one cell higher, as a step
    r:=map_check(&m)
    text,pass:=check_text(&r)
    testing.expectf(t,pass,"%s",text)
    // the faces no room sees are skip
    skipped,drawn:=0,0
    for b in m.entities[0].brushes {for s in b.sides {if s.texture=="skip" {skipped+=1} else {drawn+=1}}}
    testing.expect(t,skipped>0 && drawn>0,"some sides are hidden and some drawn")
    triangles,_,_,_:=import_converted(t,&m,"layout")
    testing.expect(t,triangles>0,"the layout imports")
}


@(test)
check_finds_a_blocked_objective_and_a_changed_structure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    structure,detail,blocked,changed:mapfile.Map
    _,_=layout_build(TWO_ROOMS,&structure)
    _,_=layout_build(TWO_ROOMS,&detail)
    // a crate in a corner of b does not get in the way
    cube_entity(&detail,{24*16+8,8,16},{24*16+40,40,48})
    r:=map_check(&detail,&structure)
    text,pass:=check_text(&r)
    testing.expectf(t,pass && r.base_kept==r.base_brushes,"%s",text)
    // a wall across the corridor shuts b off
    _,_=layout_build(TWO_ROOMS,&blocked)
    cube_entity(&blocked,{16*16,0,0},{17*16,12*16,8*16})
    r=map_check(&blocked,&structure)
    text,pass=check_text(&r)
    testing.expectf(t,!pass && !r.objectives[0].reached && r.spawns[0].reached,"%s",text)
    // a brush of the structure moved
    _,_=layout_build(TWO_ROOMS,&changed)
    changed.entities[0].brushes[0].sides[0].plane.dist+=16
    r=map_check(&changed,&structure)
    _,pass=check_text(&r)
    testing.expect(t,!pass && r.base_kept==r.base_brushes-1,"the moved brush is reported")
}


@(test)
check_finds_a_map_open_to_the_void :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    // a floor with walls on three sides and a spawn on it: the air leaks out of the fourth
    m:mapfile.Map
    cube_entity(&m,{0,0,0},{512,512,16})
    cube_entity(&m,{-16,0,0},{0,512,256})
    cube_entity(&m,{512,0,0},{528,512,256})
    cube_entity(&m,{0,-16,0},{512,0,256})
    spawn:mapfile.Entity
    append(&spawn.keys,[2]string{"classname","info_player_start"},[2]string{"origin","256 256 52"})
    append(&m.entities,spawn)
    r:=map_check(&m)
    text,pass:=check_text(&r)
    testing.expectf(t,!pass && r.leak && r.spawns[0].reached,"%s",text)
    // closed with the fourth wall, a ceiling and a floor under the walls, it holds
    cube_entity(&m,{0,512,0},{512,528,256})
    cube_entity(&m,{-16,-16,256},{528,528,272})
    cube_entity(&m,{-16,-16,-16},{528,528,0})
    r=map_check(&m)
    text,pass=check_text(&r)
    testing.expectf(t,pass && !r.leak,"%s",text)
}


@(test)
a_corridor_ends_at_the_wall_of_a_higher_room :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    m:mapfile.Map
    _,_=layout_build(TWO_ROOMS,&m)
    // under the floor of b, which is a cell higher, where the corridor would run to b's center
    p:=[3]f64{30*16+8,6*16+8,8}
    solid:=false
    for b in m.entities[0].brushes {
        within:=true
        for s in b.sides {if mapfile.dot(s.plane.normal,p)-s.plane.dist>=0 {within=false;break}}
        if within {solid=true;break}
    }
    testing.expect(t,solid,"the floor of the higher room is not dug by the corridor")
}


@(test)
check_measures_the_walk_from_each_spawn_class :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    m:mapfile.Map
    _,_=layout_build(TWO_ROOMS,&m)
    r:=map_check(&m)
    // from (4,4) in a to (24+6,6) in b: at least 26 cells along x and 2 along y
    testing.expect_value(t,len(r.distances),1)
    if len(r.distances)==1 {
        d:=r.distances[0]
        testing.expect(t,d.spawns=="info_player_start" && d.units>=28*16 && d.units<=40*16,"the walk is measured")
    }
}

