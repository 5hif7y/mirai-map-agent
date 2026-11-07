package map_agent_tools

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import mapfile "../../../valve220/editor/mapfile"

// What a generated map must keep between passes, measured without running the
// game: the brushes of the structure stay as they were, and a player can walk
// from the spawns to the objectives.
//
// Walking is measured on a grid of cells of CHECK_CELL units filled by the
// solid brushes: a player stands on a square of 2×2 cells (32 units) that is
// empty up to the height of a player with floor under some of it, and goes to
// a neighbouring square up a step of at most one cell, or down any drop.
// It is a conservative stand-in for the navigation of the game: it knows no
// ladders, crouching, water or jumps.
//
// It also floods the air from the spawns through empty cells: when the flood
// reaches the edge of the grid, a cell of air past every brush, the map is open
// to the void (a leak, which qbsp refuses). A gap narrower than a cell can be
// missed.

CHECK_CELL :: 16          // units: the grid of TrenchBroom, and a step of GoldSrc (18) rounded down
CHECK_PLAYER_CELLS :: 5   // 72 units, the hull of a standing player of GoldSrc
CHECK_PLAYER_WIDTH :: 2   // 32 units: a player stands on a square of 2×2 cells
CHECK_MAX_CELLS :: 64<<20 // cells the grid may have

// Brush textures a player walks through: triggers, origin and hint brushes,
// and the liquids of Quake and GoldSrc (names that start with ! or *).
@(private)
not_solid :: proc(texture:string) -> bool {
    name:=strings.to_lower(texture,context.temp_allocator)
    if slash:=strings.last_index_byte(name,'/');slash>=0 {name=name[slash+1:]}
    return name=="aaatrigger" || name=="trigger" || name=="origin" || name=="hint" ||
        strings.has_prefix(name,"!") || strings.has_prefix(name,"*")
}

// Entities whose brushes a player walks through.
@(private)
passable_entity :: proc(classname:string) -> bool {
    return strings.has_prefix(classname,"trigger_") || strings.has_prefix(classname,"func_buyzone") ||
        strings.has_prefix(classname,"func_bomb_target") || strings.has_prefix(classname,"func_hostage_rescue") ||
        classname=="func_illusionary" || classname=="func_water" || strings.has_prefix(classname,"func_door") ||
        classname=="func_ladder"
}

Check_Point :: struct {
    name:string,     // classname, and targetname when it has one
    position:[3]f64, // in map units
    cell:[3]int,
    standable:bool,  // a standable cell was found at or below it
    reached:bool,
}

// How far the spawns of one classname walk to an objective: steps of a cell
// between neighbours along x and y, so an upper bound of the straight walk
// (by up to √2 on a diagonal); -1 when they do not reach it.
Check_Distance :: struct {
    spawns:string,
    objective:int, // in Check_Report.objectives
    units:f64,
}

@(private)
spawn_class :: proc(name:string) -> string {
    if space:=strings.index_byte(name,' ');space>=0 {return name[:space]}
    return name
}

Check_Report :: struct {
    brushes,solid_brushes:int,
    cells:[3]int,
    standable,reachable:int,
    spawns,objectives:[dynamic]Check_Point,
    base_brushes,base_kept:int, // with a structure to compare: its brushes, and how many are in the map unchanged
    leak:bool,       // the air around a spawn reaches the edge of the grid
    leak_from:string, // the spawn it leaks from
    distances:[dynamic]Check_Distance,
    messages:[dynamic]string,
}

@(private)
brush_corners :: proc(b:mapfile.Brush,out:^[dynamic][3]f64) {
    clear(out)
    sides:=b.sides[:]
    for i in 0..<len(sides) {
        for j in i+1..<len(sides) {
            for k in j+1..<len(sides) {
                a,bb,c:=sides[i].plane,sides[j].plane,sides[k].plane
                bc:=mapfile.cross(bb.normal,c.normal)
                det:=mapfile.dot(a.normal,bc)
                if abs(det)<1e-9 {continue}
                p:=(bc*a.dist+mapfile.cross(c.normal,a.normal)*bb.dist+mapfile.cross(a.normal,bb.normal)*c.dist)/det
                inside:=true
                for s in sides {if mapfile.dot(s.plane.normal,p)-s.plane.dist>0.01 {inside=false;break}}
                if inside {append(out,p)}
            }
        }
    }
}

