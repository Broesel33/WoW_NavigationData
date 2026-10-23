-- Logical target catalogue, compact format 2 (TechnicalDocumentation/05). No graph bindings, no provenance.
local LogicalTargets = {format=2,schema=1,layer="logical",zoneId=2482,coordinateSpace="world",nativeMapId=1,availability="static",sourceSha256="9348EEB0AF46AABAC099274AEB95D74060E307F352EC5BB001F0C52DB609B17D",converterSha256="3986801B36094D4E393D073B479533C9EE73D989C5FF054BFEB457A255EE3C56",payloadSha256="B37EBB5FFF79F171A127B909C329475A5900AF4D0F69EABC38CB8A91B7FD6EB0",dropped={}}
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
{"questie_gameobject_602722_616_0",4,5203.12,-3320.62,1644.353,p=true},
{"questie_gameobject_655669_616_0",5,5151.5,-3381.74,1629.097},
}
WVN7Logical = WVN7Logical or {}
WVN7Logical[2482] = LogicalTargets
