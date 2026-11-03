package map_agent_tools

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import mapfile "project:plugins/valve220/editor/mapfile"

// The structural pass of a generated map as data instead of brushes: rooms
// and corridors on a grid, which layout_build turns into the brushes of a
// Valve 220 map. An agent writes a few lines of JSON per room instead of six
// planes per brush, and the build cannot leave a gap in a wall or a room open
// to the void. The same idea as the All-Black representation of Cardamone et
// al. (2011): space dug out of the solid as rooms and corridors.
//
//  {
//    "unit": 16,                      grid step in map units (default 16)
//    "textures": {"floor": "...", "wall": "...", "ceiling": "..."},
//    "rooms": [{"name": "a", "x": 0, "y": 0, "w": 32, "d": 24, "floor": 0, "height": 12}],
//    "corridors": [{"from": "a", "to": "b", "width": 4}],
//    "entities": [{"classname": "info_player_terrorist", "room": "a", "at": [4, 4]}]
//  }
//
// Sizes are in grid steps. A room is a box dug out at floor height; a
// corridor joins the centers of two rooms with an L of width cells, at the
// floor of the lower and as tall as the lower room. Everything sits in one
// shell of solid brushes: walls are what is not dug.

Layout_Room :: struct {
    name:string,
    x,y,w,d:int,
    floor,height:int,
}

Layout_Corridor :: struct {
    from,to:string,
    width:int,
}

Layout_Entity :: struct {
    classname:string,
    room:string,
    at:[2]int,         // cells from the corner of the room
    keys:map[string]string,
}

Layout_Textures :: struct {floor,wall,ceiling:string}

Layout :: struct {
    unit:int,
    textures:Layout_Textures,
    rooms:[]Layout_Room,
    corridors:[]Layout_Corridor,
    entities:[]Layout_Entity,
}

@(private)
Box :: struct {lo,hi:[3]int} // in grid steps, hi exclusive

@(private)
// seen: by side (+x -x +y -y +z -z), whether it borders dug space; a side
// that does not is skip, which no engine draws.
box_brush :: proc(b:Box,unit:int,textures:Layout_Textures,seen:[6]bool) -> mapfile.Brush {
    brush:mapfile.Brush
    lo:=[3]f64{f64(b.lo.x*unit),f64(b.lo.y*unit),f64(b.lo.z*unit)}
    hi:=[3]f64{f64(b.hi.x*unit),f64(b.hi.y*unit),f64(b.hi.z*unit)}
    for k in 0..<3 {
        for sign,si in ([2]f64{1,-1}) {
            n:[3]f64
            n[k]=sign
            dist:=hi[k] if sign>0 else -lo[k]
            side:=mapfile.Side{plane={n,dist},scale={0.25,0.25}}
            side.u,side.v=mapfile.default_axes(n)
            // A face up is a floor, down a ceiling: what it looks at from the room.
            switch {
            case k==2 && sign>0: side.texture=textures.floor
            case k==2 && sign<0: side.texture=textures.ceiling
            case:                side.texture=textures.wall
            }
            if !seen[k*2+si] {side.texture="skip"}
            append(&brush.sides,side)
        }
    }
    return brush
}

