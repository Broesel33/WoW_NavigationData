-- Logical target catalogue, compact format 2 (TechnicalDocumentation/05). No graph bindings, no provenance.
local LogicalTargets = {format=2,schema=1,layer="logical",zoneId=2482,coordinateSpace="world",nativeMapId=1,availability="static",sourceSha256="BC35A27B8D16E8AAF05D4EEECB668A53689883408C363077E02025DAAE81002E",converterSha256="3986801B36094D4E393D073B479533C9EE73D989C5FF054BFEB457A255EE3C56",payloadSha256="7B8714A7E8628FB32836DA330333F00F2CDB8031FA5D4B915B174E02336F3831",dropped={}}
LogicalTargets.classes = {
{"mob","npc_or_mob",243509,"Noxious Slime","Giftiger Schleim"},
{"mob","npc_or_mob",251321,"Peon"},
{"mob","npc_or_mob",259358,"Treant"},
{"gameobject","object",602722,"Mailbox"},
{"gameobject","object",655669,"Mailbox"},
}
LogicalTargets.targets = {
{"questie_creature_243509_616_0",1,4460.6,-2439.54,1128.894},
{"questie_creature_251321_616_0",2,5119.1,-1367.45,1347.932},
{"questie_creature_251321_616_1",2,5086.7,-1374.4,1343.506},
{"questie_creature_251321_616_2",2,5063.55,-1395.23,1340.356},
{"questie_creature_259358_616_0",3,4361.07,-2798.99,1102.297},
{"questie_gameobject_602722_616_0",4,5211.68,-3329.65,l={1644.556,2480.282}},
{"questie_gameobject_602722_616_1",4,5200.11,-3329.65,1644.324},
{"questie_gameobject_655669_616_0",5,5151.5,-3381.74,1629.097},
}
WVN7Logical = WVN7Logical or {}
WVN7Logical[2482] = LogicalTargets
