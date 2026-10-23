-- Logical target catalogue, compact format 2 (TechnicalDocumentation/05). No graph bindings, no provenance.
local LogicalTargets = {format=2,schema=1,layer="logical",zoneId=499,coordinateSpace="world",nativeMapId=369,availability="static",sourceSha256="3956C06803DD495D319886C01336463FD360C9D059A423CC317B70EA928E14B7",converterSha256="3986801B36094D4E393D073B479533C9EE73D989C5FF054BFEB457A255EE3C56",payloadSha256="81BF55F89EED10D42C47F2918E8F79DBC0723B7E1D6D9DA99595B840CF777A26",dropped={"creature_34119","creature_34120","creature_34121","creature_34122","creature_48268","creature_48296","creature_53789","creature_53790","creature_53791","gameobject_18512"}}
LogicalTargets.classes = {
{"npc","quest_giver",12997,"Monty (Rat Extermination Specialist)","Monty (Rattenvernichtungsspezialist)"},
{"npc",{"quest_giver","vendor"},13018,"Nipsy"},
{"creature","npc_or_mob",14041,"Haggle",a="possible_spawn"},
{"gameobject","object_type_11",176085,"Subway"},
{"gameobject","object_type_11",176084,"Subway"},
{"gameobject","object_type_11",176083,"Subway"},
{"gameobject","object_type_11",176082,"Subway"},
{"gameobject","object_type_11",176081,"Subway"},
{"gameobject","object_type_11",176080,"Subway"},
{"gameobject","object",178304,"Box o' Squirrels"},
}
LogicalTargets.targets = {
{"creature_52957",1,-19.631,40.075,-4.214},
{"creature_52990",2,-20.984,2459.93,-4.297},
{"creature_53788",3,-18.497,-17.03,-4.297},
{"gameobject_18807",4,4.499,-11.347,7.011},
{"gameobject_18806",5,-45.393,2472.93,6.989},
{"gameobject_18805",6,-45.401,2512.15,6.989},
{"gameobject_18804",7,-45.401,2492.79,6.989},
{"gameobject_18803",8,4.528,8.435,7.011},
{"gameobject_18802",9,4.581,28.21,7.011},
{"gameobject_20738",10,-19.664,44.256,-4.297},
{"gameobject_20739",10,-22.504,44.436,-4.297},
{"gameobject_20740",10,-16.772,44.478,-4.297},
}
WVN7Logical = WVN7Logical or {}
WVN7Logical[499] = LogicalTargets
