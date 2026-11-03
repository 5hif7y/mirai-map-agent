package map_agent_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import agent "project:plugins/map_agent/editor/agent"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-map-agent-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// The map of examples/defusal_open, as check reads it from the project:
// the detail kept the 59 brushes of the structure and both teams reach both
// bomb sites.
@(test)
the_example_passes_check_over_its_structure :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    folder:=temp_folder("defusal")
    defer os.remove_all(folder)
    files:=[?]struct{name:string,text:string}{
        {"map.map",#load("../examples/defusal_open/map.map",string)},
        {"structure.map",#load("../examples/defusal_open/structure.map",string)},
    }
    for f in files {testing.expect(t,os.write_entire_file(fmt.tprintf("%s/%s",folder,f.name),transmute([]u8)f.text)==nil)}
    m,message,ok:=read_map(fmt.tprintf("%s/map.map",folder))
    if !testing.expectf(t,ok,"%s",message) {return}
    structure,base_message,base_ok:=read_map(fmt.tprintf("%s/structure.map",folder))
    if !testing.expectf(t,base_ok,"%s",base_message) {return}
    r:=agent.map_check(&m,&structure)
    text,pass:=agent.check_text(&r)
    testing.expectf(t,pass && !r.leak && r.base_kept==59 && r.base_brushes==59,"%s",text)
}
