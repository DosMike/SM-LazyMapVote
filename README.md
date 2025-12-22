# Lazy Map Vote

**⚠️ THIS PLUGIN DOES NOT SUPPORT HOT LOADING ⚠️**\
Please change map to load or update the plugin.

Opinionated map vote plugin for LazyPurple servers.

UMC3, while highly configurable is slow as a sloth on narcotics, once your mapcycle file reaches a few hundret maps.

We needed optionally tiered map votes with groups in the mapcycle file; workshop support and group/map configs. So this is excatly the featureset this plugin contains.

### Commands:
* /rtv
* /setnextmap
* /forcemapvote
* /nominate

### Convars:
* sm_lmv_rtv_quota 0-100 - percent of players to whack in /rtv to start a vote or change map
* sm_lmv_rtv_enabled 0/1 - if disabled, only map end votes run
* sm_lmv_tiebreaker 0+ - if >0, all vote results less than this amount of vote off of the top vote enter a tie breaker vote
* sm_lmv_tieredvote 0/1 - if 1 the vote goes map group -> map in group, only a direct map vote otherwise

### Config:
UMC mapcycle files and structure is supported with umc_mapcycle.txt and root section umc_mapcycle. Otherwise lazy_mapcycle.txt with root section mapcycle is loaded.
```c
"mapcycle"
{
    "group"
    {
        "command" "command to run when group map starts"
        "maps_invote" "amount of maps from this group that go into the mapvote list"
        "nomination_flags" "admin flag string to be able to nominate maps in this group"
        "mapname"
        {
            "nomination_flags" "admin flag string to be able to nominate the map"
            "workshopid" "numeric workshop id"
            "command" "command to run when map starts"
        }
        "mapname" ...
    }
    "group" ...
}
```

### ℹ️ This plugins replaces:
* mapchooser.smx
* nominations.smx
* randomcycle.smx
* rockthevote.smx