@(private)
entity_origin :: proc(e:^mapfile.Entity) -> (p:[3]f64,ok:bool) {
    value:=mapfile.entity_get(e,"origin") or_return
    v:[3]f64
    if !mapfile.text_numbers(value,v[:]) {return}
    return v,true
}

// A brush as a key that does not depend on the order of its sides or the
// points that describe them: its planes rounded, sorted, with their textures.
@(private)
brush_key :: proc(b:mapfile.Brush) -> string {
    parts:=make([dynamic]string,context.temp_allocator)
    for s in b.sides {
        n:=s.plane.normal
        append(&parts,fmt.tprintf("%.4f %.4f %.4f %.2f %s",n.x,n.y,n.z,s.plane.dist,strings.to_lower(s.texture,context.temp_allocator)))
    }
    slice.sort(parts[:])
    return strings.join(parts[:],"|",context.temp_allocator)
}

// Checks m. base, when given, is the structure m was detailed from.
map_check :: proc(m:^mapfile.Map,base:^mapfile.Map=nil) -> (r:Check_Report) {
    corners:=make([dynamic][3]f64,context.temp_allocator)
    lo,hi:=[3]f64{1e18,1e18,1e18},[3]f64{-1e18,-1e18,-1e18}
    Solid :: struct {sides:[]mapfile.Side,lo,hi:[3]f64}
    solids:=make([dynamic]Solid,context.temp_allocator)
    for &e in m.entities {
        classname,_:=mapfile.entity_get(&e,"classname")
        for b in e.brushes {
            r.brushes+=1
            brush_corners(b,&corners)
            if len(corners)<4 {continue}
            blo,bhi:=corners[0],corners[0]
            for p in corners {
                for k in 0..<3 {blo[k]=min(blo[k],p[k]);bhi[k]=max(bhi[k],p[k])}
            }
            for k in 0..<3 {lo[k]=min(lo[k],blo[k]);hi[k]=max(hi[k],bhi[k])}
            if passable_entity(classname) {continue}
            all_passable:=true
            for s in b.sides {if !not_solid(s.texture) {all_passable=false;break}}
            if all_passable {continue}
            append(&solids,Solid{b.sides[:],blo,bhi})
            r.solid_brushes+=1
        }
    }
    if r.solid_brushes==0 {append(&r.messages,"the map has no solid brushes");return}
    // one cell of air past the brushes on every side, where a leak ends
    for k in 0..<3 {
        lo[k]=math.floor(lo[k]/CHECK_CELL)*CHECK_CELL-CHECK_CELL
        r.cells[k]=int(math.ceil((hi[k]-lo[k])/CHECK_CELL))+2
    }
    total:=r.cells.x*r.cells.y*r.cells.z
    if total>CHECK_MAX_CELLS {
        append(&r.messages,fmt.aprintf("the map spans %v cells of %d units, more than the check measures",r.cells,CHECK_CELL))
        return
    }
    index :: proc(cells:[3]int,c:[3]int) -> int {return (c.z*cells.y+c.y)*cells.x+c.x}
    // Each brush fills, in each column of cells it spans, the cells that the
    // stretch of z it covers on the vertical through the column's center
    // overlaps by a unit or more: exact for slopes and for floors thinner than
    // a cell, which testing cell centers misses.
    solid:=make([]bool,total,context.temp_allocator)
    for s in solids {
        c0,c1:[2]int
        for k in 0..<2 {
            c0[k]=max(0,int(math.floor((s.lo[k]-lo[k])/CHECK_CELL)))
            c1[k]=min(r.cells[k]-1,int(math.floor((s.hi[k]-lo[k])/CHECK_CELL)))
        }
        for y in c0.y..=c1.y {
            for x in c0.x..=c1.x {
                cx:=lo.x+(f64(x)+0.5)*CHECK_CELL
                cy:=lo.y+(f64(y)+0.5)*CHECK_CELL
                zlo,zhi:f64=-1e18,1e18
                for side in s.sides {
                    n:=side.plane.normal
                    rest:=side.plane.dist-n.x*cx-n.y*cy
                    switch {
                    case n.z>1e-9:  zhi=min(zhi,rest/n.z)
                    case n.z< -1e-9: zlo=max(zlo,rest/n.z)
                    case rest<0:    zlo,zhi=1,0 // the column is outside a vertical side
                    }
                }
                if zhi-zlo<1 {continue}
                z0:=max(0,int(math.floor((zlo-lo.z)/CHECK_CELL)))
                z1:=min(r.cells.z-1,int(math.floor((zhi-lo.z)/CHECK_CELL)))
                for z in z0..=z1 {
                    bottom:=lo.z+f64(z)*CHECK_CELL
                    if min(zhi,bottom+CHECK_CELL)-max(zlo,bottom)>=1 {solid[index(r.cells,{x,y,z})]=true}
                }
            }
        }
    }
    // The player's square has its corner at c: empty up to its height, with
    // floor under some of it.
    standable :: proc(solid:[]bool,cells:[3]int,c:[3]int) -> bool {
        if c.z<1 || c.z+CHECK_PLAYER_CELLS>cells.z {return false}
        if c.x+CHECK_PLAYER_WIDTH>cells.x || c.y+CHECK_PLAYER_WIDTH>cells.y {return false}
        floor:=false
        for dy in 0..<CHECK_PLAYER_WIDTH {
            for dx in 0..<CHECK_PLAYER_WIDTH {
                if solid[index(cells,{c.x+dx,c.y+dy,c.z-1})] {floor=true}
                for h in 0..<CHECK_PLAYER_CELLS {if solid[index(cells,{c.x+dx,c.y+dy,c.z+h})] {return false}}
            }
        }
        return floor
    }
    for z in 0..<r.cells.z {
        for y in 0..<r.cells.y {
            for x in 0..<r.cells.x {if standable(solid,r.cells,{x,y,z}) {r.standable+=1}}
        }
    }
    // Room over the player's head to step up from c.
    standable_head :: proc(solid:[]bool,cells:[3]int,c:[3]int) -> bool {
        top:=c.z+CHECK_PLAYER_CELLS
        if top>=cells.z {return false}
        for dy in 0..<CHECK_PLAYER_WIDTH {for dx in 0..<CHECK_PLAYER_WIDTH {if solid[index(cells,{c.x+dx,c.y+dy,top})] {return false}}}
        return true
    }
    // Spawns and objectives
    for &e in m.entities {
        classname,_:=mapfile.entity_get(&e,"classname")
        point:Check_Point
        cells_up:=3 // brushes of objectives often sink into the floor: look a little up as well
        name:=classname
        if target,has:=mapfile.entity_get(&e,"targetname");has {name=fmt.aprintf("%s %s",classname,target)}
        is_spawn:=strings.has_prefix(classname,"info_player_")
        is_objective:=strings.has_prefix(classname,"func_bomb_target") || strings.has_prefix(classname,"info_bomb_target") ||
            strings.has_prefix(classname,"func_hostage_rescue") || classname=="hostage_entity" ||
            strings.has_prefix(classname,"func_buyzone") || classname=="info_objective"
        if !is_spawn && !is_objective {continue}
        if origin,has:=entity_origin(&e);has {
            point.position=origin
        } else if len(e.brushes)>0 {
            // the middle of its brushes, at the height of their bottom
            blo,bhi:=[3]f64{1e18,1e18,1e18},[3]f64{-1e18,-1e18,-1e18}
            for b in e.brushes {
                brush_corners(b,&corners)
                for p in corners {for k in 0..<3 {blo[k]=min(blo[k],p[k]);bhi[k]=max(bhi[k],p[k])}}
            }
            point.position={(blo.x+bhi.x)/2,(blo.y+bhi.y)/2,blo.z+1}
            // a zone counts when a player stands anywhere in its height
            cells_up=max(cells_up,int(math.ceil((bhi.z-blo.z)/CHECK_CELL)))
        } else {continue}
        point.name=name
        // the standable cell at or below the point, within a few cells
        c:[3]int
        for k in 0..<3 {c[k]=int(math.floor((point.position[k]-lo[k])/CHECK_CELL))}
        c.x,c.y=max(c.x-CHECK_PLAYER_WIDTH/2+1,0),max(c.y-CHECK_PLAYER_WIDTH/2+1,0)
        for drop in -cells_up..<8 {
            cc:=c-{0,0,drop}
            if cc.z>=r.cells.z {continue}
            if cc.x<0 || cc.y<0 || cc.z<0 || cc.x>=r.cells.x || cc.y>=r.cells.y || cc.z>=r.cells.z {break}
            if standable(solid,r.cells,cc) {point.cell,point.standable=cc,true;break}
        }
        if is_spawn {append(&r.spawns,point)} else {append(&r.objectives,point)}
    }
    // Walks from starts: dist is the steps of each cell from the nearest
    // start, -1 when not reached; the result is the count of reached cells.
    walk :: proc(solid:[]bool,cells:[3]int,starts:[][3]int,dist:[]i32) -> int {
        queue:=make([dynamic][3]int,context.temp_allocator)
        slice.fill(dist,-1)
        for s in starts {
            i:=index(cells,s)
            if dist[i]<0 {dist[i]=0;append(&queue,s)}
        }
        for head:=0;head<len(queue);head+=1 {
            c:=queue[head]
            for d in ([4][2]int{{1,0},{-1,0},{0,1},{0,-1}}) {
                nx,ny:=c.x+d[0],c.y+d[1]
                if nx<0 || ny<0 || nx>=cells.x || ny>=cells.y {continue}
                next:[3]int
                found:=false
                switch {
                case standable(solid,cells,{nx,ny,c.z+1}) && standable_head(solid,cells,c):
                    next,found={nx,ny,c.z+1},true // a step up, with room overhead to take it
                case standable(solid,cells,{nx,ny,c.z}):
                    next,found={nx,ny,c.z},true
                case:
                    // a drop: the column of the neighbour is empty from the body down to a floor
                    if nx+CHECK_PLAYER_WIDTH>cells.x || ny+CHECK_PLAYER_WIDTH>cells.y {break}
                    empty :: proc(solid:[]bool,cells:[3]int,x,y,z:int) -> bool {
                        for dy in 0..<CHECK_PLAYER_WIDTH {for dx in 0..<CHECK_PLAYER_WIDTH {if solid[index(cells,{x+dx,y+dy,z})] {return false}}}
                        return true
                    }
                    blocked:=false
                    for h in 0..<CHECK_PLAYER_CELLS {if !empty(solid,cells,nx,ny,c.z+h) {blocked=true;break}}
                    if blocked {break}
                    for nz:=c.z;nz>=1;nz-=1 {
                        if !empty(solid,cells,nx,ny,nz-1) {
                            if standable(solid,cells,{nx,ny,nz}) {next,found={nx,ny,nz},true}
                            break
                        }
                    }
                }
                if !found {continue}
                i:=index(cells,next)
                if dist[i]<0 {dist[i]=dist[index(cells,c)]+1;append(&queue,next)}
            }
        }
        return len(queue)
    }
    // Flood from every spawn that stands.
    starts:=make([dynamic][3]int,context.temp_allocator)
    for s in r.spawns {if s.standable {append(&starts,s.cell)}}
    dist:=make([]i32,total,context.temp_allocator)
    r.reachable=walk(solid,r.cells,starts[:],dist)
    reached:=make([]bool,total,context.temp_allocator)
    for d,i in dist {reached[i]=d>=0}
    // The walking distance from the spawns of each classname to each objective.
    classes:=make([dynamic]string,context.temp_allocator)
    for s in r.spawns {
        class:=spawn_class(s.name)
        if !slice.contains(classes[:],class) {append(&classes,class)}
    }
    for class in classes {
        clear(&starts)
        for s in r.spawns {if s.standable && spawn_class(s.name)==class {append(&starts,s.cell)}}
        walk(solid,r.cells,starts[:],dist)
        for p,i in r.objectives {
            units:=-1.0
            if p.standable {if v:=dist[index(r.cells,p.cell)];v>=0 {units=f64(v)*CHECK_CELL}}
            append(&r.distances,Check_Distance{class,i,units})
        }
    }
    queue:=make([dynamic][3]int,context.temp_allocator)
    // Flood the air from the spawns.
    air:=make([]bool,total,context.temp_allocator)
    for s in r.spawns {
        c:[3]int
        for k in 0..<3 {c[k]=clamp(int(math.floor((s.position[k]-lo[k])/CHECK_CELL)),0,r.cells[k]-1)}
        i:=index(r.cells,c)
        if solid[i] || air[i] {continue}
        air[i]=true
        append(&queue,c)
        for head:=0;head<len(queue) && !r.leak;head+=1 {
            a:=queue[head]
            if a.x==0 || a.y==0 || a.z==0 || a.x==r.cells.x-1 || a.y==r.cells.y-1 || a.z==r.cells.z-1 {
                r.leak,r.leak_from=true,s.name
                break
            }
            for d in ([6][3]int{{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}}) {
                n:=a+d
                j:=index(r.cells,n)
                if !solid[j] && !air[j] {air[j]=true;append(&queue,n)}
            }
        }
        if r.leak {break}
    }
    for &p in r.spawns {p.reached=p.standable && reached[index(r.cells,p.cell)]}
    for &p in r.objectives {p.reached=p.standable && reached[index(r.cells,p.cell)]}
    if base!=nil {
        keys:=make(map[string]int,context.temp_allocator)
        for &e in m.entities {for b in e.brushes {keys[brush_key(b)]+=1}}
        for &e in base.entities {
            for b in e.brushes {
                r.base_brushes+=1
                k:=brush_key(b)
                if keys[k]>0 {keys[k]-=1;r.base_kept+=1}
            }
        }
    }
    return
}

