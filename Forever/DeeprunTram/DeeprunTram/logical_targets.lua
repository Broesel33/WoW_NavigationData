-- Logical target catalogue, compact format 2 (TechnicalDocumentation/05). No graph bindings, no provenance.
local LogicalTargets = {format=2,schema=1,layer="logical",zoneId=499,coordinateSpace="world",nativeMapId=369,availability="static",sourceSha256="3956C06803DD495D319886C01336463FD360C9D059A423CC317B70EA928E14B7",converterSha256="FEB3054D6400AA706B5B91E72DA1CF248EB540EABC1978F5247B31CE737BADEA",payloadSha256="964BDBC80611E5CA98F58613A9B0B306182F41E0646D5F30A1785E25C8721413"}
LogicalTargets.classes = {
{"npc","quest_giver",12997,"Monty (Rat Extermination Specialist)","Monty (Rattenvernichtungsspezialist)"},
{"npc",{"quest_giver","vendor"},13018,"Nipsy"},
{"creature","npc_or_mob",14041,"Haggle",a="possible_spawn"},
}
LogicalTargets.targets = {
{"creature_52957",1,-19.631,40.075,-4.214},
{"creature_52990",2,-20.984,2459.93,-4.297},
{"creature_53788",3,-18.497,-17.03,-4.297},
}
WVN7Logical = WVN7Logical or {}
WVN7Logical[499] = LogicalTargets