// The brushes and entities of a layout.
layout_build :: proc(text:string,m:^mapfile.Map) -> (message:string,ok:bool) {
    layout:Layout
    if err:=json.unmarshal_string(text,&layout,allocator=context.allocator);err!=nil {
        return fmt.aprintf("the layout is not valid JSON for it: %v",err),false
    }
    if layout.unit<=0 {layout.unit=16}
    if layout.textures.floor=="" {layout.textures.floor="dev_floor"}
    if layout.textures.wall=="" {layout.textures.wall="dev_wall"}
    if layout.textures.ceiling=="" {layout.textures.ceiling="dev_ceiling"}
    if len(layout.rooms)==0 {return "the layout has no rooms",false}
    rooms:=make(map[string]int,context.temp_allocator)
    for room,i in layout.rooms {
        if room.w<=0 || room.d<=0 || room.height<=0 {return fmt.aprintf("room %s has no size",room.name),false}
        if room.name in rooms {return fmt.aprintf("two rooms are named %s",room.name),false}
        rooms[room.name]=i
    }
    // The dug space: a set of boxes, the rooms first.
    dug:=make([dynamic]Box,context.temp_allocator)
    for room in layout.rooms {
        append(&dug,Box{{room.x,room.y,room.floor},{room.x+room.w,room.y+room.d,room.floor+room.height}})
    }
    room_boxes:=len(dug)
    for c in layout.corridors {
        a,has_a:=rooms[c.from]
        b,has_b:=rooms[c.to]
        if !has_a || !has_b {return fmt.aprintf("corridor %s-%s names a room that does not exist",c.from,c.to),false}
        width:=c.width if c.width>0 else 4
        ra,rb:=layout.rooms[a],layout.rooms[b]
        ca:=[2]int{ra.x+ra.w/2,ra.y+ra.d/2}
        cb:=[2]int{rb.x+rb.w/2,rb.y+rb.d/2}
        // At the floor of the lower room: a player steps up into the other one
        // when it is at most one cell higher; for more, put rooms in between
        // as stairs, one cell up each.
        floor:=min(ra.floor,rb.floor)
        height:=min(ra.height,rb.height)
        half:=width/2
        // along x at the y of a, then along y at the x of b
        x0,x1:=min(ca.x,cb.x)-half,max(ca.x,cb.x)+width-half
        y0,y1:=min(ca.y,cb.y)-half,max(ca.y,cb.y)+width-half
        append(&dug,Box{{x0,ca.y-half,floor},{x1,ca.y-half+width,floor+height}})
        append(&dug,Box{{cb.x-half,y0,floor},{cb.x-half+width,y1,floor+height}})
    }
    // Bounds: the dug space plus one cell of shell.
    lo,hi:=dug[0].lo,dug[0].hi
    for b in dug {for k in 0..<3 {lo[k]=min(lo[k],b.lo[k]);hi[k]=max(hi[k],b.hi[k])}}
    lo-={1,1,1}
    hi+={1,1,1}
    size:=hi-lo
    if size.x*size.y*size.z>8<<20 {return "the layout is too large to build",false}
    // The solid: every cell of the bounds that no box digs, merged into brushes
    // by runs along x, then rows of equal runs along y, then layers along z.
    filled:=make([]bool,size.x*size.y*size.z,context.temp_allocator)
    at :: proc(size:[3]int,x,y,z:int) -> int {return (z*size.y+y)*size.x+x}
    for z in 0..<size.z {
        for y in 0..<size.y {
            for x in 0..<size.x {
                p:=[3]int{x,y,z}+lo
                inside:=false
                for b,i in dug {
                    if p.x>=b.lo.x && p.x<b.hi.x && p.y>=b.lo.y && p.y<b.hi.y && p.z>=b.lo.z && p.z<b.hi.z {
                        // A corridor runs to the center of its rooms, at the floor of the
                        // lower one: under the floor of a higher room it digs nothing,
                        // so it ends at that room's wall as a step up.
                        if i>=room_boxes && under_a_room(dug[:room_boxes],p) {continue}
                        inside=true
                        break
                    }
                }
                filled[at(size,x,y,z)]=!inside
            }
        }
    }
    world:mapfile.Entity
    append(&world.keys,[2]string{"classname","worldspawn"})
    taken:=make([]bool,len(filled),context.temp_allocator)
    for z in 0..<size.z {
        for y in 0..<size.y {
            for x in 0..<size.x {
                if !filled[at(size,x,y,z)] || taken[at(size,x,y,z)] {continue}
                // grow along x, then y, then z, while every cell is solid and free
                x1:=x+1
                for x1<size.x && filled[at(size,x1,y,z)] && !taken[at(size,x1,y,z)] {x1+=1}
                y1:=y+1
                grow_y: for y1<size.y {
                    for xx in x..<x1 {if !filled[at(size,xx,y1,z)] || taken[at(size,xx,y1,z)] {break grow_y}}
                    y1+=1
                }
                z1:=z+1
                grow_z: for z1<size.z {
                    for yy in y..<y1 {for xx in x..<x1 {if !filled[at(size,xx,yy,z1)] || taken[at(size,xx,yy,z1)] {break grow_z}}}
                    z1+=1
                }
                for zz in z..<z1 {for yy in y..<y1 {for xx in x..<x1 {taken[at(size,xx,yy,zz)]=true}}}
                // a side is seen when a cell just outside it is dug
                seen:[6]bool
                b0,b1:=[3]int{x,y,z},[3]int{x1,y1,z1}
                for k in 0..<3 {
                    for si in 0..<2 {
                        layer:=b1[k] if si==0 else b0[k]-1
                        if layer<0 || layer>=size[k] {continue}
                        u,v:=(k+1)%3,(k+2)%3
                        found: for a in b0[u]..<b1[u] {
                            for c in b0[v]..<b1[v] {
                                cell:[3]int
                                cell[k],cell[u],cell[v]=layer,a,c
                                if !filled[at(size,cell.x,cell.y,cell.z)] {seen[k*2+si]=true;break found}
                            }
                        }
                    }
                }
                append(&world.brushes,box_brush({lo+b0,lo+b1},layout.unit,layout.textures,seen))
            }
        }
    }
    append(&m.entities,world)
    for e in layout.entities {
        room_index,has:=rooms[e.room]
        if !has {return fmt.aprintf("entity %s names room %s, which does not exist",e.classname,e.room),false}
        room:=layout.rooms[room_index]
        entity:mapfile.Entity
        append(&entity.keys,[2]string{"classname",e.classname})
        x:=(room.x+e.at.x)*layout.unit+layout.unit/2
        y:=(room.y+e.at.y)*layout.unit+layout.unit/2
        z:=room.floor*layout.unit+36 // a player's origin is at the middle of its hull
        append(&entity.keys,[2]string{"origin",fmt.aprintf("%d %d %d",x,y,z)})
        for k,v in e.keys {append(&entity.keys,[2]string{strings.clone(k),strings.clone(v)})}
        append(&m.entities,entity)
    }
    return "",true
}

// Whether p is below the floor of a room whose footprint holds it.
@(private)
under_a_room :: proc(rooms:[]Box,p:[3]int) -> bool {
    for r in rooms {
        if p.x>=r.lo.x && p.x<r.hi.x && p.y>=r.lo.y && p.y<r.hi.y && p.z<r.lo.z {return true}
    }
    return false
}