// The report as text, and whether the map passes: every spawn and objective
// stands and is reached, and every brush of the structure is kept.
check_text :: proc(r:^Check_Report,allocator:=context.allocator) -> (text:string,pass:bool) {
    b:=strings.builder_make(allocator)
    pass=len(r.messages)==0
    for msg in r.messages {fmt.sbprintf(&b,"error: %s\n",msg)}
    fmt.sbprintf(&b,"brushes %d (%d solid), grid %v of %d units, %d standable cells, %d reached from the spawns\n",
        r.brushes,r.solid_brushes,r.cells,CHECK_CELL,r.standable,r.reachable)
    list :: proc(b:^strings.Builder,title:string,points:[]Check_Point,pass:^bool) {
        fmt.sbprintf(b,"%s: %d\n",title,len(points))
        for p in points {
            state:="reached" if p.reached else ("not reached" if p.standable else "no floor under it")
            fmt.sbprintf(b,"  %-32s (%.0f %.0f %.0f) %s\n",p.name,p.position.x,p.position.y,p.position.z,state)
            if !p.reached {pass^=false}
        }
    }
    list(&b,"spawns",r.spawns[:],&pass)
    list(&b,"objectives",r.objectives[:],&pass)
    if len(r.distances)>0 {fmt.sbprintf(&b,"walking distance, in units along the grid:\n")}
    for d in r.distances {
        p:=r.objectives[d.objective]
        if d.units<0 {
            fmt.sbprintf(&b,"  from %-24s to %s (%.0f %.0f %.0f): not reached\n",d.spawns,p.name,p.position.x,p.position.y,p.position.z)
        } else {
            fmt.sbprintf(&b,"  from %-24s to %s (%.0f %.0f %.0f): %.0f\n",d.spawns,p.name,p.position.x,p.position.y,p.position.z,d.units)
        }
    }
    if len(r.spawns)==0 {fmt.sbprintf(&b,"error: no info_player_* to walk from\n");pass=false}
    if r.leak {fmt.sbprintf(&b,"error: leak: the air around %s reaches past every brush, the map is open to the void\n",r.leak_from);pass=false}
    if r.base_brushes>0 {
        fmt.sbprintf(&b,"structure: %d of %d brushes kept unchanged\n",r.base_kept,r.base_brushes)
        if r.base_kept<r.base_brushes {pass=false}
    }
    fmt.sbprintf(&b,"%s\n","pass" if pass else "fail")
    return strings.to_string(b),pass
}
